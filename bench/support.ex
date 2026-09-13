defmodule Glider.Bench do
  @moduledoc """
  Shared fixtures for the benchmark scripts.

  The graph shape here matters. A uniform-random graph is the wrong thing to
  measure: real graphs have a heavy-tailed degree distribution, so a few nodes
  carry a disproportionate share of the edges, and that is exactly what makes
  multi-hop traversal expensive. Edges are drawn with a copy model
  (preferential attachment), which reproduces that tail.
  """

  @doc """
  Build an in-memory social graph of `n` people via bulk JSONL import.

  Returns `{db, ids}` where `ids` are glider's internal node ids, sampled so a
  benchmark can probe typical nodes rather than always hitting node 0.
  """
  def social(n, opts \\ []) do
    avg_degree = Keyword.get(opts, :avg_degree, 12)
    {:ok, db} = Glider.open()
    {:ok, _} = Glider.import_jsonl(db, jsonl(n, avg_degree))
    {:ok, _} = Glider.query(db, "INDEX ON :Person(email)")
    {db, n}
  end

  @doc "Deterministic JSONL for `n` people with a heavy-tailed KNOWS graph."
  def jsonl(n, avg_degree \\ 12) do
    nodes =
      Enum.map(0..(n - 1), fn i ->
        ~s({"type":"node","id":#{i},"labels":["Person"],"props":{) <>
          ~s("name":"Person #{i}","email":"p#{i}@example.com",) <>
          ~s("age":#{18 + rem(i * 7, 62)},"city":"#{city(i)}"}})
      end)

    {edges, _} =
      Enum.flat_map_reduce(0..(n - 1), {[], seed()}, fn i, {targets, state} ->
        {lines, targets, state} = edges_for(i, n, avg_degree, targets, state)
        {lines, {targets, state}}
      end)

    Enum.join(nodes ++ edges, "\n")
  end

  @cities ~w(London Paris Berlin Madrid Rome Lisbon Dublin Vienna Tokyo Seoul)
  defp city(i), do: Enum.at(@cities, rem(i, length(@cities)))

  defp seed, do: 0x2545F4914F6CDD1D

  # xorshift64*, so the graph is identical on every run and across machines.
  defp next(state) do
    x = state
    x = Bitwise.bxor(x, Bitwise.bsl(x, 13)) |> mask()
    x = Bitwise.bxor(x, Bitwise.bsr(x, 7))
    x = Bitwise.bxor(x, Bitwise.bsl(x, 17)) |> mask()
    x
  end

  defp mask(x), do: Bitwise.band(x, 0xFFFFFFFFFFFFFFFF)

  defp edges_for(i, n, avg_degree, targets, state) do
    state = next(state)
    degree = 1 + rem(state, avg_degree * 2)

    Enum.reduce(1..degree, {[], targets, state}, fn _, {lines, targets, state} ->
      state = next(state)

      # 25% uniform, 75% preferential attachment — the mix that produces a
      # power-law tail while keeping the graph connected enough to traverse.
      to =
        if targets == [] or rem(state, 100) < 25 do
          rem(state, n)
        else
          Enum.at(targets, rem(state, length(targets)))
        end

      if to == i do
        {lines, targets, state}
      else
        line =
          ~s({"type":"edge","from":#{i},"to":#{to},"label":"KNOWS","props":{"since":#{2010 + rem(state, 16)}}})

        # Cap the sample so this stays O(1) memory rather than O(edges).
        targets = if length(targets) > 512, do: [to | Enum.take(targets, 256)], else: [to | targets]
        {[line | lines], targets, state}
      end
    end)
  end

  @doc """
  JSONL for `n` nodes and no edges.

  Exists so the bulk-load comparison is like for like: the CREATE loop it is
  measured against makes nodes only, and including edges here would have
  compared different amounts of work.
  """
  def nodes_jsonl(n) do
    Enum.map_join(0..(n - 1), "\n", fn i ->
      ~s({"type":"node","id":#{i},"labels":["P"],"props":{"i":#{i}}})
    end)
  end

  @doc "A person's email, for indexed point lookups."
  def email(i), do: "p#{i}@example.com"

  @doc "Print a one-line summary of a graph's size."
  def describe(db, label) do
    {:ok, stats} = Glider.stats(db)
    IO.puts("#{label}: #{stats["nodes"]} nodes, #{stats["edges"]} edges")
  end
end
