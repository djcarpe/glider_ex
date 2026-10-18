defmodule Glider.ContextTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, db} = Glider.open()

    Glider.run!(db, """
    CREATE (ada:Person {name: "Ada Lovelace", born: 1815, embedding: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]})
    """)

    Glider.run!(db, ~s|CREATE (:Person {name: "Charles Babbage", born: 1791})|)
    Glider.run!(db, ~s|CREATE (:Machine {name: "Analytical Engine", status: "design"})|)
    Glider.run!(db, ~s|CREATE (:Machine {name: "Difference Engine", status: "built"})|)

    Glider.run!(db, """
    MATCH (a:Person), (b:Person) WHERE a.name = "Ada Lovelace" AND b.name = "Charles Babbage"
    CREATE (a)-[:KNEW {since: 1833}]->(b)
    """)

    Glider.run!(
      db,
      ~s|MATCH (p:Person), (m:Machine) WHERE p.name = "Charles Babbage" CREATE (p)-[:DESIGNED]->(m)|
    )

    %{db: db}
  end

  test "procedures need the extension installed", %{db: db} do
    assert {:error, msg} = Glider.Context.retrieve(db, seeds: [1])
    assert msg =~ "CREATE EXTENSION context"
    assert :ok = Glider.Context.install(db)
    assert :ok = Glider.Context.install(db)
    assert {:ok, exts} = Glider.extensions(db)
    assert %{name: "context", installed: "1.0"} = Enum.find(exts, &(&1.name == "context"))
  end

  test "retrieve returns compact text with refs to pass back", %{db: db} do
    :ok = Glider.Context.install(db)
    assert {:ok, ctx} = Glider.Context.retrieve(db, query: "Ada Lovelace", budget: 400)
    assert ctx.text =~ "# context:"
    assert ctx.text =~ ~s|n1:Person name="Ada Lovelace"|
    assert ctx.text =~ "embedding=<vector 8>"
    assert ctx.text =~ "n1 -KNEW{since=1833}-> n2"
    assert "n1" in ctx.refs and "n2" in ctx.refs
    assert ctx.tokens <= 400

    # Nodes already shown are linked to, not described again.
    assert {:ok, more} = Glider.Context.retrieve(db, seeds: ["n2"], seen: ctx.refs, budget: 400)
    refute more.text =~ ~s|n1:Person|
  end

  test "json and rows formats", %{db: db} do
    :ok = Glider.Context.install(db)

    assert {:ok, %{"nodes" => nodes, "edges" => _}} =
             Glider.Context.retrieve(db, seeds: [1], format: "json")

    assert Enum.any?(nodes, &(&1["id"] == 1))

    assert {:ok, [%{id: 1, ref: "n1", hops: 0} | _]} =
             Glider.Context.retrieve(db, seeds: [1], format: :rows)
  end

  test "search, through a scan and through the index", %{db: db} do
    :ok = Glider.Context.install(db)

    assert {:ok, [%{id: 3, ref: "n3", name: "Analytical Engine"} | _]} =
             Glider.Context.search(db, "analytical")

    assert {:ok, msg} = Glider.Context.index(db)
    assert msg =~ "indexed 4 nodes"
    assert {:ok, [%{id: 3} | _]} = Glider.Context.search(db, "analytical")
    # Writes keep the index current, including inside transactions.
    {:ok, _} =
      Glider.transaction(db, fn ->
        Glider.run!(db, ~s|CREATE (:Machine {name: "Jacquard Loom"})|)
      end)

    assert {:ok, [%{name: "Jacquard Loom"}]} = Glider.Context.search(db, "jacquard")
    assert :ok = Glider.Context.unindex(db)
  end

  test "paths and schema", %{db: db} do
    :ok = Glider.Context.install(db)
    assert {:ok, p} = Glider.Context.paths(db, "n1", 4)
    assert p.text =~ "n1 -KNEW{since=1833}-> n2 -DESIGNED-> n4"
    assert {:ok, card} = Glider.Context.schema(db)
    assert card =~ "(:Person)-[:KNEW {since:int}]->(:Person)"
  end

  test "functions in queries, and the query builder", %{db: db} do
    :ok = Glider.Context.install(db)

    assert [[~s|n2:Person name="Charles Babbage" born=1791|]] =
             Glider.all(db, ~s|MATCH (p:Person) WHERE p.born < 1800 RETURN context.card(p)|)

    assert {:ok, n} = Glider.Context.tokens(db, "hello world")
    assert n in 2..4

    import Glider.Query
    assert {:ok, r} = call(:"context.search", query: "babbage") |> Glider.query(db)
    assert [[2, "n2" | _]] = r.rows
  end

  test "bad arguments are refused before they reach the engine", %{db: db} do
    :ok = Glider.Context.install(db)
    assert {:error, msg} = Glider.Context.retrieve(db, seeds: [1], nonsense: 1)
    assert msg =~ "no argument :nonsense"
    assert {:error, _} = Glider.create_extension(db, "x; CLEAR")
  end
end
