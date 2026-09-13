# Benchmarks

```sh
mix bench              # everything
mix bench queries      # just bench/queries.exs
mix bench scaling writes
```

| script | what it measures |
|---|---|
| `queries.exs` | read paths, and what the NIF boundary costs on top of the engine |
| `scaling.exs` | how read cost grows with the size of a label |
| `writes.exs` | create / update / delete, and bulk load against a CREATE loop |
| `concurrency.exs` | many processes against one handle, versus one handle each |

`support.ex` builds the fixture: a deterministic social graph with a
heavy-tailed degree distribution (preferential attachment). A uniform-random
graph would be the wrong thing to measure — real graphs concentrate degree in a
few nodes, and that is what makes multi-hop traversal expensive. At 50k people
the mean degree is ~12 while the top nodes reach ~255.

## Findings

Measured on an i7-6700K, Elixir 1.19.6 / OTP 28, in-memory graphs. Treat the
shapes as the result, not the absolute numbers.

### Index what you filter on. This is the whole game.

| | 10k people | 50k | 200k |
|---|---|---|---|
| indexed point lookup | 13.7 µs | 14.0 µs | 14.0 µs |
| label scan | 15.2 ms | 77.3 ms | 300.8 ms |

The indexed lookup is **flat**: 20× the data, 1.03× the time. The scan is
**linear**: 20× the data, 19.8× the time — about 1.5 µs per node. That is a
factor of ~21,000 between them at 200k nodes.

### `LIMIT` does not make a scan cheap

`LIMIT 1` costs the same as `LIMIT 100`. The engine materialises every node
carrying the label and then truncates, so a limit bounds what crosses into
Elixir, not what the engine walks. If you are reaching for `LIMIT` to make a
scan affordable, reach for an index instead.

### Traversal cost follows degree, not graph size

2-hop traversal from a given node runs in roughly 50–100 µs whether the graph
holds 10k or 200k people. Hop count is what dominates: at 50k, 1 hop is ~14 µs,
2 hops ~46 µs, 3 hops ~471 µs. That is the heavy tail doing its work — each
additional hop multiplies by the average degree of the nodes reached, and the
hubs are reached quickly.

### Bulk load is ~3× faster than a CREATE loop

10,000 nodes, identical data:

| | time |
|---|---|
| `import_jsonl/2` | 13.8 ms |
| 10,000 individual `CREATE`s | 41.3 ms |

`import_jsonl/2` turns off autocommit and commits in batches. Use it for
loaders.

### Do not share one handle across processes — shard

2,000 indexed lookups, varying the number of BEAM processes:

| processes | one shared handle | one handle each |
|---|---|---|
| 1 | 14.4 ms | 11.8 ms |
| 2 | 17.0 ms | 8.2 ms |
| 4 | 19.6 ms | 8.8 ms |
| 8 | 22.2 ms | 6.8 ms |

Sharing a handle does not merely fail to scale — it gets **1.54× slower** at 8
processes than at 1. glider is not thread-safe, so the NIF serialises every
call on a mutex; the critical section is the entire query, so extra processes
add contention and dirty-scheduler dispatch while buying no parallelism.

Separate handles have separate mutexes and do scale (1.74× at 8 processes,
sublinear because the work is already only ~14 µs). If you need parallel reads,
give each reader its own graph rather than sharing one.

### The boundary itself is cheap

A point lookup returning a scalar is ~6.9 µs end to end, including
dirty-scheduler dispatch. Returning a `%Glider.Node{}` instead costs ~12.7 µs,
so building the struct and its property map roughly doubles a trivial call —
but against anything that actually walks the graph it disappears.

## A note on memory measurement

The scripts do not set Benchee's `memory_time`. The engine allocates results
outside the BEAM heap, so the process-heap delta Benchee reports is identical
for every scenario and measures nothing useful. Use the engine's own
`STATS` (`Glider.stats/1`) for graph size instead.
