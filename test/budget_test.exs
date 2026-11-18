defmodule Glider.BudgetTest do
  # A statement's own budget (`:max_millis`, `:max_steps`): matching stops and
  # the database is released, however long the statement would have run.
  use ExUnit.Case, async: true

  @heavy "MATCH (a:N), (b:N) WHERE a.i = b.i + 100000 RETURN count(*)"

  defp seeded(n) do
    {:ok, db} = Glider.open()

    for chunk <- Enum.chunk_every(1..n, 1_000) do
      statements = for i <- chunk, do: {"CREATE (:N {i: $i})", %{i: i}}
      {:ok, _} = Glider.write_batch(db, statements)
    end

    db
  end

  test "query/4 stops a heavy statement at max_millis, and the database answers after" do
    db = seeded(4_000)
    {us, result} = :timer.tc(fn -> Glider.query(db, @heavy, %{}, max_millis: 100) end)
    assert {:error, "statement stopped: it ran past its time budget of 100 ms"} = result
    assert us < 2_000_000
    assert {:ok, %{rows: [[4_000]]}} = Glider.query(db, "MATCH (n:N) RETURN count(n)")
  end

  test "cursor/4 stops at its budget too, by time or by steps" do
    db = seeded(4_000)
    {us, result} = :timer.tc(fn -> Glider.cursor(db, @heavy, %{}, max_millis: 100) end)
    assert {:error, "statement stopped: " <> _} = result
    assert us < 2_000_000

    assert {:error, "statement stopped: it took more than its budget of 1000 matching steps"} =
             Glider.cursor(db, @heavy, %{}, max_steps: 1_000)
  end

  test "within its budget, or without one, a statement answers as before" do
    db = seeded(100)

    assert {:ok, %{rows: [[100]]}} =
             Glider.query(db, "MATCH (n:N) RETURN count(n)", %{},
               max_millis: 5_000,
               max_steps: 1_000_000
             )

    {:ok, c} = Glider.cursor(db, "MATCH (n:N) RETURN n.i", %{}, max_millis: 5_000)
    assert {:ok, {%{rows: [_ | _]}, _}} = Glider.cursor_next(c)

    assert_raise ArgumentError, fn ->
      Glider.query(db, "MATCH (n) RETURN n", %{}, max_steps: -1)
    end
  end

  test "candidates rejected before any match count against both budgets" do
    {:ok, db} = Glider.open()

    for chunk <- Enum.chunk_every(1..30_000, 1_000) do
      {:ok, _} =
        Glider.write_batch(
          db,
          for(i <- chunk, do: {"CREATE (:Function {name: $n})", %{n: "fn_#{i}"}})
        )
    end

    q = "MATCH (a:Function), (b:Function {name:'zzz'}) RETURN count(*)"
    {us, result} = :timer.tc(fn -> Glider.cursor(db, q, %{}, max_millis: 1_000) end)
    assert {:error, "statement stopped: it ran past its time budget of 1000 ms"} = result
    assert us < 1_300_000

    {us, result} = :timer.tc(fn -> Glider.query(db, q, %{}, max_steps: 100_000) end)
    assert {:error, "statement stopped: " <> _} = result
    assert us < 1_000_000
  end
end
