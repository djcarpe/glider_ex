# How read cost grows with the size of a label.
#
# glider is memory-resident, so nothing here is IO — this is purely how much
# memory the engine walks. The two curves that matter:
#
#   indexed point lookup — flat. The planner seeks.
#   label scan           — linear in the number of nodes carrying the label,
#                          regardless of how many rows you asked for.
#
# If you take one thing from this directory, take that pair.

Code.require_file("support.ex", __DIR__)

sizes = [10_000, 50_000, 200_000]

graphs =
  Map.new(sizes, fn n ->
    {db, _} = Glider.Bench.social(n)
    {n, db}
  end)

for {n, db} <- Enum.sort(graphs), do: Glider.Bench.describe(db, "#{n} people")
IO.puts("")

bench = fn label, fun ->
  {label,
   Map.new(sizes, fn n ->
     {"#{div(n, 1000)}k", fn -> fun.(Map.fetch!(graphs, n), n) end}
   end)}
end

{_, indexed} =
  bench.("indexed", fn db, n ->
    Glider.query(db, ~s|MATCH (p:Person {email:"#{Glider.Bench.email(div(n, 2))}"}) RETURN p|)
  end)

{_, scans} =
  bench.("scan", fn db, _n ->
    Glider.query(db, "MATCH (p:Person) RETURN count(p)")
  end)

{_, hops} =
  bench.("2 hops", fn db, _n ->
    Glider.query(db, "MATCH (p:Person)-[:KNOWS*1..2]->(f) WHERE id(p) = 100 RETURN count(f)")
  end)

IO.puts("== indexed point lookup (expect flat) ==")
Benchee.run(indexed, time: 2, warmup: 1, print: [fast_warning: false])

IO.puts("\n== label scan (expect linear) ==")
Benchee.run(scans, time: 2, warmup: 1, print: [fast_warning: false])

IO.puts("\n== 2-hop traversal (local: depends on degree, not graph size) ==")
Benchee.run(hops, time: 2, warmup: 1, print: [fast_warning: false])

Enum.each(graphs, fn {_n, db} -> Glider.close(db) end)
