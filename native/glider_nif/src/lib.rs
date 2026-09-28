//! Rustler NIF bridging glider to the BEAM.
//!
//! Three things about this boundary are not optional, and everything below is
//! shaped by them:
//!
//! 1. **glider is not thread-safe.** A graph owns its page cache and write
//!    state and mutates them in place. The BEAM will happily call a NIF for the same
//!    resource from every scheduler at once, so the handle wraps a `Mutex`.
//!    That serialises access, which is the same bargain `glider serve` makes.
//!
//! 2. **A NIF must not block a scheduler.** Anything that can run long — a
//!    query, an algorithm, opening a file, a bulk import — is marked
//!    `DirtyCpu`, or `DirtyIo` where it waits on disk. Running PageRank over a
//!    million nodes on a normal scheduler would stall the whole VM.
//!
//! 3. **Atoms are never garbage collected.** Property keys and label names are
//!    arbitrary user data, so they cross as binaries. Turning them into atoms
//!    would be an unbounded leak that eventually kills the node.
//!
//! 4. **A transaction belongs to a process.** `begin` records the calling
//!    process as the owner; calls from any other process wait until it
//!    commits or rolls back, so nobody sees or joins half a transaction. The
//!    owner is monitored: if it dies mid-transaction, the transaction is
//!    rolled back and the handle freed.
//!
//! Results are built as native Erlang terms rather than JSON. Every fallible
//! NIF returns `Result<_, String>`, which rustler encodes as `{:ok, _}` or
//! `{:error, reason}`.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use rustler::{Atom, Encoder, Env, LocalPid, Monitor, Resource, ResourceArc, Term, TermType};

use glider::api::{self, Entity};
use glider::graph::{Dir, Graph, OpenOptions};
use glider::query::{self, QueryResult};
use glider::store::Sync as GliderSync;
use glider::value::Value;

mod atoms {
    rustler::atoms! {
        ok,
        nil,
        always,
        normal,
        off,
    }
}

// ------------------------------------------------------------------ resource

/// The handle Elixir holds. `ResourceArc` refcounts it and runs `Drop` when the
/// last reference is collected, so a graph is released — and its file lock
/// dropped — even if nobody calls `close/1`.
pub struct DbResource {
    state: Mutex<State>,
    /// Signalled when a transaction ends.
    free: Condvar,
}

struct State {
    graph: Option<Graph>,
    /// The process holding an open transaction, and its monitor.
    owner: Option<(LocalPid, Option<Monitor>)>,
    /// A statement failed inside the transaction: only rollback is allowed.
    aborted: bool,
}

/// How long a call waits for another process's transaction to finish.
const TX_WAIT: Duration = Duration::from_secs(60);

#[rustler::resource_impl]
impl Resource for DbResource {
    fn down<'a>(&'a self, _env: Env<'a>, pid: LocalPid, _monitor: Monitor) {
        let mut st = self.lock();
        if st.owner.as_ref().map(|(p, _)| *p == pid).unwrap_or(false) {
            if let Some(g) = st.graph.as_mut() {
                let _ = g.rollback();
                g.autocommit = true;
            }
            st.owner = None;
            st.aborted = false;
            self.free.notify_all();
        }
    }
}

impl DbResource {
    /// Take the lock, recovering from poisoning.
    ///
    /// A panic inside one call poisons the mutex. Propagating that would turn a
    /// single bad query into a permanently dead handle, so the guard is
    /// recovered instead. glider commits transactionally, so the graph is not
    /// left half-written.
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        match self.state.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// The state, once no other process holds a transaction.
    fn acquire(&self, caller: LocalPid) -> Result<std::sync::MutexGuard<'_, State>, String> {
        let deadline = Instant::now() + TX_WAIT;
        let mut st = self.lock();
        loop {
            match &st.owner {
                Some((p, _)) if *p != caller => {
                    let left = deadline.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Err("timed out waiting for another process's transaction".into());
                    }
                    st = match self.free.wait_timeout(st, left) {
                        Ok((g, _)) => g,
                        Err(poisoned) => poisoned.into_inner().0,
                    };
                }
                _ => return Ok(st),
            }
        }
    }

    fn with<T>(
        &self,
        caller: LocalPid,
        f: impl FnOnce(&mut Graph) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut st = self.acquire(caller)?;
        let in_tx = st.owner.is_some();
        if in_tx && st.aborted {
            return Err("the transaction was aborted by an earlier error; roll it back".into());
        }
        let r = match st.graph.as_mut() {
            Some(g) => f(g),
            None => Err("this graph is closed".to_string()),
        };
        if in_tx && r.is_err() {
            st.aborted = true;
        }
        r
    }
}

fn new_handle(graph: Graph) -> ResourceArc<DbResource> {
    ResourceArc::new(DbResource {
        state: Mutex::new(State {
            graph: Some(graph),
            owner: None,
            aborted: false,
        }),
        free: Condvar::new(),
    })
}

/// An Elixir term as a glider value: nil, booleans, integers, floats,
/// binaries and lists of those. Anything else is refused rather than
/// guessed at.
fn term_value(t: Term) -> Result<Value, String> {
    match t.get_type() {
        TermType::Atom => {
            if t == atoms::nil().encode(t.get_env()) {
                Ok(Value::Null)
            } else if let Ok(b) = t.decode::<bool>() {
                Ok(Value::Bool(b))
            } else {
                Ok(Value::Text(t.atom_to_string().map_err(|_| "bad atom")?))
            }
        }
        TermType::Integer => t
            .decode::<i64>()
            .map(Value::Int)
            .map_err(|_| "integer parameter out of 64-bit range".to_string()),
        TermType::Float => t.decode::<f64>().map(Value::Float).map_err(|_| "bad float".into()),
        TermType::Binary => t
            .decode::<String>()
            .map(Value::Text)
            .map_err(|_| "binary parameter is not valid UTF-8".to_string()),
        TermType::List => {
            let items: Vec<Term> = t.decode().map_err(|_| "bad list")?;
            items.into_iter().map(term_value).collect::<Result<Vec<_>, _>>().map(Value::List)
        }
        other => Err(format!("unsupported parameter value ({other:?})")),
    }
}

fn params_of(params: Vec<(String, Term)>) -> Result<Vec<(String, Value)>, String> {
    params
        .into_iter()
        .map(|(k, v)| term_value(v).map(|v| (k, v)))
        .collect()
}

// -------------------------------------------------------------------- terms

fn atom_term<'a>(env: Env<'a>, name: &str) -> Term<'a> {
    Atom::from_str(env, name)
        .expect("atom table exhausted")
        .encode(env)
}

/// A glider `Value` as the corresponding Elixir term. Values are flat, so this
/// is total.
fn value_term<'a>(env: Env<'a>, v: &Value) -> Term<'a> {
    match v {
        Value::Null => atoms::nil().encode(env),
        Value::Bool(b) => b.encode(env),
        Value::Int(i) => i.encode(env),
        Value::Float(f) => f.encode(env),
        Value::Text(s) => s.encode(env),
        Value::List(items) => items
            .iter()
            .map(|i| value_term(env, i))
            .collect::<Vec<_>>()
            .encode(env),
    }
}

/// Properties as a map keyed by binary. See the note on atoms above.
fn props_term<'a>(env: Env<'a>, pairs: &[(String, Value)]) -> Term<'a> {
    let keys: Vec<Term<'a>> = pairs.iter().map(|(k, _)| k.encode(env)).collect();
    let values: Vec<Term<'a>> = pairs.iter().map(|(_, v)| value_term(env, v)).collect();
    Term::map_from_arrays(env, &keys, &values).expect("duplicate property key")
}

/// Build `%Glider.Node{}`. An Elixir struct is a map carrying `:__struct__`,
/// so this is constructed directly rather than through a NifStruct derive —
/// which would also force `props` to be a list of tuples instead of a map.
fn node_term<'a>(env: Env<'a>, g: &Graph, id: u64) -> Term<'a> {
    let labels: Vec<Term<'a>> = g.node_labels(id).iter().map(|l| l.encode(env)).collect();
    let keys = [
        atom_term(env, "__struct__"),
        atom_term(env, "id"),
        atom_term(env, "labels"),
        atom_term(env, "props"),
    ];
    let values = [
        atom_term(env, "Elixir.Glider.Node"),
        id.encode(env),
        labels.encode(env),
        props_term(env, &g.node_props(id)),
    ];
    Term::map_from_arrays(env, &keys, &values).expect("node struct")
}

/// Build `%Glider.Rel{}`, or `nil` if the edge has gone.
fn rel_term<'a>(env: Env<'a>, g: &Graph, id: u64) -> Term<'a> {
    let Some(e) = g.edge(id) else {
        return atoms::nil().encode(env);
    };
    let keys = [
        atom_term(env, "__struct__"),
        atom_term(env, "id"),
        atom_term(env, "type"),
        atom_term(env, "from"),
        atom_term(env, "to"),
        atom_term(env, "props"),
    ];
    let values = [
        atom_term(env, "Elixir.Glider.Rel"),
        id.encode(env),
        g.edge_type_name(id).unwrap_or("").encode(env),
        e.from.encode(env),
        e.to.encode(env),
        props_term(env, &g.edge_props(id)),
    ];
    Term::map_from_arrays(env, &keys, &values).expect("rel struct")
}

fn graph_term<'a>(
    env: Env<'a>,
    g: &Graph,
    nodes: &BTreeSet<u64>,
    edges: &BTreeSet<u64>,
) -> Term<'a> {
    let n: Vec<Term<'a>> = nodes.iter().map(|id| node_term(env, g, *id)).collect();
    let e: Vec<Term<'a>> = edges.iter().map(|id| rel_term(env, g, *id)).collect();
    let keys = [atom_term(env, "nodes"), atom_term(env, "edges")];
    let values = [n.encode(env), e.encode(env)];
    Term::map_from_arrays(env, &keys, &values).expect("graph map")
}

/// Turn a QueryResult into the map Elixir wraps as `%Glider.Result{}`,
/// including the deduplicated graph projection.
fn result_term<'a>(env: Env<'a>, g: &Graph, r: &QueryResult) -> Term<'a> {
    let mut node_ids: BTreeSet<u64> = BTreeSet::new();
    let mut edge_ids: BTreeSet<u64> = BTreeSet::new();

    let rows: Vec<Term<'a>> = r
        .rows
        .iter()
        .map(|row| {
            let cells: Vec<Term<'a>> = row
                .iter()
                .map(|v| match api::classify(g, v) {
                    Some(Entity::Node(id)) => {
                        node_ids.insert(id);
                        node_term(env, g, id)
                    }
                    Some(Entity::Edge(id)) => {
                        edge_ids.insert(id);
                        rel_term(env, g, id)
                    }
                    None => value_term(env, v),
                })
                .collect();
            cells.encode(env)
        })
        .collect();

    // An edge whose endpoints are absent cannot be drawn, so pull them in.
    // This is why `MATCH ()-[r]->() RETURN r` still yields both endpoints.
    for eid in edge_ids.iter().copied().collect::<Vec<_>>() {
        if let Some(e) = g.edge(eid) {
            node_ids.insert(e.from);
            node_ids.insert(e.to);
        }
    }

    let columns: Vec<Term<'a>> = r.columns.iter().map(|c| c.encode(env)).collect();
    let message = match &r.message {
        Some(m) => m.encode(env),
        None => atoms::nil().encode(env),
    };

    let keys = [
        atom_term(env, "columns"),
        atom_term(env, "rows"),
        atom_term(env, "graph"),
        atom_term(env, "message"),
        atom_term(env, "touched"),
    ];
    let values = [
        columns.encode(env),
        rows.encode(env),
        graph_term(env, g, &node_ids, &edge_ids),
        message,
        r.touched.encode(env),
    ];
    Term::map_from_arrays(env, &keys, &values).expect("result map")
}

// --------------------------------------------------------------------- NIFs

/// An in-memory graph; `max_bytes` 0 means the machine's physical memory.
/// Past the limit, writes fail with "graph is full" and roll back.
#[rustler::nif]
fn open_memory(max_bytes: u64) -> ResourceArc<DbResource> {
    new_handle(if max_bytes == 0 {
        Graph::memory()
    } else {
        Graph::memory_with_limit(max_bytes)
    })
}

/// Opening reads a superblock and replays whatever log a crash left, which
/// waits on disk: DirtyIo. Sizes of 0 mean the engine's defaults.
#[rustler::nif(schedule = "DirtyIo")]
fn open_file(
    path: String,
    sync: Atom,
    cache_size: u64,
    work_mem: u64,
    checkpoint_bytes: u64,
) -> Result<ResourceArc<DbResource>, String> {
    let mode = if sync == atoms::always() {
        GliderSync::Always
    } else if sync == atoms::off() {
        GliderSync::Off
    } else {
        GliderSync::Normal
    };
    let d = OpenOptions::default();
    let opts = OpenOptions {
        sync: mode,
        cache_size: if cache_size == 0 { d.cache_size } else { cache_size },
        work_mem: if work_mem == 0 { d.work_mem } else { work_mem },
        checkpoint_bytes: if checkpoint_bytes == 0 { d.checkpoint_bytes } else { checkpoint_bytes },
        ..d
    };
    let graph = Graph::open_opts(Path::new(&path), opts).map_err(|e| e.to_string())?;
    Ok(new_handle(graph))
}

/// Queries are unbounded — a whole-graph algorithm can run for minutes — so
/// this never touches a normal scheduler. `params` are `$name` values.
#[rustler::nif(schedule = "DirtyCpu")]
fn query<'a>(
    env: Env<'a>,
    db: ResourceArc<DbResource>,
    q: String,
    params: Vec<(String, Term<'a>)>,
) -> Result<Term<'a>, String> {
    let params = params_of(params)?;
    db.with(env.pid(), |g| {
        let r = query::execute_with(g, &q, &params).map_err(|e| e.to_string())?;
        Ok(result_term(env, g, &r))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn schema(env: Env, db: ResourceArc<DbResource>) -> Result<String, String> {
    db.with(env.pid(), api::schema_json)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn expand<'a>(
    env: Env<'a>,
    db: ResourceArc<DbResource>,
    id: u64,
    limit: usize,
) -> Result<Term<'a>, String> {
    db.with(env.pid(), |g| {
        if g.node(id).is_none() {
            return Err(format!("no node with id {}", id));
        }
        let mut nodes: BTreeSet<u64> = BTreeSet::new();
        let mut edges: BTreeSet<u64> = BTreeSet::new();
        nodes.insert(id);
        for a in g.neighbors_limited(id, Dir::Both, limit.min(10_000)) {
            edges.insert(a.edge);
            nodes.insert(a.other);
        }
        Ok(graph_term(env, g, &nodes, &edges))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn import_jsonl(env: Env, db: ResourceArc<DbResource>, jsonl: String) -> Result<(usize, usize), String> {
    db.with(env.pid(), |g| query::import_jsonl(g, &jsonl).map_err(|e| e.to_string()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_jsonl(env: Env, db: ResourceArc<DbResource>) -> Result<String, String> {
    db.with(env.pid(), |g| Ok(query::export_jsonl(g)))
}

/// Flushing waits on the filesystem.
#[rustler::nif(schedule = "DirtyIo")]
fn checkpoint(env: Env, db: ResourceArc<DbResource>) -> Result<Atom, String> {
    db.with(env.pid(), |g| {
        if g.uncommitted() > 0 {
            return Err("cannot checkpoint inside a transaction".into());
        }
        g.checkpoint().map_err(|e| e.to_string())
    })?;
    Ok(atoms::ok())
}

/// Start a transaction owned by the calling process.
#[rustler::nif(schedule = "DirtyIo")]
fn begin(env: Env, db: ResourceArc<DbResource>) -> Result<Atom, String> {
    let caller = env.pid();
    let mut st = db.acquire(caller)?;
    if st.owner.is_some() {
        return Err("a transaction is already open in this process".into());
    }
    let Some(g) = st.graph.as_mut() else {
        return Err("this graph is closed".into());
    };
    g.autocommit = false;
    let mon = env.monitor(&db, &caller);
    st.owner = Some((caller, mon));
    st.aborted = false;
    Ok(atoms::ok())
}

fn end_tx(env: Env, db: &ResourceArc<DbResource>, commit: bool) -> Result<Atom, String> {
    let caller = env.pid();
    let mut st = db.acquire(caller)?;
    if st.owner.is_none() {
        return Err("no transaction is open".into());
    }
    let aborted = st.aborted;
    let r = match st.graph.as_mut() {
        Some(g) => {
            let r = if commit && !aborted {
                g.commit().map_err(|e| e.to_string())
            } else {
                g.rollback().map_err(|e| e.to_string())
            };
            g.autocommit = true;
            r
        }
        None => Ok(()),
    };
    if let Some((_, Some(mon))) = st.owner.take() {
        env.demonitor(db, &mon);
    }
    st.aborted = false;
    db.free.notify_all();
    drop(st);
    r?;
    if commit && aborted {
        return Err("the transaction was aborted by an earlier error and has been rolled back".into());
    }
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit(env: Env, db: ResourceArc<DbResource>) -> Result<Atom, String> {
    end_tx(env, &db, true)
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback(env: Env, db: ResourceArc<DbResource>) -> Result<Atom, String> {
    end_tx(env, &db, false)
}

/// Whether the calling process holds an open transaction on this handle.
#[rustler::nif]
fn in_transaction(env: Env, db: ResourceArc<DbResource>) -> bool {
    let st = db.lock();
    st.owner.as_ref().map(|(p, _)| *p == env.pid()).unwrap_or(false)
}

/// Act on a replicator's request now, for a handle that may sit idle
/// (see glider's docs/REPLICATION.md).
#[rustler::nif(schedule = "DirtyIo")]
fn poll_replication(env: Env, db: ResourceArc<DbResource>) -> Result<Atom, String> {
    db.with(env.pid(), |g| g.poll_replication().map_err(|e| e.to_string()))?;
    Ok(atoms::ok())
}

/// Drop the graph now rather than at garbage collection, releasing the file
/// lock so the path can be reopened. An open transaction is rolled back.
/// Idempotent.
#[rustler::nif(schedule = "DirtyIo")]
fn close(env: Env, db: ResourceArc<DbResource>) -> Atom {
    let mut st = db.lock();
    let in_tx = st.owner.is_some();
    if let Some(g) = st.graph.as_mut() {
        if in_tx {
            let _ = g.rollback();
        }
    }
    if let Some((_, Some(mon))) = st.owner.take() {
        env.demonitor(&db, &mon);
    }
    st.graph = None;
    db.free.notify_all();
    atoms::ok()
}

#[rustler::nif]
fn version() -> &'static str {
    glider::VERSION
}

/// The kind of legacy (pre-paged) file at `path`, or nothing if it is a paged
/// database, absent, or not glider's at all. A stat and a header read.
#[rustler::nif(schedule = "DirtyIo")]
fn legacy_kind(path: String) -> Option<String> {
    glider::legacy::detect(Path::new(&path)).map(|k| k.to_string())
}

/// Convert a legacy log-format database into a paged one, in place: the new
/// database is built beside the old under `<path>.migrating`, then swapped in,
/// and the original is kept as `<path>.legacy.bak`. Returns the node and edge
/// counts copied. Reads and writes the whole graph, so DirtyIo.
#[rustler::nif(schedule = "DirtyIo")]
fn migrate(path: String) -> Result<(u64, u64), String> {
    let db = Path::new(&path);
    if glider::legacy::detect(db).is_none() {
        return Err(format!("{path} is not a legacy glider file; nothing to migrate"));
    }
    let old = glider::legacy::graph::Graph::open(db, GliderSync::Normal).map_err(|e| e.to_string())?;
    let tmp = format!("{path}.migrating");
    for suffix in ["", "-wal", "-data", ".lock"] {
        let _ = std::fs::remove_file(format!("{tmp}{suffix}"));
    }
    let mut g = Graph::open(Path::new(&tmp), GliderSync::Off).map_err(|e| e.to_string())?;
    g.import_legacy(&old).map_err(|e| e.to_string())?;
    g.checkpoint().map_err(|e| e.to_string())?;
    let (n, e) = (g.node_count() as u64, g.edge_count() as u64);
    drop(g);
    drop(old);
    std::fs::rename(db, format!("{path}.legacy.bak")).map_err(|e| e.to_string())?;
    for (from, to) in [
        (tmp.clone(), path.clone()),
        (format!("{tmp}-wal"), format!("{path}-wal")),
        (format!("{tmp}-data"), format!("{path}-data")),
    ] {
        if Path::new(&from).exists() {
            std::fs::rename(&from, &to).map_err(|e| e.to_string())?;
        }
    }
    let _ = std::fs::remove_file(format!("{tmp}.lock"));
    let _ = std::fs::remove_file(format!("{path}.lock"));
    Ok((n, e))
}

rustler::init!("Elixir.Glider.Native");
