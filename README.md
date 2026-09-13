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
| `Glider.open/0` | a throwaway in-memory graph |
| `Glider.open/2` | open or create a file, with a durability mode |
| `Glider.query/2` | typed result: columns, rows, graph projection |
| `Glider.query!/2` | same, raising `Glider.Error` |
| `Glider.run/2` | run for effect, returns entities touched |
| `Glider.graph/2` | just the `%{nodes: _, edges: _}` projection |
| `Glider.schema/1` | labels, relationship types, indexes, with counts |
| `Glider.expand/3` | neighbours of one node, both directions |
| `Glider.import_jsonl/2`, `Glider.export_jsonl/1` | bulk load and dump |
| `Glider.stats/1` | node, edge, label and index counts |
| `Glider.checkpoint/1`, `Glider.compact/1` | flush; reclaim space |
| `Glider.close/1` | release the graph and its file lock |

Everything fallible returns `{:ok, _}` or `{:error, reason}`.

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
serialised** by a mutex in the NIF. glider holds the graph in memory and mutates
it in place, so concurrent access would be a data race, not merely slow. Reads
do not run in parallel. The test suite hammers one handle from 16 schedulers to
prove the serialisation holds.

For a supervised single writer, wrap the handle in a `GenServer`. For read
parallelism, open several handles onto separate graphs rather than sharing one.

Every call that can run long — queries, algorithms, opening a file, import,
export, compaction — is scheduled on a **dirty scheduler**, so a PageRank over
a large graph will not stall the VM.

## Persistence

```elixir
{:ok, db} = Glider.open("social.gldb")            # :normal durability
{:ok, db} = Glider.open("social.gldb", :always)   # fsync every commit
{:ok, db} = Glider.open("bulk.gldb", :off)        # buffered, for bulk load
```

The file is a write-ahead log and the persistent form at once. A torn tail is
discarded on open, so you never see a partial transaction. Only one writer may
hold a file; a second `open/2` returns `{:error, reason}` until the first calls
`close/1` or is garbage collected.

The graph is memory-resident — reads never touch disk — so it must fit in RAM.

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
lib/glider/structs.ex      %Glider.Node{}, %Glider.Rel{}, %Glider.Result{}
lib/glider/native.ex       raw NIF surface (private)
native/glider_nif/         the Rustler crate
```
