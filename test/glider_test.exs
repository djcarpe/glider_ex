defmodule GliderTest do
  use ExUnit.Case, async: true

  doctest Glider

  @create ~S"""
  CREATE (a:Person {name:"Ada", age:36})-[:KNOWS {since:2019}]->(b:Person {name:"Bob", age:41})
  """

  @live_in ~S"""
  MATCH (a:Person {name:"Ada"}) CREATE (a)-[:LIVES_IN]->(:City {name:"London"})
  """

  defp seeded do
    {:ok, db} = Glider.open()
    {:ok, _} = Glider.run(db, @create)
    {:ok, _} = Glider.run(db, @live_in)
    db
  end

  describe "lifecycle" do
    test "reports the engine version" do
      assert Glider.version() =~ ~r/^\d+\.\d+\.\d+$/
    end

    test "graphs are isolated from one another" do
      {:ok, a} = Glider.open()
      {:ok, b} = Glider.open()
      {:ok, _} = Glider.run(a, ~S|CREATE (:Only {in:"a"})|)

      assert {:ok, %{"nodes" => 1}} = Glider.stats(a)
      assert {:ok, %{"nodes" => 0}} = Glider.stats(b)
    end

    test "close is idempotent and later calls report it" do
      {:ok, db} = Glider.open()
      assert :ok = Glider.close(db)
      assert :ok = Glider.close(db)
      assert {:error, "this graph is closed"} = Glider.query(db, "MATCH (n) RETURN n")
    end
  end

  describe "queries" do
    test "nodes and relationships come back as structs" do
      db = seeded()
      {:ok, r} = Glider.query(db, "MATCH (a)-[r:KNOWS]->(b) RETURN a, r, b")

      assert [%Glider.Node{} = a, %Glider.Rel{} = rel, %Glider.Node{} = b] = hd(r.rows)
      assert a.labels == ["Person"]
      assert a.props == %{"name" => "Ada", "age" => 36}
      assert rel.type == "KNOWS"
      assert rel.props == %{"since" => 2019}
      assert rel.from == a.id
      assert rel.to == b.id
    end

    test "properties are a map keyed by binary, never atoms" do
      # Atoms are never garbage collected, so user-controlled keys must not
      # become them. This is the regression guard for that.
      db = seeded()
      {:ok, r} = Glider.query(db, "MATCH (p:Person) RETURN p LIMIT 1")
      [%Glider.Node{props: props}] = hd(r.rows)

      assert is_map(props)
      assert Enum.all?(Map.keys(props), &is_binary/1)
    end

    test "scalars stay native terms" do
      db = seeded()
      {:ok, r} = Glider.query(db, "MATCH (p:Person) RETURN p.name, p.age ORDER BY p.age")

      assert r.columns == ["p.name", "p.age"]
      assert r.rows == [["Ada", 36], ["Bob", 41]]
    end

    test "the graph projection is deduplicated and closed over endpoints" do
      db = seeded()

      # Returns only the relationship; both endpoints must still arrive.
      {:ok, g} = Glider.graph(db, "MATCH ()-[r:KNOWS]->() RETURN r")
      assert length(g.edges) == 1
      assert length(g.nodes) == 2

      # Ada appears in two rows but must count once.
      {:ok, all} = Glider.graph(db, "MATCH (a)-[r]->(b) RETURN a, r, b")
      assert length(all.nodes) == 3
      assert length(all.edges) == 2
    end

    test "a text property that mimics a node is not turned into one" do
      # glider's Value has no entity variant, so a node renders to a JSON
      # string. Classification is byte-equality against the live entity, which
      # is what stops a crafted string from being promoted to a struct.
      {:ok, db} = Glider.open()
      decoy = ~S|{"id":0,"labels":["Person"],"props":{}}|
      escaped = String.replace(decoy, "\"", "\\\"")
      {:ok, _} = Glider.run(db, ~s|CREATE (:Decoy {trap:"#{escaped}"})|)

      {:ok, r} = Glider.query(db, "MATCH (d:Decoy) RETURN d.trap")
      assert [cell] = hd(r.rows)
      assert is_binary(cell), "decoy should stay a string, got: #{inspect(cell)}"
      assert r.graph.nodes == []
    end

    test "run/2 reports entities touched" do
      {:ok, db} = Glider.open()
      assert {:ok, 3} = Glider.run(db, "CREATE (:A)-[:R]->(:B)")
    end

    test "query!/2 raises Glider.Error" do
      {:ok, db} = Glider.open()
      assert_raise Glider.Error, fn -> Glider.query!(db, "MATCH ((((") end
    end

    test "a syntax error leaves the handle usable" do
      db = seeded()
      assert {:error, reason} = Glider.query(db, "MATCH ((((")
      assert reason =~ "expected"
      assert {:ok, %{rows: [[2]]}} = Glider.query(db, "MATCH (p:Person) RETURN count(p)")
    end
  end

  describe "schema and expand" do
    test "schema lists labels and relationship types with counts" do
      db = seeded()
      {:ok, s} = Glider.schema(db)

      assert Enum.sort_by(s.labels, & &1.name) == [
               %{name: "City", count: 1},
               %{name: "Person", count: 2}
             ]

      assert Enum.sort_by(s.edge_types, & &1.name) == [
               %{name: "KNOWS", count: 1},
               %{name: "LIVES_IN", count: 1}
             ]
    end

    test "expand walks both directions" do
      db = seeded()
      {:ok, r} = Glider.query(db, ~S|MATCH (p:Person {name:"Ada"}) RETURN p|)
      [%Glider.Node{id: ada}] = hd(r.rows)

      {:ok, out} = Glider.expand(db, ada)
      assert length(out.edges) == 2

      {:ok, r2} = Glider.query(db, ~S|MATCH (p:Person {name:"Bob"}) RETURN p|)
      [%Glider.Node{id: bob}] = hd(r2.rows)

      # Bob has only an inbound KNOWS; expand must still find it.
      {:ok, inbound} = Glider.expand(db, bob)
      assert length(inbound.edges) == 1
    end

    test "expanding an unknown node is an error" do
      db = seeded()
      assert {:error, reason} = Glider.expand(db, 9_999_999)
      assert reason =~ "no node with id"
    end
  end

  describe "persistence" do
    @tag :tmp_dir
    test "a file graph survives close and reopen", %{tmp_dir: dir} do
      path = Path.join(dir, "social.gldb")

      {:ok, db} = Glider.open(path, :always)
      {:ok, _} = Glider.run(db, @create)
      :ok = Glider.checkpoint(db)
      :ok = Glider.close(db)

      {:ok, db2} = Glider.open(path)
      assert {:ok, %{"nodes" => 2, "edges" => 1}} = Glider.stats(db2)
      :ok = Glider.close(db2)
    end

    @tag :tmp_dir
    test "a second writer is refused while the first holds the file", %{tmp_dir: dir} do
      path = Path.join(dir, "locked.gldb")
      {:ok, db} = Glider.open(path)

      assert {:error, reason} = Glider.open(path)
      assert is_binary(reason)

      # ...and is allowed once the first handle lets go.
      :ok = Glider.close(db)
      assert {:ok, db2} = Glider.open(path)
      :ok = Glider.close(db2)
    end

    @tag :tmp_dir
    test "checkpoint preserves state across reopen", %{tmp_dir: dir} do
      path = Path.join(dir, "c.gldb")
      {:ok, db} = Glider.open(path, cache_size: "16M", checkpoint: :off)
      {:ok, _} = Glider.run(db, @create)
      {:ok, _} = Glider.run(db, ~S|MATCH (p:Person {name:"Bob"}) DETACH DELETE p|)

      assert :ok = Glider.checkpoint(db)
      assert {:ok, %{"nodes" => 1}} = Glider.stats(db)
      :ok = Glider.close(db)

      {:ok, db2} = Glider.open(path, sync: :always)
      assert {:ok, %{"nodes" => 1}} = Glider.stats(db2)
      :ok = Glider.close(db2)
    end

    @tag :tmp_dir
    test "bad open options are refused", %{tmp_dir: dir} do
      path = Path.join(dir, "o.gldb")
      assert_raise ArgumentError, fn -> Glider.open(path, sync: :sometimes) end
      assert_raise ArgumentError, fn -> Glider.open(path, cache_size: "lots") end
    end

    test "an in-memory graph can be capped" do
      {:ok, db} = Glider.open(max_memory: "64M")
      assert {:ok, 1} = Glider.run(db, "CREATE (:A)")
    end
  end

  describe "parameters" do
    test "values bind by name, from a keyword list or a map" do
      db = seeded()
      q = "MATCH (p:Person) WHERE p.age > $min RETURN p.name"
      assert Glider.all(db, q, min: 40) == [["Bob"]]
      assert Glider.all(db, q, %{"min" => 30}) |> Enum.sort() == [["Ada"], ["Bob"]]
    end

    test "a value that looks like Cypher stays a value" do
      {:ok, db} = Glider.open()
      evil = ~S|x"}) DETACH DELETE n //|
      {:ok, 1} = Glider.run(db, "CREATE (:T {s: $s})", s: evil)
      assert Glider.one(db, "MATCH (t:T) RETURN t.s") == [evil]
    end

    test "lists, nil and booleans round-trip" do
      {:ok, db} = Glider.open()
      {:ok, _} = Glider.run(db, "CREATE (:T {xs: $xs, b: $b, n: $n})", xs: [1, 2, 3], b: true, n: nil)
      assert [[[1, 2, 3], true]] = Glider.all(db, "MATCH (t:T) RETURN t.xs, t.b")
    end

    test "a missing parameter is an error" do
      {:ok, db} = Glider.open()
      assert {:error, reason} = Glider.query(db, "MATCH (n) WHERE n.x = $nope RETURN n")
      assert reason =~ "missing parameter"
    end

    test "one/3 raises on several rows" do
      db = seeded()
      assert_raise Glider.Error, fn -> Glider.one(db, "MATCH (p:Person) RETURN p.name") end
      assert Glider.one(db, "MATCH (p:Person {name: $n}) RETURN p.age", n: "Nobody") == nil
    end
  end

  describe "transactions" do
    test "commit makes every statement visible at once" do
      {:ok, db} = Glider.open()

      assert {:ok, :done} =
               Glider.transaction(db, fn ->
                 Glider.run!(db, "CREATE (:Acct {id: 1})")
                 Glider.run!(db, "CREATE (:Acct {id: 2})")
                 :done
               end)

      assert {:ok, %{"nodes" => 2}} = Glider.stats(db)
    end

    test "rollback/2 discards the work and returns its value" do
      {:ok, db} = Glider.open()

      assert {:error, :nope} =
               Glider.transaction(db, fn ->
                 Glider.run!(db, "CREATE (:Acct)")
                 Glider.rollback(db, :nope)
               end)

      assert {:ok, %{"nodes" => 0}} = Glider.stats(db)
      refute Glider.in_transaction?(db)
    end

    test "an exception rolls back and re-raises" do
      {:ok, db} = Glider.open()

      assert_raise RuntimeError, "boom", fn ->
        Glider.transaction(db, fn ->
          Glider.run!(db, "CREATE (:Acct)")
          raise "boom"
        end)
      end

      assert {:ok, %{"nodes" => 0}} = Glider.stats(db)
    end

    test "a failed statement aborts the transaction" do
      {:ok, db} = Glider.open()

      assert {:error, reason} =
               Glider.transaction(db, fn ->
                 Glider.run(db, "CREATE (:Acct)")
                 Glider.run(db, "MATCH ((((")
                 :ok
               end)

      assert reason =~ "aborted"
      assert {:ok, %{"nodes" => 0}} = Glider.stats(db)
    end

    test "nested transactions join the outer one" do
      {:ok, db} = Glider.open()

      {:ok, {:ok, 1}} =
        Glider.transaction(db, fn ->
          Glider.transaction(db, fn -> Glider.run!(db, "CREATE (:A)") end)
        end)

      assert {:ok, %{"nodes" => 1}} = Glider.stats(db)
    end

    test "another process waits for the transaction to finish" do
      {:ok, db} = Glider.open()
      parent = self()

      Glider.transaction(db, fn ->
        Glider.run!(db, "CREATE (:A)")

        spawn(fn ->
          send(parent, {:reader_started, System.monotonic_time(:millisecond)})
          {:ok, s} = Glider.stats(db)
          send(parent, {:reader_saw, s["nodes"], System.monotonic_time(:millisecond)})
        end)

        assert_receive {:reader_started, _}
        Process.sleep(100)
        refute_received {:reader_saw, _, _}
      end)

      assert_receive {:reader_saw, 1, _}, 2_000
    end

    test "a transaction owner that dies is rolled back" do
      {:ok, db} = Glider.open()

      {pid, ref} =
        spawn_monitor(fn ->
          :ok = elem(Glider.Native.begin(db), 1)
          Glider.run!(db, "CREATE (:Orphan)")
          exit(:crash)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :crash}
      assert {:ok, %{"nodes" => 0}} = Glider.stats(db)
    end
  end

  describe "jsonl" do
    test "export then import reproduces the graph" do
      src = seeded()
      {:ok, dump} = Glider.export_jsonl(src)
      assert dump =~ "Ada"

      {:ok, dst} = Glider.open()
      assert {:ok, {3, 2}} = Glider.import_jsonl(dst, dump)
      assert Glider.stats(dst) == Glider.stats(src)
    end

    test "malformed jsonl is an error, not a crash" do
      {:ok, db} = Glider.open()
      assert {:error, reason} = Glider.import_jsonl(db, "{not json at all")
      assert is_binary(reason)
    end
  end

  describe "algorithms" do
    test "pagerank runs and writes back" do
      db = seeded()
      {:ok, _} = Glider.query(db, ~S|CALL pagerank(iterations: 10, write: "rank")|)
      {:ok, r} = Glider.query(db, "MATCH (p:Person) RETURN p.name, p.rank ORDER BY p.rank DESC")

      assert length(r.rows) == 2
      assert [_name, rank] = hd(r.rows)
      assert is_float(rank)
    end
  end

  describe "concurrency" do
    test "one handle survives concurrent access from many processes" do
      # The NIF serialises on a mutex; this asserts that holds up rather than
      # corrupting the graph or crashing the VM.
      {:ok, db} = Glider.open()

      1..50
      |> Task.async_stream(fn i -> Glider.run(db, "CREATE (:N {i: #{i}})") end,
        max_concurrency: 16,
        timeout: 30_000
      )
      |> Stream.run()

      assert {:ok, %{"nodes" => 50}} = Glider.stats(db)

      # And concurrent reads agree with each other.
      results =
        1..50
        |> Task.async_stream(fn _ -> Glider.query(db, "MATCH (n:N) RETURN count(n)") end,
          max_concurrency: 16,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, {:ok, r}} -> r.rows end)

      assert Enum.uniq(results) == [[[50]]]
    end
  end
end
