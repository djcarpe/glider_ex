defmodule Glider.Procedure do
  @moduledoc false
  # Running one engine statement for a typed wrapper (`Glider.Changes`,
  # `Glider.Check`, `Glider.Structure`, `Glider.health/2`): arguments allow-listed and sent as
  # `$` parameters, the statement budget and result caps passed through, and
  # a `[:glider, :query, ...]` span with the procedure named.

  import Bitwise

  alias Glider.Native

  @budget [:max_millis, :max_steps]

  @doc false
  # The options every wrapper takes besides the procedure's own arguments.
  def budget_opts, do: @budget

  @doc false
  # `CALL <procedure>(k: $k, ...)` for the `args` (nil values dropped), run
  # with `opts` (`:max_millis`, `:max_steps`, and the result caps
  # `:max_rows`, `:max_bytes` a wrapper sets for its procedure; `probe: true`
  # for a statement that writes nothing, whose failure leaves the caller's
  # transaction alone and which leaves a recorded read error in place).
  def call(db, procedure, args, opts) do
    args = Enum.reject(args, fn {_, v} -> is_nil(v) end)
    list = Enum.map_join(args, ", ", fn {k, _} -> "#{k}: $#{k}" end)
    params = Enum.map(args, fn {k, v} -> {Atom.to_string(k), param(v)} end)
    statement(db, "CALL #{procedure}(#{list})", params, procedure, opts)
  end

  @doc false
  # A statement that is not a procedure call (`STATS`, `SHOW EXTENSIONS`).
  def statement(db, q, params, procedure, opts) do
    meta = %{db: db, query: q, procedure: procedure}

    :telemetry.span([:glider, :query], meta, fn ->
      result =
        Native.query_bounded(
          db,
          q,
          params,
          Keyword.get(opts, :max_rows, 10_000),
          Keyword.get(opts, :max_bytes, 8 <<< 20),
          false,
          {budget(opts, :max_millis), budget(opts, :max_steps)},
          Keyword.get(opts, :probe, false)
        )

      operation = q |> String.split(" ", parts: 2) |> hd()

      case result do
        {:ok, r} ->
          rows = length(r.rows)
          stop = Map.merge(meta, %{result: :ok, operation: operation})
          {{:ok, r}, %{rows: rows, touched: Map.get(r, :touched, 0)}, stop}

        {:error, reason} ->
          stop = Map.merge(meta, %{result: :error, operation: operation, error: reason})
          {{:error, reason}, %{}, stop}
      end
    end)
  end

  # ------------------------------------------------------------ answers in slices
  #
  # The one place that knows the end row (glider's docs/EXTENSIONS.md,
  # "Answers in slices"): a procedure that answers a piece at a time ends its
  # table with a `slice` column, null on every row but the last, whose value
  # is a JSON object `answered, complete, next, reason, oldest, watermark`.
  # Nothing here reads the message.

  @reasons %{
    "not_installed" => :not_installed,
    "installed" => :installed,
    "released" => :released,
    "cap" => :cap,
    "cleared" => :cleared,
    "reset" => :reset,
    "ahead" => :ahead,
    "restarting" => :restarting
  }

  @doc false
  # `call/4` for a procedure that ends with the end row: `{:ok, %{columns:,
  # rows:, end:, message:, touched:}}` with the `slice` column and the end
  # row taken off, `end` the end row read back as a map with atom keys
  # (`reason` an atom of the engine's fixed set). A result without a
  # well-formed end row is an error, never a complete answer.
  def sliced(db, procedure, args, opts) do
    with {:ok, r} <- call(db, procedure, args, opts), do: split_end(r, procedure)
  end

  @doc false
  def split_end(%{columns: columns, rows: rows} = r, procedure) do
    with {:ok, own} <- own_columns(columns, procedure),
         {:ok, body, last} <- last_row(rows, procedure),
         {:ok, end_} <- end_row(last, length(own), procedure) do
      {:ok,
       %{
         columns: own,
         rows: Enum.map(body, &Enum.take(&1, length(own))),
         end: end_,
         message: r.message,
         touched: Map.get(r, :touched, 0)
       }}
    end
  end

  defp own_columns(columns, procedure) do
    case Enum.split(columns, -1) do
      {own, ["slice"]} -> {:ok, own}
      _ -> {:error, "#{procedure} gave no slice column; this engine predates the end row"}
    end
  end

  defp last_row([], procedure), do: {:error, "#{procedure} gave no end row"}

  defp last_row(rows, _procedure) do
    {body, [last]} = Enum.split(rows, -1)
    {:ok, body, last}
  end

  defp end_row(last, own, procedure) do
    {cells, [json]} = Enum.split(last, -1)

    with true <- length(cells) == own and Enum.all?(cells, &is_nil/1) and is_binary(json),
         %{"answered" => answered, "complete" => complete, "next" => next} = j
         when is_boolean(answered) and is_boolean(complete) <- decode(json),
         {:ok, reason} <- reason(Map.get(j, "reason")) do
      {:ok,
       %{
         answered: answered,
         complete: complete,
         next: next,
         reason: reason,
         oldest: Map.get(j, "oldest"),
         watermark: Map.get(j, "watermark")
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "#{procedure} ended with a row that is not an end row: #{inspect(last)}"}
    end
  end

  # JSON null as nil (`:json` decodes it to `:null`).
  defp decode(json) do
    json
    |> :json.decode()
    |> Map.new(fn {k, v} -> {k, if(v == :null, do: nil, else: v)} end)
  rescue
    _ -> nil
  end

  defp reason(nil), do: {:ok, nil}

  defp reason(name) do
    case Map.fetch(@reasons, name) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "the engine gave a reason this binding does not know: #{inspect(name)}"}
    end
  end

  @doc false
  # A lazy stream over slices: `fetch.(cursor)` (nil first) returns
  # `{:ok, items, end}` or `{:error, reason}`; the stream follows the end
  # row's `next` exactly as given, stops on `complete`, and calls
  # `cannot.(end)` (which raises) when a slice says it cannot answer, on the
  # first slice or any later one. A slice that is neither complete nor gives
  # a next one is an error, never the end of the answer. `failed.(reason)`
  # raises for any other failure.
  def stream(fetch, cannot, failed) do
    Stream.resource(
      fn -> {:next, nil} end,
      fn
        :done ->
          {:halt, :done}

        {:next, cursor} ->
          case fetch.(cursor) do
            {:ok, _items, %{answered: false} = end_} ->
              cannot.(end_)

            {:ok, items, %{complete: true}} ->
              {items, :done}

            {:ok, items, %{next: next}} when not is_nil(next) ->
              {items, {:next, next}}

            {:ok, _items, end_} ->
              failed.("a slice was neither complete nor said where to go on: #{inspect(end_)}")

            {:error, reason} ->
              failed.(reason)
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc false
  # Run `fun` (several statements) so that no other process writes between
  # them: inside the caller's transaction as it is, otherwise in a
  # transaction of its own, which `fun`'s read-only statements leave empty.
  def together(db, fun) do
    if Glider.in_transaction?(db) do
      fun.()
    else
      case Glider.transaction(db, fun) do
        {:ok, result} -> result
        {:error, _} = error -> error
      end
    end
  end

  @doc false
  # Rows as maps keyed by the engine's column names (binaries from data).
  def maps(columns, rows), do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))

  @doc false
  # Split `opts` into the procedure's arguments (`allowed`) and the budget;
  # an option that is neither is an error naming it.
  def split(opts, allowed, what) when is_list(opts) do
    case Enum.reject(Keyword.keys(opts), &(&1 in allowed or &1 in @budget)) do
      [] ->
        {args, budget} = Keyword.split(opts, allowed)
        {:ok, args, budget}

      bad ->
        {:error, "#{what} has no option #{Enum.map_join(bad, ", ", &inspect/1)}"}
    end
  end

  # 0 is "no budget" to the NIF
  defp budget(opts, key) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n > 0 -> n
      nil -> 0
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc false
  # Run `fun` as a span for a wrapper that is not one statement (an install):
  # `[:glider, :query, ...]` with `:procedure` named.
  def span(db, procedure, fun) do
    meta = %{db: db, query: procedure, procedure: procedure}

    :telemetry.span([:glider, :query], meta, fn ->
      case fun.() do
        {:error, reason} = error ->
          {error, %{}, Map.merge(meta, %{result: :error, error: reason})}

        result ->
          {result, %{}, Map.put(meta, :result, :ok)}
      end
    end)
  end

  @doc false
  # A positive whole number, or nil: checked before anything is sent.
  def positive(nil, _what), do: :ok
  def positive(n, _what) when is_integer(n) and n >= 1, do: :ok

  def positive(other, what),
    do: {:error, "#{what} must be a whole number at least 1, got: #{inspect(other)}"}

  defp param(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: Atom.to_string(v)
  defp param(v) when is_list(v), do: Enum.map(v, &param/1)
  defp param(v), do: v
end
