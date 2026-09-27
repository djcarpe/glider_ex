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
| `Glider.expand/3` | neighbours of one node, both directions |
| `Glider.import_jsonl/2`, `Glider.export_jsonl/1` | bulk load and dump |
| `Glider.stats/1` | node, edge, label and index counts |
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
```

The file is a paged database with a write-ahead log beside it. It can grow far
past RAM: memory stays near `cache_size` (default 1G) however large the file
is. Commits go to the log and are folded into the pages after `checkpoint`
bytes of log (default 256M) or on `checkpoint/1`. A torn log tail is discarded
on open, so you never see a partial transaction. Only one writer may hold a
file; a second `open/2` returns `{:error, reason}` until the first calls
`close/1` or is garbage collected.

Sizes are bytes, or strings like `"256M"` and `"4G"`.

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
lib/glider/query.ex        Glider.Query, the composable query builder
lib/glider/structs.ex      %Glider.Node{}, %Glider.Rel{}, %Glider.Result{}
lib/glider/native.ex       raw NIF surface (private)
native/glider_nif/         the Rustler crate
```
