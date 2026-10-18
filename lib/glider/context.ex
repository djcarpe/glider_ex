defmodule Glider.Context do
  @moduledoc """
  The engine's `context` extension: graph retrieval for language models.

  A model asked about a knowledge graph needs a small, relevant, faithful
  slice of it in as few tokens as possible. `context` does that in the
  engine: it finds entry points by full-text search, ranks their
  neighbourhood by personalised PageRank, and grows a connected subgraph
  until a token budget is spent, written in a compact text form a model
  reads as easily as JSON at a fraction of the tokens.

      {:ok, db} = Glider.open("kg.gldb")
      :ok = Glider.Context.install(db)
      {:ok, _} = Glider.Context.index(db)

      {:ok, ctx} = Glider.Context.retrieve(db, query: "Ada Lovelace", budget: 1500)
      ctx.text
      #=> "# context: 4 nodes, 4 edges; seeds n1\\nn1:Person name=\\"Ada Lovelace\\" ..."

      # follow-ups: say what the model has already seen
      {:ok, more} = Glider.Context.retrieve(db, seeds: ["n2"], seen: ctx.refs, budget: 800)

  `nN` in the text is the node id; every function accepts it back. Options
  are the procedure's arguments (`CALL context.help()` in the engine, or
  glider's `docs/EXTENSIONS.md`), passed as parameters, never spliced.
  """

  @type db :: Glider.db()

  @typedoc "A `retrieve` or `paths` result in text form."
  @type text_result :: %{
          text: String.t(),
          tokens: non_neg_integer(),
          nodes: non_neg_integer() | nil,
          edges: non_neg_integer() | nil,
          refs: [String.t()],
          message: String.t() | nil
        }

  @retrieve ~w(query seeds budget depth types type dir labels props exclude seen format alpha normalize
               max_chars max_fanout epsilon top label keys)a
  @search ~w(label keys top scan)a
  @paths ~w(k depth types type dir labels props exclude budget max_chars)a
  @index ~w(labels label keys)a

  @doc "Install the extension in this database (a no-op if it already is)."
  @spec install(db()) :: :ok | {:error, String.t()}
  def install(db), do: Glider.create_extension(db, "context")

  @doc """
  Build the full-text index `search` and `retrieve(query: ...)` use, over
  `labels:` and `keys:` (every label and text property by default). Writes
  keep it current from then on. Returns the engine's summary.
  """
  @spec index(db(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def index(db, opts \\ []) do
    with {:ok, r} <- call(db, "index", opts, @index), do: {:ok, r.message}
  end

  @doc "Drop the full-text index."
  @spec unindex(db()) :: :ok | {:error, String.t()}
  def unindex(db) do
    with {:ok, _} <- call(db, "unindex", [], []), do: :ok
  end

  @doc """
  Nodes whose text best matches `query`, best first:
  `[%{id: 12, ref: "n12", name: "Ada Lovelace", score: 13.2}]`.
  """
  @spec search(db(), String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def search(db, query, opts \\ []) when is_binary(query) do
    with {:ok, r} <- call(db, "search", [{:query, query} | opts], [:query | @search]) do
      {:ok,
       Enum.map(r.rows, fn [id, ref, name, score] ->
         %{id: id, ref: ref, name: name, score: score}
       end)}
    end
  end

  @doc """
  A connected, relevance-ranked subgraph around `seeds:` (ids or `"nN"`)
  and/or the best matches for `query:`, fitting `budget:` tokens.

  The default text form returns `t:text_result/0`. `format: "json"` returns
  the decoded `%{"nodes" => ..., "edges" => ...}`; `format: "rows"` one map
  per node with its score and hops.
  """
  @spec retrieve(db(), keyword()) :: {:ok, text_result() | map() | [map()]} | {:error, String.t()}
  def retrieve(db, opts) do
    with {:ok, r} <- call(db, "retrieve", opts, @retrieve) do
      case to_string(Keyword.get(opts, :format, "text")) do
        "rows" ->
          {:ok,
           Enum.map(r.rows, fn [id, ref, score, hops, card] ->
             %{id: id, ref: ref, score: score, hops: hops, card: card}
           end)}

        "json" ->
          [[json, _tokens]] = r.rows
          {:ok, :json.decode(json)}

        _ ->
          [[text, nodes, edges, tokens]] = r.rows
          {:ok, text_result(text, tokens, nodes, edges, r.message)}
      end
    end
  end

  @doc "Up to `k:` (3) shortest paths between two nodes, with the nodes on them."
  @spec paths(db(), integer() | String.t(), integer() | String.t(), keyword()) ::
          {:ok, text_result()} | {:error, String.t()}
  def paths(db, from, to, opts \\ []) do
    with {:ok, r} <- call(db, "paths", [{:from, from}, {:to, to} | opts], [:from, :to | @paths]) do
      [[text, tokens]] = r.rows
      {:ok, text_result(text, tokens, nil, nil, r.message)}
    end
  end

  @doc "A compact schema card for a system prompt: labels, property types, patterns."
  @spec schema(db(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def schema(db, opts \\ []) do
    with {:ok, r} <- call(db, "schema", opts, [:sample]) do
      [[text, _tokens]] = r.rows
      {:ok, text}
    end
  end

  @doc "The engine's token estimate for a string."
  @spec tokens(db(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def tokens(db, text) when is_binary(text) do
    # A statement needs a row to evaluate a function on; any node will do,
    # and an empty graph has the estimate computed from the text alone.
    case Glider.query(db, "MATCH (n) RETURN context.tokens($t) LIMIT 1", t: text) do
      {:ok, %{rows: [[n]]}} -> {:ok, n}
      {:ok, %{rows: []}} -> {:ok, local_estimate(text)}
      {:error, _} = e -> e
    end
  end

  # The engine's rule (glider::ext::context::tokens), for an empty graph.
  defp local_estimate(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({0, 0}, fn c, {n, run} ->
      cond do
        c =~ ~r/^[[:alnum:]]$/u -> {n, run + 1}
        c =~ ~r/^\s$/u -> {n + div(run + 3, 4), 0}
        true -> {n + div(run + 3, 4) + 1, 0}
      end
    end)
    |> then(fn {n, run} -> n + div(run + 3, 4) end)
  end

  defp text_result(text, tokens, nodes, edges, message) do
    refs =
      Regex.scan(~r/^(n\d+)[:\s]/m, text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    %{text: text, tokens: tokens, nodes: nodes, edges: edges, refs: refs, message: message}
  end

  # `CALL context.<proc>(k: $k, ...)` with every value a parameter. Keys
  # are checked against the procedure's arguments, so they can't be syntax.
  defp call(db, proc, opts, allowed) do
    opts = Enum.reject(opts, fn {_, v} -> is_nil(v) end)

    case Enum.reject(Keyword.keys(opts), &(&1 in allowed)) do
      [] ->
        args = Enum.map_join(opts, ", ", fn {k, _} -> "#{k}: $#{k}" end)
        params = Map.new(opts, fn {k, v} -> {Atom.to_string(k), param(v)} end)
        Glider.query(db, "CALL context.#{proc}(#{args})", params)

      bad ->
        {:error, "context.#{proc} has no argument #{Enum.map_join(bad, ", ", &inspect/1)}"}
    end
  end

  defp param(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp param(v) when is_list(v), do: Enum.map(v, &param/1)
  defp param(v), do: v
end
