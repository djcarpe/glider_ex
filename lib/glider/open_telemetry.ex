defmodule Glider.OpenTelemetry do
  @moduledoc """
  OpenTelemetry spans for glider, from its `:telemetry` events.

      # in Application.start/2, after the OpenTelemetry SDK is configured
      :ok = Glider.OpenTelemetry.setup()

  Each query becomes a client span named `glider <operation>` (`glider MATCH`,
  `glider CALL`, ...), a child of whatever span is current in the calling
  process — a Phoenix request, an Oban job. A `Glider.transaction/2` is a
  span too, and the statements inside it are its children. Attribute names
  are the same ones glider's native and wasm runtimes use:

    * `db.system.name` (`"glider"`), `db.operation.name`, `db.query.text`,
      `db.response.returned_rows`, `db.stored_procedure.name` (for `CALL`)
    * `glider.db`, `glider.touched`, `glider.page.reads`, `glider.page.writes`,
      `glider.page.hits`, `glider.page.misses`

  Needs `:opentelemetry_api` (an optional dependency of glider_ex) and, to
  export anything, the `:opentelemetry` SDK with an exporter. Without the API
  `setup/1` returns `{:error, :opentelemetry_not_loaded}` and glider runs as
  before.

  Options:

    * `:query_text` - record statements as `db.query.text`. Default `true`.
      Parameters (`$name`) are never recorded, only the text.
  """

  # opentelemetry_api is optional: compile cleanly without it.
  @compile {:no_warn_undefined, [:opentelemetry, :otel_tracer, :otel_span, :otel_ctx]}

  @spans [:query, :transaction, :checkpoint, :import, :export, :procedure]
  @handler __MODULE__
  @max_query_text 2048

  @spec setup(keyword()) :: :ok | {:error, :opentelemetry_not_loaded | :already_exists}
  def setup(opts \\ []) do
    if Code.ensure_loaded?(:otel_tracer) do
      events = for s <- @spans, phase <- [:start, :stop, :exception], do: [:glider, s, phase]
      config = %{query_text: Keyword.get(opts, :query_text, true)}
      :telemetry.attach_many(@handler, events, &__MODULE__.handle_event/4, config)
    else
      {:error, :opentelemetry_not_loaded}
    end
  end

  @doc "Detach the handlers `setup/1` attached."
  @spec teardown() :: :ok | {:error, :not_found}
  def teardown, do: :telemetry.detach(@handler)

  @doc false
  def handle_event([:glider, kind, :start], _measurements, meta, config) do
    parent = :otel_ctx.get_current()
    tracer = :opentelemetry.get_tracer(:glider_ex)

    span =
      :otel_tracer.start_span(tracer, "glider #{kind}", %{
        kind: :client,
        attributes: start_attributes(kind, meta, config)
      })

    :otel_tracer.set_current_span(span)
    Process.put({__MODULE__, meta.telemetry_span_context}, {parent, span})
  end

  def handle_event([:glider, _kind, :stop], measurements, meta, _config) do
    with {parent, span} <- Process.delete({__MODULE__, meta.telemetry_span_context}) do
      if op = meta[:operation], do: :otel_span.update_name(span, "glider #{op}")
      :otel_span.set_attributes(span, stop_attributes(measurements, meta))

      if meta[:result] == :error do
        :otel_span.set_status(span, :opentelemetry.status(:error, describe(meta[:error])))
      end

      finish(span, parent)
    end
  end

  def handle_event([:glider, _kind, :exception], _measurements, meta, _config) do
    with {parent, span} <- Process.delete({__MODULE__, meta.telemetry_span_context}) do
      :otel_span.record_exception(span, meta.kind, meta.reason, meta.stacktrace, %{})
      :otel_span.set_status(span, :opentelemetry.status(:error, describe(meta.reason)))
      finish(span, parent)
    end
  end

  defp finish(span, parent) do
    :otel_span.end_span(span)
    :otel_ctx.attach(parent)
  end

  defp start_attributes(:query, %{query: q}, %{query_text: true}) do
    %{
      "db.system.name": "glider",
      "db.query.text": binary_part(q, 0, min(byte_size(q), @max_query_text))
    }
  end

  defp start_attributes(_kind, _meta, _config), do: %{"db.system.name": "glider"}

  defp stop_attributes(measurements, meta) do
    [
      {:"db.operation.name", meta[:operation]},
      {:"db.stored_procedure.name", meta[:procedure]},
      {:"glider.db", meta[:db_name]},
      {:"db.response.returned_rows", measurements[:rows]},
      {:"glider.touched", measurements[:touched]},
      {:"glider.page.reads", measurements[:page_reads]},
      {:"glider.page.writes", measurements[:page_writes]},
      {:"glider.page.hits", measurements[:page_hits]},
      {:"glider.page.misses", measurements[:page_misses]}
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)
end
