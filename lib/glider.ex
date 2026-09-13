defmodule Glider do
  @moduledoc ~S"""
  Elixir bindings for glider, an embeddable property-graph database with
  built-in graph algorithms.

  The engine is linked into the BEAM as a NIF. There is no server, no port
  process and no socket — a query is a function call.

      {:ok, db} = Glider.open()

      {:ok, _} =
        Glider.run(db, "CREATE (a:Person {name:\"Ada\"})-[:KNOWS]->(b:Person {name:\"Bob\"})")

      {:ok, r} = Glider.query(db, "MATCH (a)-[r:KNOWS]->(b) RETURN a, r, b")

      [%Glider.Node{props: %{"name" => "Ada"}}, %Glider.Rel{type: "KNOWS"}, _] = hd(r.rows)

  ### Writing queries in Elixir source

  Prefer a plain string, or a heredoc sigil. Do not reach for the bracket
  sigils: Elixir nests paired delimiters, so `~S[...]` and `~S(...)` both fail
  to parse on ordinary Cypher such as `-[:KNOWS]->(b)`. Use the uppercase `~S`
  form rather than `~s` so that a literal `#{...}` inside a query is not read
  as interpolation.

  ## Concurrency

  A handle is safe to share between processes, but calls against one handle are
  **serialised** by a mutex inside the NIF: glider holds the graph in memory and
  mutates it in place, so concurrent access would be a data race rather than a
  slowdown. Reads do not run in parallel.

  If you want a single writer with supervised lifecycle, put the handle in a
  `GenServer` and call through it. If you want read parallelism, open several
  handles onto separate graphs — one per shard — rather than sharing one.

  All potentially slow work (queries, algorithms, opening a file, import,
  export, compaction) runs on a dirty scheduler, so a long-running PageRank
  will not stall the VM.

  ## Persistence

  `open/0` gives a throwaway in-memory graph. `open/2` opens or creates a file,
  which is a write-ahead log and the persistent form at once:

      {:ok, db} = Glider.open("social.gldb")
      {:ok, db} = Glider.open("social.gldb", :always)   # fsync every commit

  Durability modes are `:always` (survives power loss), `:normal` (the default;
  survives process death) and `:off` (buffered, for bulk load).

  ## Query language

  A Cypher-flavoured subset. Two divergences catch people out:

    * `RETURN` requires a `MATCH` — there is no bare `RETURN 1`.
    * `count()` over zero matches yields **zero rows**, not one row holding `0`.
      Use `stats/1` when you want a count that is always present.
  """

  alias Glider.{Native, Node, Rel, Result}

  @typedoc "A property value. glider's values are flat — no nested maps."
  @type prop :: nil | boolean() | integer() | float() | String.t() | [prop()]

  @typedoc "One cell of a result row."
  @type cell :: prop() | Node.t() | Rel.t()

  @typedoc "An open graph. Opaque."
  @opaque db :: reference()

  @type sync :: :always | :normal | :off

  @doc "Open a throwaway in-memory graph."
  @spec open() :: {:ok, db()} | {:error, String.t()}
  def open, do: {:ok, Native.open_memory()}

  @doc """
  Open or create a graph file.

  Returns `{:error, reason}` if the file is locked by another writer, or is not
  a glider database.
  """
  @spec open(Path.t(), sync()) :: {:ok, db()} | {:error, String.t()}
  def open(path, sync \\ :normal) when is_binary(path) and sync in [:always, :normal, :off] do
    Native.open_file(path, sync)
  end

  @doc """
  Run a query.

  Nodes and relationships come back as `%Glider.Node{}` and `%Glider.Rel{}`;
  everything else as the corresponding Elixir term.
  """
  @spec query(db(), String.t()) :: {:ok, Result.t()} | {:error, String.t()}
  def query(db, q) when is_binary(q) do
    case Native.query(db, q) do
      {:ok, map} -> {:ok, to_result(map)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run a query, raising `Glider.Error` on failure.
  """
  @spec query!(db(), String.t()) :: Result.t()
  def query!(db, q) do
    case query(db, q) do
      {:ok, r} -> r
      {:error, reason} -> raise Glider.Error, message: reason, query: q
    end
  end

  @doc """
  Run a statement for its effect, returning how many entities it touched.

      {:ok, 3} = Glider.run(db, "CREATE (:A)-[:R]->(:B)")
  """
  @spec run(db(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def run(db, q) do
    with {:ok, r} <- query(db, q), do: {:ok, r.touched}
  end

  @doc "Just the drawable `%{nodes: [...], edges: [...]}` projection of a query."
  @spec graph(db(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def graph(db, q) do
    with {:ok, r} <- query(db, q), do: {:ok, r.graph}
  end

  @doc """
  Labels, relationship types and indexes, with counts.

      {:ok, %{labels: [%{name: "Person", count: 2}], edge_types: [...], indexes: []}}
  """
  @spec schema(db()) :: {:ok, map()} | {:error, String.t()}
  def schema(db) do
    case Native.schema(db) do
      {:ok, json} -> {:ok, decode_schema(json)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Neighbours of one node, in both directions, capped by `limit`."
  @spec expand(db(), non_neg_integer(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def expand(db, id, limit \\ 50) when is_integer(id) and id >= 0 do
    Native.expand(db, id, limit)
  end

  @doc """
  Bulk load JSON Lines. Returns `{:ok, {nodes, edges}}`.

  One JSON object per line:

      {"type":"node","id":1,"labels":["Person"],"props":{"name":"Ada"}}
      {"type":"edge","from":1,"to":2,"label":"KNOWS","props":{}}
  """
  @spec import_jsonl(db(), String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, String.t()}
  def import_jsonl(db, jsonl) when is_binary(jsonl), do: Native.import_jsonl(db, jsonl)

  @doc "Dump the whole graph as JSON Lines, re-importable by `import_jsonl/2`."
  @spec export_jsonl(db()) :: {:ok, String.t()} | {:error, String.t()}
  def export_jsonl(db), do: Native.export_jsonl(db)

  @doc "Node, edge, label and index counts, as a map."
  @spec stats(db()) :: {:ok, map()} | {:error, String.t()}
  def stats(db) do
    with {:ok, r} <- query(db, "STATS") do
      {:ok, Map.new(r.rows, fn [k, v] -> {k, v} end)}
    end
  end

  @doc "Flush buffered writes to disk. A no-op for in-memory graphs."
  @spec checkpoint(db()) :: :ok | {:error, String.t()}
  def checkpoint(db), do: unwrap_ok(Native.checkpoint(db))

  @doc """
  Rewrite the file as the minimal set of records reproducing current state,
  reclaiming space from deletes and overwrites.
  """
  @spec compact(db()) :: :ok | {:error, String.t()}
  def compact(db), do: unwrap_ok(Native.compact(db))

  @doc """
  Release the graph and its file lock now, rather than at garbage collection.

  Safe to call more than once. Any later call on the handle returns
  `{:error, "this graph is closed"}`.
  """
  @spec close(db()) :: :ok
  def close(db), do: Native.close(db)

  @doc "The version of the underlying glider engine."
  @spec version() :: String.t()
  def version, do: Native.version()

  # ------------------------------------------------------------------ private

  # The NIF returns Result<_, String>, which rustler encodes as {:ok, _} /
  # {:error, reason}. For calls whose success payload is just :ok, collapse the
  # {:ok, :ok} that falls out of that.
  defp unwrap_ok({:ok, :ok}), do: :ok
  defp unwrap_ok({:error, reason}), do: {:error, reason}

  defp to_result(%{columns: columns, rows: rows, graph: graph} = map) do
    %Result{
      columns: columns,
      rows: rows,
      graph: %{nodes: graph.nodes, edges: graph.edges},
      message: Map.get(map, :message),
      touched: Map.get(map, :touched, 0)
    }
  end

  # The schema call is the one place the NIF hands back JSON rather than terms:
  # it is small, and reusing glider's own SCHEMA statement avoids a second
  # definition of what a schema is. OTP 27+ ships :json, so this costs no
  # dependency.
  defp decode_schema(json) do
    decoded = :json.decode(json)

    %{
      labels: entries(decoded, "labels"),
      edge_types: entries(decoded, "edge_types"),
      indexes: entries(decoded, "indexes")
    }
  end

  defp entries(decoded, key) do
    decoded
    |> Map.get(key, [])
    |> Enum.map(fn e -> %{name: Map.get(e, "name"), count: Map.get(e, "count", 0)} end)
  end
end

defmodule Glider.Error do
  @moduledoc "Raised by the bang variants when the engine reports an error."
  defexception [:message, :query]
end
