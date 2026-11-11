defmodule Glider.BoundedTest do
  use ExUnit.Case, async: true

  defp seeded(n) do
    {:ok, db} = Glider.open()
    statements = for i <- 1..n, do: {"CREATE (:N {i: $i})", %{i: i}}
    assert {:ok, ^n} = Glider.write_batch(db, statements)
    db
  end

  test "write_batch is one atomic slice" do
    db = seeded(10)

    assert {:error, _} =
             Glider.write_batch(db, [{"CREATE (:N {i: 11})", %{}}, {"NOT CYPHER", %{}}])

    assert {:ok, %{rows: [[10]]}} = Glider.query(db, "MATCH (n:N) RETURN count(n)")
  end

  test "query/4 refuses a result past max_rows; stream/4 takes it in batches" do
    db = seeded(250)
    q = "MATCH (n:N) RETURN n.i"

    assert {:error, _} = Glider.query(db, q, %{}, max_rows: 100)

    batches = db |> Glider.stream(q, %{}, max_rows: 100) |> Enum.to_list()
    assert Enum.all?(batches, &(length(&1.rows) <= 100))

    assert batches |> Enum.flat_map(& &1.rows) |> List.flatten() |> Enum.sort() ==
             Enum.to_list(1..250)
  end

  test "a cursor closes more than once" do
    db = seeded(5)
    {:ok, cursor} = Glider.cursor(db, "MATCH (n:N) RETURN n.i")
    assert {:ok, {%{rows: rows}, true}} = Glider.cursor_next(cursor)
    assert length(rows) == 5
    Glider.cursor_close(cursor)
    Glider.cursor_close(cursor)
  end

  test "the graph of a result is there when asked for" do
    db = seeded(1)
    assert {:ok, without} = Glider.query(db, "MATCH (n:N) RETURN n")
    assert {:ok, with_graph} = Glider.query(db, "MATCH (n:N) RETURN n", %{}, graph: true)
    assert length(with_graph.graph.nodes) == 1
    refute without.graph == with_graph.graph
  end

  test "memory_budget reports the process budget in bytes" do
    budget = Glider.memory_budget()
    assert budget.limit_bytes > 0
    assert budget.cache_limit_bytes > 0
  end

  test "export_file and import_file round-trip, and export refuses to overwrite" do
    db = seeded(20)

    path =
      Path.join(System.tmp_dir!(), "glider-bounded-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)

    assert {:ok, _} = Glider.export_file(db, path)
    assert {:error, _} = Glider.export_file(db, path)

    {:ok, other} = Glider.open()
    assert {:ok, %{nodes: 20, edges: 0}} = Glider.import_file(other, path)
  end
end
