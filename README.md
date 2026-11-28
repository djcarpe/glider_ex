# Glider

Elixir bindings for [glider](../glider), an embeddable property-graph database
with built-in graph algorithms, linked into the BEAM as a Rustler NIF.

No server, no port process, no socket. A query is a function call.

```elixir
{:ok, db} = Glider.open()

{:ok, _} =
  Glider.run(db, "CREATE (a:Person {name:\"Ada\"})-[:KNOWS {since:2019}]->(b:Person {name:\"Bob\"})")

{:ok, r} = Glider.query(db, "MATCH (a)-[r:KNOWS]->(b) RETURN a, r, b")

[%Glider.Node{labels: ["Person"], props: %{"name" => "Ada"}},
 %Glider.Rel{type: "KNOWS", props: %{"since" => 2019}},
 %Glider.Node{props: %{"name" => "Bob"}}] = hd(r.rows)
```

## Install

```elixir
def deps do
  [{:glider_ex, path: "../glider_ex"}]
end
```

Building needs a Rust toolchain; the glider engine itself has no dependencies,
and Rustler is added only here — which is exactly why these bindings live
outside the glider tree.

```sh
mix deps.get
mix compile
mix test
```

## API

| | |
|---|---|
| `Glider.open/1` | a throwaway in-memory graph, optionally capped (`max_memory:`) |
| `Glider.open/2` | open or create a file: `sync:`, `cache_size:`, `work_mem:`, `checkpoint:` |
| `Glider.query/3` | typed result: columns, rows, graph projection |
| `Glider.query!/3` | same, raising `Glider.Error` |
| `Glider.all/3`, `Glider.one/3` | just the rows, shaped by a `Glider.Query`'s `return` |
| `Glider.run/3`, `Glider.run!/3` | run for effect, returns entities touched |
| `Glider.graph/3` | just the `%{nodes: _, edges: _}` projection |
| `Glider.transaction/2`, `Glider.rollback/2` | group statements; abandon them |
| `Glider.schema/1` | labels, relationship types, indexes, with counts |
| `Glider.extensions/1`, `create_extension/2`, `drop_extension/2` | engine extensions this build has and this database installed |
| `Glider.expand/3` | neighbours of one node, both directions |
| `Glider.import_jsonl/2`, `Glider.export_jsonl/1` | bulk load and dump |
| `Glider.stats/1` | node, edge, label and index counts, with the revision and generation |
| `Glider.revision/2`, `Glider.generation/2` | has the graph changed since I last looked: its revision and lineage |
| `Glider.health/2` | one cheap call before relying on a graph: revision, counts, memory, extensions, the change journal, read errors |
| `Glider.Changes` | what changed since a revision: `install/2`, `since/3`, `stream/3`, `status/2`, `release/3`, `cap/3` |
| `Glider.Check` | is the graph whole: `install/1`, `run/2`, `stream/2` |
| `Glider.checkpoint/1` | fold the write-ahead log into the pages |
| `Glider.poll_replication/1` | serve a replicator's request on an idle handle |
| `Glider.close/1` | release the graph and its file lock |

Everything fallible returns `{:ok, _}` or `{:error, reason}`; the bang
variants, `all/3` and `one/3` raise `Glider.Error` instead. Every query
function takes a string or a `Glider.Query`, and a query-first call works too,
so a pipeline can end in `|> Glider.all(db)`.

## Parameters

Pass values as `$name` parameters instead of splicing them into the text. They
are substituted as literals, so a value can never change the query:

```elixir
Glider.all(db, "MATCH (p:Person) WHERE p.age > $min RETURN p.name", min: 30)
```

Nesting is limited to 64 levels, as glider limits it (its README, "Limits"):
a list parameter nested deeper is refused before it reaches the engine, and
a statement nested deeper (parentheses, nested lists, `NOT` or `-` chains,
subscripts, nested calls) is an `{:error, _}`, never a crash of the VM.
Long `AND` chains, sums, lists and many patterns are not deep and have no
such limit.

## Composable queries

`Glider.Query` builds queries the way Ecto does: small functions that take a
query and return a new one, with `^` pinning Elixir values as parameters.
Patterns stay Cypher; conditions, projections and ordering are Elixir
expressions, checked when your code compiles.

```elixir
import Glider.Query

people = match("(p:Person)")
adults = people |> where(p.age >= 18)

adults
|> match("(p)-[:KNOWS]->(f:Person)")
|> where(f.country == ^country and not is_nil(f.email))
|> return(name: p.name, friends: count(f))
|> order_by(desc: :friends)
|> limit(10)
|> Glider.all(db)
#=> [%{name: "Ada", friends: 12}, ...]
```

`return/2` decides the row shape: one expression gives values, a list gives
lists, a tuple gives tuples, a keyword list gives maps. Writes and algorithms
use the same style:

```elixir
Glider.run!(db, create(vertex(:p, "Person", name: "Ada", age: 36)))

match("(a:Person {name: $a}), (b:Person {name: $b})", a: "Ada", b: "Bob")
|> create(edge(:a, "KNOWS", :b, since: 2020))
|> Glider.run!(db)

match("(p:Person)") |> where(p.name == ^name) |> set(p.age = ^age) |> Glider.run!(db)
match("(p:Person)") |> where(p.age < 0) |> delete(:p, detach: true) |> Glider.run!(db)

call(:pagerank, iterations: 20, top: 10) |> Glider.query!(db)
```

`Glider.Query.to_cypher/1` shows the text and parameters a query sends. Where
an expression has no Elixir spelling, `fragment("p.score * ? > 10", ^k)` drops
to raw Cypher with pinned values.

## Context for language models

`Glider.Context` wraps the engine's `context` extension: full-text search for
entry points, a relevance-ranked connected subgraph that fits a token budget,
path explanations and a schema card, in a compact text form.

```elixir
:ok = Glider.Context.install(db)
{:ok, _summary} = Glider.Context.index(db)          # optional: makes search an index lookup
{:ok, card} = Glider.Context.schema(db)             # for the system prompt

{:ok, ctx} = Glider.Context.retrieve(db, query: "Ada Lovelace", budget: 1500)
ctx.text      #=> "# context: 4 nodes, 4 edges; seeds n1\nn1:Person name=\"Ada Lovelace\" ..."
ctx.refs      #=> ["n1", "n2", "n3", "n5"]

# a follow-up spends its budget on what the model has not seen yet
{:ok, more} = Glider.Context.retrieve(db, seeds: ["n2"], seen: ctx.refs, budget: 800)
{:ok, why} = Glider.Context.paths(db, "n1", "n9")
```

The functions work in queries too: `RETURN context.card(p)`, and
`call(:"context.search", query: "...")` in `Glider.Query`. Arguments are
passed as parameters and checked against the procedure's; see glider's
`docs/EXTENSIONS.md` for all of them.

## Derived data: revision, changes, checks, health

Things kept beside a graph and computed from it (embeddings that cost money,
summaries, compiled text for a model) are kept right by jobs that ask three
questions: has the graph changed since I last looked, what exactly changed,
and is the graph whole.

```elixir
# has it changed? the revision grows with every committed change, and only then
{:ok, rev} = Glider.revision(db)

# what changed? the change journal, installed once
:ok = Glider.Changes.install(db, cap: 1_000_000)

case Glider.Changes.since(db, kept_revision) do
  {:ok, %Glider.Changes.Slice{changes: changes, after: nil, complete_up_to: now}} ->
    reembed(for %{kind: :node, change: :put, id: id} <- changes, do: id)
    keep(now)

  {:ok, %Glider.Changes.Slice{after: cursor}} ->
    # more than one slice: call again with after: cursor, or use stream/3

  {:error, %Glider.Changes.Unanswerable{oldest: oldest}} ->
    # the journal cannot say (installed later, released, capped, CLEAR):
    # rebuild from a scan, then carry on from `oldest` or later
    rebuild_all()
end

# large answers, a slice at a time, with the handle free in between
db |> Glider.Changes.stream(kept_revision) |> Stream.chunk_every(100) |> Enum.each(&reembed/1)

# is it whole? edges, adjacency, membership, counters, indexes, derived data
:ok = Glider.Check.install(db)
{:ok, %Glider.Check.Report{findings: []}} = Glider.Check.run(db)
db |> Glider.Check.stream(limit: 100_000) |> Stream.flat_map(& &1.findings) |> Enum.to_list()

# before relying on it at all
{:ok, %Glider.Health{revision: rev, read_error: nil, changes: journal}} = Glider.health(db)
```

The journal never answers "nothing changed" when it cannot answer: asked
about a revision it no longer (or never) covers, `since/3` returns
`{:error, %Glider.Changes.Unanswerable{}}` with the oldest revision it does
cover, and `stream/3` raises it on first use. An empty list of changes always
means nothing changed.

`Glider.Check.run/2` reports and never repairs. With no `:checks` it runs the
six checks of the database (findings of severity `:fault`); `:duplicates`,
`:orphans` and `:required` are facts about the data (`:candidate`) and run
only when named. Each finding names the record (`"e2"`, `"n12"`, or the
label, index or counter at fault).

`Glider.health/2` runs no scan of the graph (the change journal's status
counts its own entries; `changes: false` leaves it out) and so cannot say
whether the graph is whole: that is `Glider.Check.run/2`. It reports a
storage read error the engine has recorded and not yet reported.

Every one of these takes `:max_millis` and `:max_steps` and passes them to
the engine; procedures obey them from the engine version whose procedures
count steps. Each is a `[:glider, :query, ...]` span with `:procedure` set
(`"changes.since"`, `"check.run"`, ...). See glider's `docs/DERIVED.md` and
`docs/EXTENSIONS.md` for what the engine guarantees.

## Transactions

```elixir
{:ok, order} =
  Glider.transaction(db, fn ->
    Glider.run!(db, create(vertex(:o, "Order", ref: ref)))
    unless in_stock?(ref), do: Glider.rollback(db, :out_of_stock)
    ref
  end)
```

A transaction belongs to the calling process. Other processes using the same
handle wait until it commits or rolls back, and if the owner dies mid-way the
transaction is rolled back for it. An exception rolls back and re-raises; a
statement that fails inside the transaction aborts it, and it returns
`{:error, reason}` without committing. A nested `transaction/2` joins the
outer one.

The transaction is one the engine can see start and end (glider's
`Graph::begin()`): if the engine rolls it back itself (a failed write or
write hook, a memory graph past `max_memory`) nothing more can go into it or
commit from it, and operations that commit on their own (`COMPACT`,
`import_jsonl/2`, `import_file/3`, `write_batch/2`) are refused inside it
rather than committing its pending writes.

`BEGIN`, `COMMIT` and `ROLLBACK` sent as statement text are refused, from
every function that takes a statement: as text they would open or close the
handle's transaction for every process at once, with no owner to roll it
back.

## Types

Nodes and relationships arrive as structs. Everything else arrives as the
natural Elixir term.

```elixir
%Glider.Node{id: 1, labels: ["Person"], props: %{"name" => "Ada", "age" => 36}}
%Glider.Rel{id: 1, type: "KNOWS", from: 1, to: 2, props: %{"since" => 2019}}
```

**Property keys are binaries, never atoms.** The atom table is never garbage
collected, so turning user-controlled keys into atoms would be an unbounded
leak that eventually takes the node down. There is a test asserting this.

`result.graph` holds every entity that appeared in the rows, deduplicated, with
the endpoints of any returned relationship pulled in — so
`MATCH ()-[r]->() RETURN r` still gives you both ends without asking.

## Concurrency

A handle is safe to share between processes, but **calls against one handle are
serialised** by a mutex in the NIF: the engine is single-threaded, so
concurrent access would be a data race, not merely slow. Reads do not run in
parallel. The test suite hammers one handle from 16 schedulers to
prove the serialisation holds.

For a supervised single writer, wrap the handle in a `GenServer`. For read
parallelism, open several handles onto separate graphs rather than sharing one.

Every call that can run long — queries, algorithms, opening a file, import,
export, checkpoints — is scheduled on a **dirty scheduler**, so a PageRank over
a large graph will not stall the VM.

## Persistence

```elixir
{:ok, db} = Glider.open("social.gldb")                   # :normal durability
{:ok, db} = Glider.open("social.gldb", sync: :always)    # fsync every commit
{:ok, db} = Glider.open("bulk.gldb", sync: :off, checkpoint: :off)
{:ok, db} = Glider.open("big.gldb", cache_size: "4G", work_mem: "1G")
{:ok, db} = Glider.open("api.gldb", cache_size: "256M", hot_size: "32M")
```

The file is a paged database with a write-ahead log beside it. It can grow far
past RAM: memory stays near `cache_size` (default 1G) however large the file
is. Commits go to the log and are folded into the pages after `checkpoint`
bytes of log (default 256M) or on `checkpoint/1`. A torn log tail is discarded
on open, so you never see a partial transaction. Only one writer may hold a
file; a second `open/2` returns `{:error, reason}` until the first calls
`close/1` or is garbage collected.

With `hot_size`, part of the cache is kept for the pages used most often, and
their list is written beside the file at each checkpoint and on close and
loaded before the next `open/2` returns: a database opened again, or restored
from a replica (whose base carries the list), answers its first lookups of
those pages from memory. `Glider.stats/1` reports `"prewarmed"` and the
other hot-set counters, `Glider.Telemetry.metrics/1` the same beside the
cache's page reads (glider's `docs/HOT.md`).

Sizes are bytes, or strings like `"256M"` and `"4G"`.

## Replication

A paged database replicates to S3, a directory or an `exec:` command as base
snapshots plus the write-ahead log (glider-stream's paged replication; see
glider's `docs/STREAM.md`), and restores from there to any point in time:

```elixir
s3 = [endpoint: "http://minio.internal:9000"]   # keys from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

{:ok, db} = Glider.open("app.gldb")
{:ok, %{bases_uploaded: 1}} = Glider.Replication.sync("app.gldb", "s3://graphs/app", [db: db] ++ s3)

# or keep it replicated, under a supervisor
{Glider.Replicator, path: "app.gldb", url: "s3://graphs/app", db: db, interval: 1_000, endpoint: "http://minio.internal:9000"}

{:ok, _report} = Glider.Replication.restore("s3://graphs/app", "restored.gldb", s3)
{:ok, _report} = Glider.Replication.restore("s3://graphs/app", "yesterday.gldb", [as_of: System.os_time(:second) - 86_400] ++ s3)
{:ok, back} = Glider.open("restored.gldb")                     # opening replays the log
```

A base is copied from a checkpoint the writer holds in place for the copy,
which it notices at its next commit or when polled: pass the open handle as
`db:` and the pass polls it. Each pass ships into a local spool first and
uploads what is complete (a base's `base.json` last); a failed upload stays
pending for the next pass. `generations/2`, `listing/3`, `lag/3` and
`enforce_retention/3` look at and tidy a replica; every pass emits
`[:glider, :replication, :sync]` telemetry with the bytes, bases, segments,
lag and duration.

A graph in memory replicates too, once it keeps a log. It ships the same
objects a file does, so a replica restores to either place whichever wrote
it, on the same lineage:

```elixir
{:ok, db} = Glider.open(max_memory: "4G", log: true)
{:ok, %{bases_uploaded: 1}} = Glider.Replication.sync(db, "s3://graphs/app", s3)   # the handle, not a path

{Glider.Replicator, db: db, url: "s3://graphs/app", interval: 1_000, endpoint: "http://minio.internal:9000"}

{:ok, %{db: db}} = Glider.Replication.restore("s3://graphs/app", :memory, [max_memory: "4G"] ++ s3)
{:ok, _report} = Glider.Replication.restore("s3://graphs/app", "on-disk.gldb", s3)
```

A pass holds the handle only to take what it ships — the committed pages
by reference, in about the time it takes to copy that many pointers, or
the log since the last pass — and to record that it was shipped. The upload
runs on a dirty I/O scheduler with the handle free, so other processes'
queries carry on while a base is in the air. A graph restored into memory
keeps a log that starts where the replica ended: pointed back at that
replica, it ships only what it writes from then on, with no new base. A
file restored from a replica does the same, if it is replicated again
within ten minutes of the restore (after that it takes a base).

What is in memory and not yet shipped is lost with the VM: that window is
the interval between passes. The log is held in memory until it is shipped,
up to `:log_cap` (64M by default); past it the next pass takes a new base.
A memory graph opened without `log: true` keeps no log and cannot be
replicated, and pays nothing for it.

## Writing queries in Elixir source

Use a plain string, or a heredoc sigil. **Do not use the bracket sigils**:
Elixir nests paired delimiters, so `~S[...]` and `~S(...)` both fail to *parse*
on ordinary Cypher like `-[:KNOWS]->(b)`. Prefer uppercase `~S` over `~s` so a
literal `#{...}` inside a query is not read as interpolation.

## Differences from Cypher

  * `RETURN` requires a `MATCH` — there is no bare `RETURN 1`.
  * `count()` over zero matches returns **zero rows**, not one row holding `0`.
    Use `Glider.stats/1` for a count that is always present.
  * `count(DISTINCT x)` is unsupported; `RETURN DISTINCT` works.

## Telemetry

Queries, transactions, checkpoints, imports and exports emit `:telemetry` span
events: `[:glider, :query, :start | :stop | :exception]` and so on. The
engine's own report on each statement comes with them. `:stop` carries
`rows`, `touched`, `page_reads`, `page_hits`, `page_misses` and
`engine_duration` as measurements, and `operation` (`"MATCH"`, `"CALL"`, ...),
`procedure`, `db_name` and `result` as metadata.

OpenTelemetry spans, parented under the calling process's current span. Add
`{:opentelemetry_api, "~> 1.4"}` and an SDK to your app, then:

```elixir
:ok = Glider.OpenTelemetry.setup()
```

Each statement becomes a client span named after its operation (`glider
MATCH`), with the same attributes glider's native and wasm runtimes use
(`db.system.name`, `db.operation.name`, `db.query.text`,
`db.response.returned_rows`, `glider.page.hits`, ...). A `Glider.transaction/2`
span parents the statements inside it.

Metrics:

| | |
|---|---|
| `Glider.Telemetry.emit_db_metrics/1` | `[:glider, :db]` gauges, for `:telemetry_poller` |
| `Glider.Telemetry.prometheus/1` | Prometheus text for a `/metrics` plug |
| `Glider.Telemetry.start_exporter/1` | the engine's own OTLP exporter, from `OTEL_*` env vars |
| `Glider.Telemetry.snapshot/0`, `metrics/1`, `otlp_metrics/2` | the raw numbers |

See `Glider.Telemetry` for the event catalogue, and glider's
`docs/OBSERVABILITY.md` for the names every runtime shares.

## Benchmarks

```sh
mix bench              # everything
mix bench queries      # one script
```

See `bench/README.md` for the measured findings. The three that change how you
write code against this library:

  * An indexed lookup is flat in graph size; a label scan is linear (~1.5 µs
    per node). `LIMIT` does not make a scan cheap — the engine materialises the
    whole label first.
  * `import_jsonl/2` is ~3x faster than a loop of `CREATE`s.
  * Sharing one handle across processes gets *slower* with concurrency, not
    faster. Give each reader its own graph.

## Layout

```
lib/glider.ex              public API
lib/glider/query.ex        Glider.Query, the composable query builder
lib/glider/structs.ex      %Glider.Node{}, %Glider.Rel{}, %Glider.Result{}, %Glider.Health{}
lib/glider/changes.ex      Glider.Changes, the change journal (structs in changes/)
lib/glider/check.ex        Glider.Check, integrity checks (structs in check/)
lib/glider/procedure.ex    running an engine procedure for a wrapper (private)
lib/glider/telemetry.ex    events, engine metrics, the native OTLP exporter
lib/glider/open_telemetry.ex  OpenTelemetry spans from the events
lib/glider/replication.ex  Glider.Replication: S3/dir replication and restore
lib/glider/replicator.ex   Glider.Replicator, a pass on a schedule
lib/glider/native.ex       raw NIF surface (private)
native/glider_nif/         the Rustler crate
```
