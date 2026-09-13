# Write paths.
#
# The headline comparison is single CREATEs against a bulk JSONL import of the
# same data. import_jsonl/2 turns off autocommit and commits in batches, so it
# is not merely "the same work in a loop" — and the gap is large enough to
# change how you write a loader.

Code.require_file("support.ex", __DIR__)

fresh = fn -> {:ok, db} = Glider.open(); db end

Benchee.run(
  %{
    "CREATE one node" => {
      fn {db, i} -> Glider.query(db, ~s|CREATE (:P {i: #{i}, name: "n#{i}"})|) end,
      before_scenario: fn _ -> fresh.() end,
      before_each: fn db -> {db, :erlang.unique_integer([:positive])} end,
      after_scenario: &Glider.close/1
    },
    "CREATE one node with an edge" => {
      fn {db, i} ->
        Glider.query(db, ~s|CREATE (:P {i: #{i}})-[:R {w: 1}]->(:P {i: #{i + 1}})|)
      end,
      before_scenario: fn _ -> fresh.() end,
      before_each: fn db -> {db, :erlang.unique_integer([:positive])} end,
      after_scenario: &Glider.close/1
    },
    "UPDATE one node by indexed property" => {
      fn {db, i} -> Glider.query(db, ~s|MATCH (p:P {i: #{i}}) SET p.name = "updated"|) end,
      before_scenario: fn _ ->
        db = fresh.()
        Glider.query(db, "INDEX ON :P(i)")
        for i <- 1..5_000, do: Glider.query(db, ~s|CREATE (:P {i: #{i}})|)
        db
      end,
      before_each: fn db -> {db, :rand.uniform(5_000)} end,
      after_scenario: &Glider.close/1
    },
    "DETACH DELETE one node" => {
      fn {db, i} -> Glider.query(db, ~s|MATCH (p:P {i: #{i}}) DETACH DELETE p|) end,
      before_scenario: fn _ ->
        db = fresh.()
        Glider.query(db, "INDEX ON :P(i)")
        for i <- 1..20_000, do: Glider.query(db, ~s|CREATE (:P {i: #{i}})|)
        db
      end,
      before_each: fn db -> {db, :erlang.unique_integer([:positive])} end,
      after_scenario: &Glider.close/1
    }
  },
  time: 3,
  warmup: 1,
  print: [fast_warning: false]
)

# ---- bulk load: the comparison that actually changes how you write a loader

IO.puts("\n== 10,000 nodes: one CREATE at a time vs one import_jsonl ==\n")

n = 10_000
# Nodes only, matching exactly what the CREATE loop below produces.
jsonl = Glider.Bench.nodes_jsonl(n)

Benchee.run(
  %{
    "10k individual CREATEs" => {
      fn db -> for i <- 1..n, do: Glider.query(db, ~s|CREATE (:P {i: #{i}})|) end,
      before_scenario: fn _ -> fresh.() end,
      after_scenario: &Glider.close/1
    },
    "10k via import_jsonl" => {
      fn db -> Glider.import_jsonl(db, jsonl) end,
      before_scenario: fn _ -> fresh.() end,
      after_scenario: &Glider.close/1
    }
  },
  time: 5,
  warmup: 1,
  print: [fast_warning: false]
)

# ---- export

{db, _} = Glider.Bench.social(20_000)

Benchee.run(
  %{"export_jsonl (20k people)" => fn -> Glider.export_jsonl(db) end},
  time: 3,
  warmup: 1,
  print: [fast_warning: false]
)

Glider.close(db)
