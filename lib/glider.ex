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

  ## Parameters

  Pass values as `$name` parameters rather than splicing them into the string.
  They are substituted as literals, so a value can never change the query's
  shape:

      Glider.query(db, "MATCH (p:Person {email: $email}) RETURN p", email: email)

  ## Composable queries

  `Glider.Query` builds queries Ecto-style, with `^` pinning Elixir values as
  parameters:

      import Glider.Query

      match("(p:Person)-[:KNOWS]->(f:Person)")
      |> where(p.email == ^email and f.age >= ^min_age)
      |> return(name: f.name, age: f.age)
      |> order_by(desc: f.age)
      |> limit(10)
      |> Glider.all(db)
      #=> [%{name: "Bob", age: 41}, ...]

  ## Transactions

  Outside a transaction every statement commits on its own. `transaction/2`
  groups them, and belongs to the calling process: other processes using the
  same handle wait until it finishes.

      Glider.transaction(db, fn ->
        Glider.run!(db, "CREATE (:Account {id: $id})", id: 1)
        Glider.run!(db, "CREATE (:Account {id: $id})", id: 2)
      end)

  ## Concurrency

  A handle is safe to share between processes, but calls against one handle are
  **serialised** by a mutex inside the NIF. If you want a single writer with a
  supervised lifecycle, put the handle in a `GenServer` and call through it.

  All potentially slow work (queries, algorithms, opening a file, import,
  export, checkpoints) runs on a dirty scheduler, so a long-running PageRank
  will not stall the VM.

  ## Persistence

  `open/0` gives a throwaway in-memory graph. `open/2` opens or creates a paged
  database file, which may grow far beyond RAM; memory stays near the page
  cache size:

      {:ok, db} = Glider.open("social.gldb")
      {:ok, db} = Glider.open("social.gldb", sync: :always, cache_size: "256M")

  Durability modes are `:always` (survives power loss), `:normal` (the default;
  survives process death) and `:off` (buffered, for bulk load).

  ## Telemetry

  Queries, transactions, checkpoints, imports and exports emit `:telemetry`
  span events (`[:glider, :query, :start | :stop | :exception]` and so on),
  carrying the engine's own report — rows, pages read, cache hits — as
  measurements. `Glider.OpenTelemetry.setup/1` turns them into OpenTelemetry
  spans; `Glider.Telemetry` has the event catalogue, engine counters,
  Prometheus and OTLP renderers, and per-database metrics.

  ## Query language

  A Cypher-flavoured subset. Two divergences catch people out:

    * `RETURN` requires a `MATCH` — there is no bare `RETURN 1`.
    * `count()` over zero matches yields **zero rows**, not one row holding `0`.
      Use `stats/1` when you want a count that is always present.
  """

  import Bitwise

  alias Glider.{Native, Node, Query, Rel, Result}

  @typedoc "A property value. glider's values are flat — no nested maps."
  @type prop :: nil | boolean() | integer() | float() | String.t() | [prop()]

  @typedoc "One cell of a result row."
  @type cell :: prop() | Node.t() | Rel.t()

  @typedoc "An open graph. Opaque."
  @opaque db :: reference()

  @type sync :: :always | :normal | :off

  @typedoc "`$name` parameters, as a keyword list or a map with atom or string keys."
  @type params :: keyword() | %{optional(atom() | String.t()) => prop()}

  @typedoc "A query string or a `Glider.Query` built with the query DSL."
  @type queryable :: String.t() | Query.t()

  @typedoc """
  A size in bytes: an integer, or a string with a K, M, G or T suffix
  (binary multiples, as the glider CLI takes them).
  """
  @type size :: non_neg_integer() | String.t()

  @doc """
  Open a throwaway in-memory graph.

  Options:

    * `:max_memory` - the most memory the graph may use (a `t:size/0`).
      Past it, writes fail cleanly and roll back. Defaults to physical RAM.
  """
  @spec open(keyword()) :: {:ok, db()} | {:error, String.t()}
  def open(opts \\ [])

  def open(opts) when is_list(opts) do
    {:ok, Native.open_memory(bytes(Keyword.get(opts, :max_memory, 0)))}
  end

  def open(path) when is_binary(path), do: open(path, [])

  @doc """
  Open or create a database file.

  Options:

    * `:sync` - `:always`, `:normal` (default) or `:off`.
    * `:cache_size` - page cache (a `t:size/0`, default 1G). RAM use stays
      near this however large the database grows.
    * `:work_mem` - memory algorithms may use before spilling to disk
      (default 256M).
    * `:checkpoint` - fold the write-ahead log into the pages after this much
      log (default 256M), or `:off`.

  A bare sync atom is accepted in place of the options: `open(path, :always)`.

  Returns `{:error, reason}` if the file is locked by another writer, or is not
  a glider database.
  """
  @spec open(Path.t(), keyword() | sync()) :: {:ok, db()} | {:error, String.t()}
  def open(path, sync) when is_binary(path) and sync in [:always, :normal, :off],
    do: open(path, sync: sync)

  def open(path, opts) when is_binary(path) and is_list(opts) do
    sync = Keyword.get(opts, :sync, :normal)

    unless sync in [:always, :normal, :off] do
      raise ArgumentError, "unknown :sync mode #{inspect(sync)}"
    end

    checkpoint =
      case Keyword.get(opts, :checkpoint, 0) do
        :off -> 0xFFFF_FFFF_FFFF_FFFF
        size -> bytes(size)
      end

    Native.open_file(
      path,
      sync,
      bytes(Keyword.get(opts, :cache_size, 0)),
      bytes(Keyword.get(opts, :work_mem, 0)),
      checkpoint
    )
  end

  @doc """
  Whether `path` holds a database in glider's legacy log format, which the
  paged engine refuses to open until it is migrated. Returns the format's
  name, or `nil` for a paged database, a missing file, or a file that is not
  glider's.
  """
  @spec legacy(Path.t()) :: String.t() | nil
  def legacy(path) when is_binary(path), do: Native.legacy_kind(path)

  @doc """
  Convert a legacy log-format database into a paged one, in place.

  The new database is built beside the old and swapped in; the original is
  kept as `<path>.legacy.bak`. Returns how many nodes and edges were copied.
  Nothing may have the file open while this runs.
  """
  @spec migrate(Path.t()) ::
          {:ok, %{nodes: non_neg_integer(), edges: non_neg_integer()}} | {:error, String.t()}
  def migrate(path) when is_binary(path) do
    case Native.migrate(path) do
      {:ok, {nodes, edges}} -> {:ok, %{nodes: nodes, edges: edges}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Run a query.

  `query` is a string or a `Glider.Query`. `params` fill `$name` placeholders;
  a `Glider.Query` carries its own pinned values and may take more here.

  Nodes and relationships come back as `%Glider.Node{}` and `%Glider.Rel{}`;
  everything else as the corresponding Elixir term.
  """
  @spec query(db(), queryable(), params()) :: {:ok, Result.t()} | {:error, String.t()}
  def query(db, query, params \\ [])

  # Query first, so a pipeline can end in `|> Glider.query(db)`.
  def query(%Query{} = q, db, params) when is_reference(db), do: query(db, q, params)

  def query(db, %Query{} = q, params) do
    {cypher, own} = Query.to_cypher(q)
    query(db, cypher, Map.merge(own, stringify(params)))
  end

  def query(db, q, params) when is_binary(q) do
    params = Map.to_list(stringify(params))
    meta = %{db: db, query: q}

    :telemetry.span([:glider, :query], meta, fn ->
      case Native.query(db, q, params) do
        {:ok, {map, op}} ->
          {{:ok, to_result(map)}, Glider.Telemetry.measurements(op),
           Glider.Telemetry.stop_metadata(meta, op, :ok)}

        {:error, {reason, op}} ->
          {{:error, reason}, Glider.Telemetry.measurements(op),
           meta |> Glider.Telemetry.stop_metadata(op, :error) |> Map.put(:error, reason)}
      end
    end)
  end

  @doc """
  Run a query, raising `Glider.Error` on failure.
  """
  @spec query!(db(), queryable(), params()) :: Result.t()
  def query!(db, q, params \\ [])
  def query!(%Query{} = q, db, params) when is_reference(db), do: query!(db, q, params)

  def query!(db, q, params) do
    case query(db, q, params) do
      {:ok, r} -> r
      {:error, reason} -> raise Glider.Error, message: reason, query: describe(q)
    end
  end

  @doc """
  Run a statement for its effect, returning how many entities it touched.

      {:ok, 3} = Glider.run(db, "CREATE (:A)-[:R]->(:B)")
  """
  @spec run(db(), queryable(), params()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def run(db, q, params \\ [])
  def run(%Query{} = q, db, params) when is_reference(db), do: run(db, q, params)

  def run(db, q, params) do
    with {:ok, r} <- query(db, q, params), do: {:ok, r.touched}
  end

  @doc "Like `run/3`, raising `Glider.Error` on failure."
  @spec run!(db(), queryable(), params()) :: non_neg_integer()
  def run!(db, q, params \\ [])
  def run!(%Query{} = q, db, params) when is_reference(db), do: run!(db, q, params)
  def run!(db, q, params), do: query!(db, q, params).touched

  @doc """
  The rows of a query, shaped by its `RETURN`.

  For a `Glider.Query`, rows take the shape its `return/2` asked for: a single
  expression gives a list of values, a keyword list gives maps, a list gives
  lists. A query string gives lists, one per row.

      Glider.all(db, "MATCH (p:Person) RETURN p.name")
      #=> [["Ada"], ["Bob"]]
  """
  @spec all(db(), queryable(), params()) :: [term()]
  def all(db, q, params \\ [])
  def all(%Query{} = q, db, params) when is_reference(db), do: all(db, q, params)

  def all(db, q, params) do
    r = query!(db, q, params)
    Enum.map(r.rows, &shape_row(q, &1))
  end

  @doc """
  The single row of a query, `nil` when there is none. Raises if there are
  several.
  """
  @spec one(db(), queryable(), params()) :: term() | nil
  def one(db, q, params \\ [])
  def one(%Query{} = q, db, params) when is_reference(db), do: one(db, q, params)

  def one(db, q, params) do
    case all(db, q, params) do
      [] ->
        nil

      [row] ->
        row

      rows ->
        raise Glider.Error,
          message: "expected at most one row, got #{length(rows)}",
          query: describe(q)
    end
  end

  @doc "Just the drawable `%{nodes: [...], edges: [...]}` projection of a query."
  @spec graph(db(), queryable(), params()) :: {:ok, map()} | {:error, String.t()}
  def graph(db, q, params \\ [])
  def graph(%Query{} = q, db, params) when is_reference(db), do: graph(db, q, params)

  def graph(db, q, params) do
    with {:ok, r} <- query(db, q, params), do: {:ok, r.graph}
  end

  @doc """
  Run `fun` inside a transaction owned by the calling process.

  Commits and returns `{:ok, result}` if `fun` returns normally. Rolls back if
  it raises, throws or exits (and re-raises), or if it calls `rollback/2`
  (returning `{:error, value}`). A statement that fails inside the transaction
  aborts it: the rest of `fun` still runs, but nothing is committed.

  Calling `transaction/2` while the process already holds a transaction on
  `db` runs `fun` inside it.
  """
  @spec transaction(db(), (-> result)) :: {:ok, result} | {:error, term()} when result: term()
  def transaction(db, fun) when is_function(fun, 0) do
    if Native.in_transaction(db) do
      {:ok, fun.()}
    else
      # A span around the whole transaction: with Glider.OpenTelemetry its
      # statements become children of it.
      instrument(:transaction, %{db: db}, fn ->
        with {:ok, :ok} <- Native.begin(db), do: run_transaction(db, fun)
      end)
    end
  end

  defp run_transaction(db, fun) do
    result =
      try do
        fun.()
      catch
        :throw, {:glider_rollback, ^db, value} ->
          _ = Native.rollback(db)
          throw({:glider_rolled_back, value})

        kind, reason ->
          _ = Native.rollback(db)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case Native.commit(db) do
      {:ok, :ok} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  catch
    :throw, {:glider_rolled_back, value} -> {:error, value}
  end

  @doc """
  Abandon the enclosing `transaction/2`, which then returns `{:error, value}`.
  """
  @spec rollback(db(), term()) :: no_return()
  def rollback(db, value \\ :rollback) do
    unless Native.in_transaction(db) do
      raise Glider.Error, message: "rollback/2 called outside a transaction"
    end

    throw({:glider_rollback, db, value})
  end

  @doc "Whether the calling process holds an open transaction on `db`."
  @spec in_transaction?(db()) :: boolean()
  def in_transaction?(db), do: Native.in_transaction(db)

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
  def import_jsonl(db, jsonl) when is_binary(jsonl) do
    instrument(:import, %{db: db, bytes: byte_size(jsonl)}, fn ->
      Native.import_jsonl(db, jsonl)
    end)
  end

  @doc "Dump the whole graph as JSON Lines, re-importable by `import_jsonl/2`."
  @spec export_jsonl(db()) :: {:ok, String.t()} | {:error, String.t()}
  def export_jsonl(db), do: instrument(:export, %{db: db}, fn -> Native.export_jsonl(db) end)

  @doc "Node, edge, label and index counts, as a map."
  @spec stats(db()) :: {:ok, map()} | {:error, String.t()}
  def stats(db) do
    with {:ok, r} <- query(db, "STATS") do
      {:ok, Map.new(r.rows, fn [k, v] -> {k, v} end)}
    end
  end

  @doc """
  Fold the write-ahead log into the database pages and reclaim its space.
  A no-op for in-memory graphs. Not allowed inside a transaction.
  """
  @spec checkpoint(db()) :: :ok | {:error, String.t()}
  def checkpoint(db) do
    instrument(:checkpoint, %{db: db}, fn -> unwrap_ok(Native.checkpoint(db)) end)
  end

  @doc """
  Act on a pending replicator request now. A handle that sits idle between
  writes should call this periodically when the file is replicated; see
  glider's `docs/REPLICATION.md`.
  """
  @spec poll_replication(db()) :: :ok | {:error, String.t()}
  def poll_replication(db), do: unwrap_ok(Native.poll_replication(db))

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

  # A `[:glider, event, ...]` telemetry span whose stop metadata says how it
  # ended: `result: :ok | :error`, and `error:` with the reason.
  defp instrument(event, meta, fun) do
    :telemetry.span([:glider, event], meta, fn ->
      result = fun.()

      case result do
        {:error, reason} -> {result, Map.merge(meta, %{result: :error, error: reason})}
        _ -> {result, Map.put(meta, :result, :ok)}
      end
    end)
  end

  # The NIF returns Result<_, String>, which rustler encodes as {:ok, _} /
  # {:error, reason}. For calls whose success payload is just :ok, collapse the
  # {:ok, :ok} that falls out of that.
  defp unwrap_ok({:ok, :ok}), do: :ok
  defp unwrap_ok({:error, reason}), do: {:error, reason}

  defp stringify(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) ->
        {Atom.to_string(k), v}

      {k, v} when is_binary(k) ->
        {k, v}

      {k, _} ->
        raise ArgumentError, "parameter names must be atoms or strings, got: #{inspect(k)}"
    end)
  end

  defp shape_row(%Query{} = q, row), do: Query.shape(q, row)
  defp shape_row(_q, row), do: row

  defp describe(%Query{} = q), do: q |> Query.to_cypher() |> elem(0)
  defp describe(q), do: q

  @units %{"" => 1, "K" => 1 <<< 10, "M" => 1 <<< 20, "G" => 1 <<< 30, "T" => 1 <<< 40}

  defp bytes(n) when is_integer(n) and n >= 0, do: n

  defp bytes(s) when is_binary(s) do
    with [_, num, unit] <- Regex.run(~r/^\s*(\d+(?:\.\d+)?)\s*([KMGT]?)(?:i?B)?\s*$/i, s),
         {n, ""} <- Float.parse(num) do
      trunc(n * Map.fetch!(@units, String.upcase(unit)))
    else
      _ -> raise ArgumentError, "not a size: #{inspect(s)} (use bytes, or e.g. \"256M\")"
    end
  end

  defp bytes(other), do: raise(ArgumentError, "not a size: #{inspect(other)}")

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
