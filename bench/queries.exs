# Read paths, and what the NIF boundary costs on top of the engine.
#
# The interesting question for a binding is not "how fast is glider" — that is
# measured in the glider repo — but how much the crossing costs: dirty-scheduler
# dispatch on the way in, and building Elixir terms on the way out.

Code.require_file("support.ex", __DIR__)

{db, n} = Glider.Bench.social(50_000)
Glider.Bench.describe(db, "graph")

probe = Glider.Bench.email(div(n, 2))

Benchee.run(
  %{
    # Fixed cost of a call: dirty-scheduler dispatch plus one row out. Whatever
    # this measures is the floor under every other number here.
    "point lookup (indexed)" => fn ->
      Glider.query(db, ~s|MATCH (p:Person {email:"#{probe}"}) RETURN p.name|)
    end,

    # Same work in the engine, but returns a node struct rather than a scalar,
    # so the delta is the cost of building %Glider.Node{} with its props map.
    "point lookup returning node" => fn ->
      Glider.query(db, ~s|MATCH (p:Person {email:"#{probe}"}) RETURN p|)
    end,

    # Aggregation in the engine: one row out regardless of graph size.
    "count all persons" => fn ->
      Glider.query(db, "MATCH (p:Person) RETURN count(p)")
    end,

    # A label scan with a predicate the engine evaluates itself.
    "filter scan" => fn ->
      Glider.query(db, ~s|MATCH (p:Person) WHERE p.age > 40 AND p.city = "London" RETURN count(p)|)
    end,

    "1 hop" => fn ->
      Glider.query(db, "MATCH (p:Person)-[:KNOWS]->(f) WHERE id(p) = 100 RETURN count(f)")
    end,
    "2 hops" => fn ->
      Glider.query(db, "MATCH (p:Person)-[:KNOWS*1..2]->(f) WHERE id(p) = 100 RETURN count(f)")
    end,
    "3 hops" => fn ->
      Glider.query(db, "MATCH (p:Person)-[:KNOWS*1..3]->(f) WHERE id(p) = 100 RETURN count(f)")
    end,

    # LIMIT does not short-circuit a label scan: the engine materialises the
    # whole label, then truncates. So these three cost about the same, and all
    # three cost about what `count all persons` costs. That is the single most
    # useful thing in this file — if you are reaching for LIMIT to make a scan
    # cheap, it will not.
    "scan LIMIT 1" => fn ->
      Glider.query(db, "MATCH (p:Person) RETURN p LIMIT 1")
    end,
    "scan LIMIT 100 (scalars)" => fn ->
      Glider.query(db, "MATCH (p:Person) RETURN p.name, p.age LIMIT 100")
    end,
    "scan LIMIT 100 (nodes)" => fn ->
      Glider.query(db, "MATCH (p:Person) RETURN p LIMIT 100")
    end,
    "scan LIMIT 1000 (nodes)" => fn ->
      Glider.query(db, "MATCH (p:Person) RETURN p LIMIT 1000")
    end,

    # expand/3 builds the same structs through a different path.
    "expand (50 neighbours)" => fn -> Glider.expand(db, 100, 50) end,
    "schema" => fn -> Glider.schema(db) end
  },
  time: 3,
  warmup: 1,
  # No memory_time: the engine allocates its results outside the BEAM heap, so
  # Benchee's process-heap delta reports the same figure for every case here
  # and measures nothing useful.
  print: [fast_warning: false]
)

Glider.close(db)
