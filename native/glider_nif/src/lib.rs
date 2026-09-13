//! Rustler NIF bridging glider to the BEAM.
//!
//! Three things about this boundary are not optional, and everything below is
//! shaped by them:
//!
//! 1. **glider is not thread-safe.** The engine holds the graph in memory and
//!    mutates it in place. The BEAM will happily call a NIF for the same
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
//! Results are built as native Erlang terms rather than JSON. Every fallible
//! NIF returns `Result<_, String>`, which rustler encodes as `{:ok, _}` or
//! `{:error, reason}`.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Mutex;

use rustler::{Atom, Encoder, Env, Resource, ResourceArc, Term};

use glider::api::{self, Entity};
use glider::graph::{Dir, Graph};
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
    graph: Mutex<Option<Graph>>,
}

#[rustler::resource_impl]
impl Resource for DbResource {}

impl DbResource {
    /// Take the lock, recovering from poisoning.
    ///
    /// A panic inside one call poisons the mutex. Propagating that would turn a
    /// single bad query into a permanently dead handle, so the guard is
    /// recovered instead. glider commits transactionally, so the graph is not
    /// left half-written.
    fn lock(&self) -> std::sync::MutexGuard<'_, Option<Graph>> {
        match self.graph.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn with<T>(&self, f: impl FnOnce(&mut Graph) -> Result<T, String>) -> Result<T, String> {
        let mut guard = self.lock();
        match guard.as_mut() {
            Some(g) => f(g),
            None => Err("this graph is closed".to_string()),
        }
    }
}

fn new_handle(graph: Graph) -> ResourceArc<DbResource> {
    ResourceArc::new(DbResource {
        graph: Mutex::new(Some(graph)),
    })
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

#[rustler::nif]
fn open_memory() -> ResourceArc<DbResource> {
    new_handle(Graph::memory())
}

/// Opening a file replays the whole write-ahead log: disk-bound and unbounded
/// in time, hence DirtyIo.
#[rustler::nif(schedule = "DirtyIo")]
fn open_file(path: String, sync: Atom) -> Result<ResourceArc<DbResource>, String> {
    let mode = if sync == atoms::always() {
        GliderSync::Always
    } else if sync == atoms::off() {
        GliderSync::Off
    } else {
        GliderSync::Normal
    };
    let graph = Graph::open(Path::new(&path), mode).map_err(|e| e.to_string())?;
    Ok(new_handle(graph))
}

/// Queries are unbounded — a whole-graph algorithm can run for seconds — so
/// this never touches a normal scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn query<'a>(env: Env<'a>, db: ResourceArc<DbResource>, q: String) -> Result<Term<'a>, String> {
    db.with(|g| {
        let r = query::execute(g, &q).map_err(|e| e.to_string())?;
        Ok(result_term(env, g, &r))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn schema(db: ResourceArc<DbResource>) -> Result<String, String> {
    db.with(api::schema_json)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn expand<'a>(
    env: Env<'a>,
    db: ResourceArc<DbResource>,
    id: u64,
    limit: usize,
) -> Result<Term<'a>, String> {
    db.with(|g| {
        if g.node(id).is_none() {
            return Err(format!("no node with id {}", id));
        }
        let mut nodes: BTreeSet<u64> = BTreeSet::new();
        let mut edges: BTreeSet<u64> = BTreeSet::new();
        nodes.insert(id);
        for a in g
            .neighbors(id, Dir::Both, None)
            .into_iter()
            .take(limit.min(10_000))
        {
            edges.insert(a.edge);
            nodes.insert(a.other);
        }
        Ok(graph_term(env, g, &nodes, &edges))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn import_jsonl(db: ResourceArc<DbResource>, jsonl: String) -> Result<(usize, usize), String> {
    db.with(|g| query::import_jsonl(g, &jsonl).map_err(|e| e.to_string()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_jsonl(db: ResourceArc<DbResource>) -> Result<String, String> {
    db.with(|g| Ok(query::export_jsonl(g)))
}

/// Flushing waits on the filesystem.
#[rustler::nif(schedule = "DirtyIo")]
fn checkpoint(db: ResourceArc<DbResource>) -> Result<Atom, String> {
    db.with(|g| g.checkpoint().map_err(|e| e.to_string()))?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
fn compact(db: ResourceArc<DbResource>) -> Result<Atom, String> {
    db.with(|g| g.compact().map_err(|e| e.to_string()))?;
    Ok(atoms::ok())
}

/// Drop the graph now rather than at garbage collection, releasing the file
/// lock so the path can be reopened. Idempotent.
#[rustler::nif(schedule = "DirtyIo")]
fn close(db: ResourceArc<DbResource>) -> Atom {
    let mut guard = db.lock();
    *guard = None;
    atoms::ok()
}

#[rustler::nif]
fn version() -> &'static str {
    glider::VERSION
}

rustler::init!("Elixir.Glider.Native");
