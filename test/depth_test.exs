defmodule Glider.DepthTest do
  # Deeply nested input used to overflow the native stack of the dirty
  # scheduler running the NIF, and a stack overflow there is not an error:
  # it takes the whole VM down. These run in the test VM itself, so a
  # regression kills the test run, which is the point.
  use ExUnit.Case, async: true
  import Bitwise

  @deep 1_500
  @limit 64

  defp nested(open, inner, close, n),
    do: String.duplicate(open, n) <> inner <> String.duplicate(close, n)

  defp joined(unit, sep, n), do: Enum.map_join(1..n, sep, fn _ -> unit end)

  defp list(n), do: Enum.reduce(1..n, 1, fn _, acc -> [acc] end)

  # Every shape of glider's own corpus, at ten times the depth that crashed
  # the VM (parentheses 120, list literals 150, unary minus 400, EXPLAIN
  # 300, sums and subscripts 1,000, comma patterns 200).
  defp shapes do
    commas = Enum.map_join(1..2_000, ", ", &"(a#{&1})")

    [
      parentheses: "MATCH (n) WHERE #{nested("(", "n.x = 1", ")", 1_200)} RETURN n.x",
      list_literals: "MATCH (n) RETURN #{nested("[", "1", "]", @deep)}",
      unary_minus: "MATCH (n) RETURN #{String.duplicate("- ", 4_000)}1",
      not: "MATCH (n) WHERE #{String.duplicate("NOT ", 4_000)}true RETURN n.x",
      subscripts: "MATCH (n) RETURN [1]#{String.duplicate("[0]", 10_000)}",
      slices: "MATCH (n) RETURN [1]#{String.duplicate("[0..]", 10_000)}",
      explain: "#{String.duplicate("EXPLAIN ", 3_000)}MATCH (n) RETURN n",
      calls: "MATCH (n) RETURN #{nested("abs(", "1", ")", 1_200)}",
      and_chain: "MATCH (n) WHERE #{joined("n.x = 1", " AND ", 10_000)} RETURN n.x",
      sum: "MATCH (n) RETURN #{joined("1", " + ", 10_000)}",
      pattern_chain: "MATCH (a)#{String.duplicate("-[]-(a)", 10_000)} RETURN count(*)",
      comma_patterns: "MATCH #{commas} RETURN count(*)",
      set_items: "MATCH (n) SET #{joined("n.k = 1", ", ", 10_000)}",
      call_argument: "CALL pagerank(top: #{nested("[", "1", "]", @deep)})"
    ]
  end

  defp survived?({:ok, _}), do: true
  defp survived?({:error, reason}) when is_binary(reason), do: true
  defp survived?(other), do: flunk("unexpected #{inspect(other, limit: 5)}")

  setup do
    {:ok, db} = Glider.open()
    {:ok, 1} = Glider.run(db, "CREATE (:N {x: 1})")
    %{db: db}
  end

  defp answers(db) do
    assert {:ok, %{rows: [[1]]}} = Glider.query(db, "MATCH (n:N) RETURN n.x")
  end

  test "every shape, through every entry point that takes statement text", %{db: db} do
    for {name, q} <- shapes() do
      assert survived?(Glider.query(db, q)), "query/3 #{name}"
      assert survived?(Glider.query(db, q, [], max_rows: 10)), "query/4 #{name}"
      assert survived?(Glider.run(db, q)), "run/3 #{name}"

      try do
        Glider.all(db, q)
      rescue
        Glider.Error -> :refused
      end

      assert survived?(Glider.cursor(db, q)), "cursor/4 #{name}"
      assert survived?(wrap(Glider.write_batch(db, [{q, %{}}]))), "write_batch/2 #{name}"
      answers(db)
    end
  end

  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:error, _} = e), do: e

  test "nested list parameters are refused at the boundary, with glider's message", %{db: db} do
    message = "list nested deeper than #{@limit} levels"

    for depth <- [@limit + 1, @deep, 1 <<< 20] do
      p = list(depth)
      assert {:error, ^message} = Glider.query(db, "MATCH (n) RETURN $p", p: p)
      assert {:error, ^message} = Glider.query(db, "MATCH (n) RETURN $p", %{p: p}, max_rows: 5)
      assert {:error, ^message} = Glider.run(db, "MATCH (n) SET n.p = $p", p: p)
      assert_raise Glider.Error, fn -> Glider.all(db, "MATCH (n) RETURN $p", p: p) end
      assert {:error, ^message} = Glider.cursor(db, "MATCH (n) RETURN $p", %{p: p})
      assert {:error, ^message} = Glider.write_batch(db, [{"CREATE (:M {p: $p})", %{p: p}}])
    end

    # At the limit, a value goes in and comes back out whole.
    p = list(@limit)
    assert {:ok, 1} = Glider.run(db, "MATCH (n:N) SET n.p = $p", p: p)
    assert [[^p]] = Glider.all(db, "MATCH (n:N) RETURN n.p")
    {:ok, cursor} = Glider.cursor(db, "MATCH (n:N) RETURN n.p")
    assert {:ok, {%{rows: [[^p]]}, true}} = Glider.cursor_next(cursor)
    # A statement that builds a deeper one is refused rather than handed out.
    assert {:error, "list nested deeper" <> _} = Glider.query(db, "MATCH (n:N) RETURN [n.p]")
    answers(db)
  end

  test "Glider.Context passes its options as parameters, refused the same way", %{db: db} do
    :ok = Glider.Context.install(db)
    deep = list(@deep)
    assert {:error, "list nested deeper" <> _} = Glider.Context.retrieve(db, seeds: deep)
    assert {:error, "list nested deeper" <> _} = Glider.Context.paths(db, deep, deep)
    assert {:error, "list nested deeper" <> _} = Glider.Context.search(db, "x", keys: deep)
    assert {:error, "list nested deeper" <> _} = Glider.Context.index(db, labels: deep)
    assert {:ok, _} = Glider.Context.tokens(db, nested("[", "1", "]", @deep))
    answers(db)
  end

  test "deeply nested JSON lines are refused by import_jsonl/2 and import_file/3", %{db: db} do
    lines = [
      ~s({"type":"node","props":{"p":#{nested("[", "1", "]", @limit + 1)}}}),
      ~s({"type":"node","props":{"p":#{nested("[", "1", "]", @deep)}}}),
      ~s({"type":"node","props":{"p":#{nested("{\"a\":", "1", "}", @deep)}}}),
      ~s({"type":"node","props":{"p":#{nested("[", "1", "]", 500_000)}}})
    ]

    path =
      Path.join(System.tmp_dir!(), "glider-depth-#{System.unique_integer([:positive])}.jsonl")

    for line <- lines do
      assert {:error, _} = Glider.import_jsonl(db, line)
      File.write!(path, line)
      assert {:error, _} = Glider.import_file(db, path, max_record_bytes: 1 <<< 20)
      answers(db)
    end

    File.rm(path)
    assert {:ok, %{rows: [[1]]}} = Glider.query(db, "MATCH (n) RETURN count(n)")
  end

  describe "transactions belong to Glider.transaction/2" do
    @controls ["BEGIN", "begin", "  Commit;", "ROLLBACK", "// open one\nBEGIN", "`BEGIN`"]

    test "BEGIN, COMMIT and ROLLBACK as text are refused, naming it", %{db: db} do
      for q <- @controls do
        assert {:error, reason} = Glider.query(db, q), inspect(q)
        assert reason =~ "Glider.transaction/2"
        assert {:error, ^reason} = Glider.run(db, q)
        assert {:error, ^reason} = Glider.query(db, q, [], max_rows: 5)
        assert {:error, ^reason} = Glider.cursor(db, q)
        assert {:error, ^reason} = Glider.write_batch(db, [{q, %{}}])
        assert_raise Glider.Error, fn -> Glider.all(db, q) end
      end
    end

    test "so a raw BEGIN cannot leave the handle in a transaction nobody owns", %{db: db} do
      _ = Glider.query(db, "BEGIN")
      refute Glider.in_transaction?(db)

      # Another process's write commits on its own, and survives this
      # process's ROLLBACK as text.
      {:ok, 1} = Task.async(fn -> Glider.run(db, "CREATE (:Other)") end) |> Task.await()
      _ = Glider.query(db, "ROLLBACK")
      assert {:ok, %{rows: [[1]]}} = Glider.query(db, "MATCH (n:Other) RETURN count(n)")
    end

    test "transaction/2 and rollback/2 keep working", %{db: db} do
      assert {:ok, :done} =
               Glider.transaction(db, fn ->
                 Glider.run!(db, "CREATE (:T)")
                 :done
               end)

      assert {:error, :nope} =
               Glider.transaction(db, fn ->
                 Glider.run!(db, "CREATE (:T)")
                 Glider.rollback(db, :nope)
               end)

      assert {:ok, %{rows: [[1]]}} = Glider.query(db, "MATCH (n:T) RETURN count(n)")
    end
  end
end
