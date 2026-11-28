defmodule Glider.Procedure do
  @moduledoc false
  # Running one engine statement for a typed wrapper (`Glider.Changes`,
  # `Glider.Check`, `Glider.health/2`): arguments allow-listed and sent as
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
