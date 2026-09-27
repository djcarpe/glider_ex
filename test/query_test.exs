defmodule Glider.QueryTest do
  use ExUnit.Case, async: true

  import Glider.Query

  doctest Glider.Query

  defp seeded do
    {:ok, db} = Glider.open()

    Glider.run!(db, ~S"""
    CREATE (a:Person {name:"Ada", age:36, country:"UK"})-[:KNOWS {since:2019}]->(b:Person {name:"Bob", age:41, country:"US"})
    """)

    Glider.run!(db, ~S"""
    MATCH (a:Person {name:"Ada"}) CREATE (a)-[:KNOWS {since:2021}]->(:Person {name:"Cy", age:17, country:"UK"})
    """)

    db
  end

  describe "to_cypher/1" do
    test "pins become numbered parameters, never text" do
      min = 18
      country = "UK"

      q =
        match("(p:Person)")
        |> where(p.age >= ^min and p.country == ^country)
        |> return(p.name)

      assert to_cypher(q) ==
               {"MATCH (p:Person) WHERE (p.age >= $__1) AND (p.country = $__2) RETURN p.name",
                %{"__1" => 18, "__2" => "UK"}}
    end

    test "string literals travel as parameters too" do
      {text, params} = match("(p)") |> where(p.name == "O'Brien \" x") |> return(p) |> to_cypher()
      assert text == "MATCH (p) WHERE p.name = $__1 RETURN p"
      assert params == %{"__1" => "O'Brien \" x"}
    end

    test "several where/2 calls are ANDed, each parenthesised" do
      {text, _} =
        match("(p)")
        |> where(p.a == 1 or p.b == 2)
        |> where(not is_nil(p.c))
        |> to_cypher()

      assert text == "MATCH (p) WHERE ((p.a = 1) OR (p.b = 2)) AND (p.c IS NOT NULL) RETURN *"
    end

    test "return shapes, order, skip, limit and distinct" do
      n = 5

      {text, _} =
        match("(p:Person)-[:KNOWS]->(f)")
        |> return(name: p.name, friends: count(f))
        |> distinct()
        |> order_by(desc: :friends, asc: p.name)
        |> skip(10)
        |> limit(^n)
        |> to_cypher()

      assert text ==
               "MATCH (p:Person)-[:KNOWS]->(f) RETURN DISTINCT p.name AS name, count(f) AS friends " <>
                 "ORDER BY friends DESC, name SKIP 10 LIMIT 5"
    end

    test "functions, IN, string predicates and fragments" do
      ids = [1, 2]

      {text, params} =
        match("(p)")
        |> where(id(p) in ^ids and starts_with(lower(p.name), "a"))
        |> where(fragment("p.score * ? > 10", ^3))
        |> return({labels(p), coalesce(p.nick, p.name), count()})
        |> to_cypher()

      assert text ==
               "MATCH (p) WHERE ((id(p) IN $__1) AND (lower(p.name) STARTS WITH $__2)) AND ((p.score * $__3 > 10)) " <>
                 "RETURN labels(p), coalesce(p.nick, p.name), count(*)"

      assert params == %{"__1" => [1, 2], "__2" => "a", "__3" => 3}
    end

    test "composed queries number parameters without collisions" do
      base = match("(p:Person)") |> where(p.age > ^1)
      a = base |> where(p.country == ^"UK")
      b = base |> where(p.country == ^"US")

      assert {_, %{"__1" => 1, "__2" => "UK"}} = to_cypher(a)
      assert {_, %{"__1" => 1, "__2" => "US"}} = to_cypher(b)
    end

    test "vertex/3 and edge/5 parameterise properties" do
      {text, params} =
        create(vertex(:p, ["Person", "VIP"], name: "Ada", "odd key": 1))
        |> to_cypher()

      assert text == "CREATE (p:Person:VIP {name: $__1, `odd key`: $__2})"
      assert params == %{"__1" => "Ada", "__2" => 1}

      {text, _} =
        match("(a {name: $a}), (b {name: $b})", a: "Ada", b: "Bob")
        |> create(edge(:a, "KNOWS", :b, %{since: 2020}))
        |> to_cypher()

      assert text == "MATCH (a {name: $a}), (b {name: $b}) CREATE (a)-[:KNOWS {since: $__1}]->(b)"
    end

    test "writes" do
      age = 37

      assert {"MATCH (p {name: $n}) SET p.age = $__1, p.seen = true", %{"__1" => 37, "n" => "Ada"}} =
               match("(p {name: $n})", n: "Ada") |> set(p.age = ^age, p.seen = true) |> to_cypher()

      assert {"MATCH (p) SET p:VIP", _} = match("(p)") |> add_label(:p, "VIP") |> to_cypher()
      assert {"MATCH (p) REMOVE p.nick, p:VIP", _} =
               match("(p)") |> remove(p.nick) |> remove_label(:p, "VIP") |> to_cypher()

      assert {"MATCH (p) DETACH DELETE p", _} = match("(p)") |> delete(:p, detach: true) |> to_cypher()
    end

    test "run-time conditions and property maps" do
      field = :age

      assert {"MATCH (p) WHERE p.age >= $__1 SET p.name = $__2, p.nick = $__3", params} =
               match("(p)")
               |> where_fragment(["p.", ident(field), " >= ", {:param, 18}])
               |> set_props(:p, name: "Ada", nick: nil)
               |> to_cypher()

      assert params == %{"__1" => 18, "__2" => "Ada", "__3" => nil}
    end

    test "call/3 and explain/1" do
      assert {"CALL pagerank(iterations: $__1, top: $__2)", %{"__1" => 5, "__2" => 3}} =
               call(:pagerank, iterations: 5, top: 3) |> to_cypher()

      assert {"EXPLAIN MATCH (p) RETURN p", _} = match("(p)") |> return(p) |> explain() |> to_cypher()
    end

    test "conflicting clauses are refused" do
      assert_raise ArgumentError, ~r/one clause after MATCH/, fn ->
        match("(p)") |> return(p) |> delete(:p)
      end

      assert_raise ArgumentError, fn -> call(:wcc) |> match("(p)") end
      assert_raise ArgumentError, fn -> to_cypher(new()) end

      assert_raise ArgumentError, ~r/given twice/, fn ->
        match("(a {x: $x})", x: 1) |> match("(b {x: $x})", x: 2)
      end
    end

    test "untranslatable expressions fail at compile time" do
      assert_raise ArgumentError, ~r/cannot translate/, fn ->
        Code.eval_string("import Glider.Query; match(\"(p)\") |> where(Enum.count(p) > 1)")
      end
    end
  end

  describe "running" do
    test "all/2 shapes rows as return/2 asked" do
      db = seeded()
      q = match("(p:Person)") |> order_by(p.name)

      assert Glider.all(db, return(q, p.name)) == ["Ada", "Bob", "Cy"]
      assert Glider.all(db, return(q, [p.name, p.age])) == [["Ada", 36], ["Bob", 41], ["Cy", 17]]
      assert Glider.all(db, return(q, {p.name, p.age})) |> hd() == {"Ada", 36}
      assert Glider.all(db, return(q, name: p.name)) |> hd() == %{name: "Ada"}
    end

    test "a pinned value filters, and an aggregate groups" do
      db = seeded()
      country = "UK"

      # Ada knows Bob (US) and Cy (UK): one UK friend.
      rows =
        match("(p:Person)-[:KNOWS]->(f:Person)")
        |> where(f.country == ^country)
        |> return(who: p.name, n: count(f))
        |> Glider.all(db)

      assert rows == [%{who: "Ada", n: 1}]
    end

    test "create, set, delete end to end" do
      {:ok, db} = Glider.open()

      Glider.run!(db, create(vertex(:p, "Person", name: "Ada", age: 36)))
      Glider.run!(db, create(vertex(:p, "Person", name: "Bob", age: 41)))

      match("(a:Person {name: $a}), (b:Person {name: $b})", a: "Ada", b: "Bob")
      |> create(edge(:a, "KNOWS", :b, since: 2020))
      |> then(&Glider.run!(db, &1))

      ada = match("(p:Person)") |> where(p.name == "Ada")
      Glider.run!(db, ada |> set(p.age = ^37))
      assert Glider.one(db, ada |> return(p.age)) == 37

      assert Glider.one(db, match("(:Person)-[k:KNOWS]->(:Person)") |> return(k.since)) == 2020

      Glider.run!(db, ada |> delete(:p, detach: true))
      assert Glider.all(db, match("(p:Person)") |> return(p.name)) == ["Bob"]
    end

    test "algorithms through call/3" do
      db = seeded()
      assert {:ok, r} = Glider.query(db, call(:degree, top: 1))
      assert length(r.rows) == 1
    end

    test "a query struct takes extra params at run time" do
      db = seeded()
      q = match("(p:Person)") |> where(fragment("p.age > $min")) |> return(p.name) |> order_by(p.name)
      assert Glider.all(db, q, min: 30) == ["Ada", "Bob"]
    end

    test "query!/3 names the generated Cypher on failure" do
      {:ok, db} = Glider.open()

      err =
        assert_raise Glider.Error, fn ->
          Glider.query!(db, match("(p)") |> where(fragment("p.x = $missing")))
        end

      assert err.query =~ "MATCH (p) WHERE"
    end
  end
end
