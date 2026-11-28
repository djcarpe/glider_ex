defmodule Glider.StructureTest do
  use ExUnit.Case, async: true

  alias Glider.Structure
  alias Glider.Structure.{Colouring, Compact, Dictionary, Plan, Slice, Stale}

  @types ["HAS_SIDE", "HAS_ELEMENT"]

  # Six stations built to one design: two sides, each with two work
  # elements whose names and instructions are the same at every station.
  defp plant(opts \\ []) do
    {:ok, db} = Glider.open()
    :ok = Structure.install(db)
    if opts[:changes], do: :ok = Glider.Changes.install(db)

    for s <- 1..6 do
      Glider.run!(
        db,
        """
        CREATE (st:Station {code: $code, name: 'Battery tray torque cell'}),
          (st)-[:HAS_SIDE]->(l:Side {name: 'Left side of the line', code: $l}),
          (st)-[:HAS_SIDE]->(r:Side {name: 'Right side of the line', code: $r}),
          (l)-[:HAS_ELEMENT]->(:Element {name: 'Torque the four tray bolts to 25 Nm', code: $l1}),
          (l)-[:HAS_ELEMENT]->(:Element {name: 'Check the tray seats flush on its posts', code: $l2}),
          (r)-[:HAS_ELEMENT]->(:Element {name: 'Torque the four tray bolts to 25 Nm', code: $r1}),
          (r)-[:HAS_ELEMENT]->(:Element {name: 'Check the tray seats flush on its posts', code: $r2})
        """,
        code: "ST0#{s}",
        l: "ST0#{s}-L",
        r: "ST0#{s}-R",
        l1: "ST0#{s}-L1",
        l2: "ST0#{s}-L2",
        r1: "ST0#{s}-R1",
        r2: "ST0#{s}-R2"
      )
    end

    db
  end

  defp station(db, code) do
    [[id]] = Glider.all(db, "MATCH (s:Station {code: $c}) RETURN id(s)", c: code)

    ids =
      Glider.all(db, "MATCH (s:Station {code: $c})-[*1..2]->(x) RETURN id(x)", c: code)
      |> List.flatten()

    {id, Enum.sort([id | ids])}
  end

  describe "colours" do
    test "colours, kept colourings read in slices and as a stream, freshness, drop" do
      db = plant()

      assert {:ok, %Slice{rows: rows, complete: true, after: nil}} =
               Structure.colors(db, depth: 2, types: @types, labels: ["Station"])

      assert length(rows) == 6
      assert [%{"id" => _, "color" => c} | _] = rows
      assert Enum.all?(rows, &(&1["color"] == c))

      {:ok, %Slice{rows: all}} = Structure.colors(db, depth: :stable, store: "designs")

      assert {:ok, [%Colouring{name: "designs", fresh: true, nodes: n} = kept]} =
               Structure.stored(db)

      assert n == length(all) and is_integer(kept.revision) and is_map(kept.args)

      assert {:ok, %Slice{rows: whole, complete: true, kept: %Colouring{fresh: true}}} =
               Structure.read(db, "designs")

      assert whole == all

      # slices by hand, each cursor passed back as given
      sliced =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            {:ok, %Slice{rows: rows} = s} = Structure.read(db, "designs", limit: 7, after: cursor)
            assert length(rows) <= 7
            {rows, if(s.complete, do: :done, else: s.after)}
        end)
        |> Enum.concat()

      assert sliced == whole
      assert db |> Structure.stream({:read, "designs"}, limit: 5) |> Enum.to_list() == whole
      assert db |> Structure.stream(:colors, depth: :stable, limit: 4) |> Enum.to_list() == all

      # a write makes it stale; require refuses it with a distinct error
      Glider.run!(db, "CREATE (:Elsewhere)")
      assert {:ok, [%Colouring{fresh: false}]} = Structure.stored(db)

      assert {:ok, %Slice{rows: ^whole, kept: %Colouring{fresh: false}}} =
               Structure.read(db, "designs")

      assert {:error, %Stale{kind: :colouring, name: "designs"}} =
               Structure.read(db, "designs", fresh: :require)

      assert {:error, %Stale{}} =
               Structure.classes(db, by: :colors, colors: "designs", fresh: :require)

      assert_raise Stale, fn ->
        db |> Structure.stream({:read, "designs"}, fresh: :require) |> Enum.to_list()
      end

      assert :ok = Structure.drop(db, "designs")
      assert {:ok, []} = Structure.stored(db)
    end

    test "with the change journal, only a node or edge change makes a colouring stale" do
      db = plant(changes: true)
      {:ok, _} = Structure.colors(db, store: "a")
      {:ok, _} = Structure.colors(db, depth: 1, store: "b")
      # keeping another, and an index, leave it fresh
      Glider.run!(db, "CREATE INDEX ON :Station(code)")
      assert {:ok, %Slice{kept: %Colouring{fresh: true}}} = Structure.read(db, "a")
      Glider.run!(db, "MATCH (s:Station {code: 'ST01'}) SET s.note = 'x'")
      assert {:ok, %Slice{kept: %Colouring{fresh: false}}} = Structure.read(db, "a")
    end

    test "classes by neighbours and by colours" do
      db = plant()

      {:ok, %Slice{rows: [%{"size" => 6, "members" => members}], complete: true}} =
        Structure.classes(db, by: :colors, depth: 2, types: @types, labels: ["Station"])

      assert length(members) == 6

      Glider.run!(
        db,
        "MATCH (e:Element {code: 'ST01-L1'}) CREATE (e)-[:USES]->(:Tool {name: 't'})"
      )

      Glider.run!(db, "MATCH (e:Element {code: 'ST02-L1'}), (t:Tool) CREATE (e)-[:USES]->(t)")

      users =
        Glider.all(db, "MATCH (e:Element)-[:USES]->() RETURN id(e)")
        |> List.flatten()
        |> Enum.sort()

      {:ok, %Slice{rows: rows}} =
        Structure.classes(db, labels: ["Element"], keys: ["name"], types: ["USES"])

      # the two that use the one tool are told apart from the rest by it
      assert %{"size" => 2} = Enum.find(rows, &(Enum.sort(&1["members"]) == users))
    end
  end

  describe "templates, expand and paths" do
    test "a repeated shape is a template whose instances expand to their nodes" do
      db = plant()

      {:ok, %Slice{rows: [t | _], complete: true}} =
        Structure.templates(db, types: @types, labels: ["Station"])

      assert %{"template" => id, "instances" => 6, "nodes" => 7, "root" => "Station"} = t

      assert db
             |> Structure.stream(:templates, types: @types, labels: ["Station"])
             |> Enum.take(1) == [t]

      {:ok, %Slice{rows: instances}} =
        Structure.templates(db, types: @types, labels: ["Station"], instances: id)

      assert length(instances) == 6

      {root, ids} = station(db, "ST03")
      {:ok, rows} = Structure.expand(db, id, root: root, types: @types, labels: ["Station"])
      nodes = for %{"kind" => "node"} = r <- rows, do: r
      assert Enum.sort(Enum.map(nodes, & &1["id"])) == ids

      assert Enum.any?(
               nodes,
               &(&1["props"] == %{"code" => "ST03", "name" => "Battery tray torque cell"})
             )

      assert length(for %{"kind" => "edge"} <- rows, do: 1) == 6

      assert {:error, reason} = Structure.expand(db, id, root: hd(ids -- [root]), types: @types)
      assert is_binary(reason)
    end

    test "path patterns and chains" do
      db = plant()

      {:ok, %Slice{rows: [p | _]}} = Structure.paths(db, types: @types)

      assert %{"path" => "(:Station) -HAS_SIDE-> (:Side) -HAS_ELEMENT-> (:Element)", "hops" => 2} =
               p

      {:ok, %Slice{rows: chains, complete: true}} =
        Structure.paths(db, kind: :chains, types: @types)

      assert is_list(chains)
    end
  end

  describe "the plan and the compact notation" do
    test "a selection's text names its dictionary by hash and describes the same nodes as plain" do
      db = plant()

      {:ok, %Plan{total: total, candidates: cands, complete: true}} =
        Structure.plan(db, types: @types, store: "plant")

      assert %{"chosen" => true, "id" => hash} = total
      assert Enum.any?(cands, &(&1["chosen"] == true))

      assert {:ok, [%Dictionary{name: "plant", hash: ^hash, fresh: true} = d]} =
               Structure.dictionaries(db)

      {_root, ids} = station(db, "ST04")

      assert {:ok, %Compact{text: text, hash: ^hash, fresh: true, dictionary: "plant"} = c} =
               Structure.compact(db, ids, "plant")

      assert text =~ ~r/\A# glider-compact\/1 dictionary #{hash}\n/
      assert c.bytes == byte_size(text) and c.revision == d.revision
      assert c.saving_bytes == c.plain_bytes - c.bytes and c.saving_bytes > 0

      {:ok, %Plan{total: %{"text" => plain}, kept: %Dictionary{name: "plant"}}} =
        Structure.plan(db, dictionary: "plant", nodes: ids, text: :plain)

      assert byte_size(plain) == c.plain_bytes
      refute plain =~ "dictionary"
      # the same nodes: every node of the selection, once, in both forms
      assert written(plain) == ids
      assert written(text) == ids

      # the dictionary's own text, given to a reader once
      assert {:ok, dict} = Structure.dictionary_text(db, "plant")
      assert byte_size(dict) == d.bytes
      assert dict =~ ~r/^T1 #[0-9a-f]{16}$/m
    end

    test "a stale dictionary is reported, refused with fresh: :require, and costs uses not truth" do
      db = plant()
      {:ok, _} = Structure.plan(db, types: @types, store: "plant")
      {_root, ids} = station(db, "ST05")
      {:ok, %Compact{text: before}} = Structure.compact(db, ids, "plant")

      Glider.run!(db, "MATCH (s:Station {code: 'ST05'}) SET s.name = 'Rebuilt'")

      assert {:error, %Stale{kind: :dictionary, name: "plant"}} =
               Structure.compact(db, ids, "plant", fresh: :require)

      assert {:error, %Stale{}} = Structure.dictionary_text(db, "plant", fresh: :require)

      assert {:ok, %Compact{fresh: false, text: text}} = Structure.compact(db, ids, "plant")
      assert text != before and text =~ "Rebuilt"
      assert written(text) == ids
    end

    test "inside a caller's transaction a compact text and a refusal leave it to commit" do
      db = plant()
      {:ok, _} = Structure.plan(db, types: @types, store: "plant")
      {_root, ids} = station(db, "ST02")

      assert {:ok, {:ok, %Compact{}}} =
               Glider.transaction(db, fn ->
                 Glider.run!(db, "CREATE (:Mine)")
                 assert {:error, %Stale{}} = Structure.compact(db, ids, "plant", fresh: :require)
                 assert {:error, _} = Structure.compact(db, ids, "nope")
                 Structure.compact(db, ids, "plant")
               end)

      assert [[1]] = Glider.all(db, "MATCH (m:Mine) RETURN count(m)")
    end
  end

  test "options are allow-listed, values checked, and the budget passed on" do
    db = plant()

    assert {:error, "Glider.Structure.colors/2 has no option :bogus"} =
             Structure.colors(db, bogus: 1)

    assert {:error, "Glider.Structure.compact/4 has no option :text"} =
             Structure.compact(db, [], "p", text: :plain)

    assert {:error, "Glider.Structure.read/3 has no option :name"} =
             Structure.read(db, "x", name: "y")

    assert {:error, "nodes: must be" <> _} = Structure.compact(db, [-1], "p")
    assert {:error, "limit: must be" <> _} = Structure.templates(db, limit: 0)
    assert_raise ArgumentError, fn -> Structure.stream(db, :colors, after: "x") end
    # accepted and passed on; the engine this was built on does not yet
    # count steps in structure's procedures, so nothing here stops them
    assert {:ok, %Slice{}} = Structure.templates(db, types: @types, max_steps: 1)
    assert_raise ArgumentError, fn -> Structure.templates(db, types: @types, max_steps: -1) end

    assert {:ok, %Slice{}} =
             Structure.paths(db, types: @types, max_millis: 10_000, max_steps: 10_000_000)

    {:ok, bare} = Glider.open()
    assert {:error, reason} = Structure.colors(bare)
    assert reason =~ "CREATE EXTENSION structure"
  end

  # The node ids a glider-compact/1 text writes: a card's handle (`n12:`)
  # or a use's id list (`T3 n7..9,12 ...`), each node once.
  defp written(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        m = Regex.run(~r/^n(\d+):/, line) -> [String.to_integer(Enum.at(m, 1))]
        m = Regex.run(~r/^T\d+ n([\d.,]+)/, line) -> runs(Enum.at(m, 1))
        true -> []
      end
    end)
    |> then(fn ids ->
      assert ids == Enum.uniq(ids)
      Enum.sort(ids)
    end)
  end

  defp runs(list) do
    list
    |> String.split(",")
    |> Enum.flat_map(fn part ->
      case String.split(part, "..") do
        [a, b] -> Enum.to_list(String.to_integer(a)..String.to_integer(b))
        [a] -> [String.to_integer(a)]
      end
    end)
  end
end
