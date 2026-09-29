defmodule Glider.Telemetry do
  @moduledoc """
  Observability for glider on the BEAM.

  The engine keeps its own numbers — statement counters, a duration
  histogram, a report on every statement, per-database state — using the same
  metric and attribute names as glider's other runtimes (native, wasm).
  This module gets them into the BEAM's observability stack three ways:

    1. **`:telemetry` events**, emitted by `Glider` itself (below). Attach
       `Telemetry.Metrics` reporters to them, or `Glider.OpenTelemetry.setup/1`
       to turn them into OpenTelemetry spans.
    2. **Pull**: `snapshot/0`, `metrics/1`, `prometheus/1`, `otlp_metrics/2`,
       and `emit_db_metrics/1` for `:telemetry_poller`.
    3. **The engine's own OTLP exporter** (`start_exporter/1`), which pushes
       the metrics to a collector from Rust, configured by the standard
       `OTEL_*` environment variables — metrics without a BEAM metrics SDK.

  ## Events

  Every span is `:telemetry.span/3`: a `:start` event with `system_time` and
  `monotonic_time`, then `:stop` with `duration`, or `:exception` with `kind`,
  `reason` and `stacktrace`. Every event's metadata carries `:db` (the handle).

  | event | extra metadata | extra `:stop` measurements |
  |---|---|---|
  | `[:glider, :query, _]` | `:query`; on stop `:operation`, `:procedure`, `:db_name`, `:result`, `:error` | `rows`, `touched`, `page_reads`, `page_writes`, `page_hits`, `page_misses`, `engine_duration` |
  | `[:glider, :transaction, _]` | on stop `:result`, `:error` | |
  | `[:glider, :checkpoint, _]` | on stop `:result`, `:error` | |
  | `[:glider, :import, _]` | `:bytes`; on stop `:result`, `:error` | |
  | `[:glider, :export, _]` | on stop `:result`, `:error` | |
  | `[:glider, :procedure, _]` | `:procedure`; on stop `:operation` (`"CALL"`), `:result`, `:error` | `rows` |

  `[:glider, :procedure, _]` is the contract for procedures that run outside
  the engine, in Elixir — `glider_extensions_ex` emits it for `text.embed`,
  `cluster.kmeans` and the rest — so they are measured and traced like the
  engine's own `CALL`s.

  `:operation` is the statement kind the engine parsed — `"MATCH"`,
  `"CREATE"`, `"CALL"`, ... or `"INVALID"` — and `:procedure` the algorithm a
  `CALL` ran. `:result` is `:ok` or `:error`, and a failed call's `:error` is
  the reason. `engine_duration` is the time inside the engine, in native time
  units, like `duration`; the difference is the NIF boundary and term
  building.

  `emit_db_metrics/1` emits `[:glider, :db]` with the `t:db_metrics/0` fields
  as measurements and `%{db: handle, db_name: name}` as metadata.

  ## With Telemetry.Metrics

      [
        counter("glider.query.stop.duration", tags: [:operation, :result]),
        distribution("glider.query.stop.duration",
          unit: {:native, :millisecond}, tags: [:operation]),
        sum("glider.query.stop.page_misses", tags: [:operation]),
        last_value("glider.db.nodes", tags: [:db_name]),
        last_value("glider.db.log_bytes", tags: [:db_name])
      ]

  with `{:telemetry_poller, measurements: [{Glider.Telemetry, :emit_db_metrics, [db]}]}`.
  """

  alias Glider.Native

  @typedoc "One graph's state, from the engine."
  @type db_metrics :: %{
          name: String.t(),
          nodes: non_neg_integer(),
          edges: non_neg_integer(),
          bytes: non_neg_integer(),
          memory_limit: non_neg_integer() | nil,
          page_size: non_neg_integer(),
          resident_pages: non_neg_integer(),
          allocated_pages: non_neg_integer(),
          log_bytes: non_neg_integer(),
          page_reads: non_neg_integer(),
          page_writes: non_neg_integer(),
          page_hits: non_neg_integer(),
          page_misses: non_neg_integer(),
          evictions: non_neg_integer(),
          commits: non_neg_integer(),
          rollbacks: non_neg_integer(),
          checkpoints: non_neg_integer()
        }

  @doc """
  The engine's process-wide counters: statements by operation and outcome,
  rows, touched, page traffic, and the duration histogram (bucket bounds in
  seconds).
  """
  @spec snapshot() :: map()
  def snapshot, do: Native.telemetry_snapshot()

  @doc "One graph's counts, size, cache, I/O and commit counters."
  @spec metrics(Glider.db()) :: {:ok, db_metrics()} | {:error, String.t()}
  def metrics(db), do: Native.db_metrics(db)

  @doc """
  The engine's counters, plus the given graphs, in the Prometheus text
  format — serve it from a `/metrics` plug.
  """
  @spec prometheus(Glider.db() | [Glider.db()]) :: String.t()
  def prometheus(dbs \\ []), do: Native.metrics_prometheus(List.wrap(dbs))

  @doc """
  The engine's counters, plus the given graphs, as an OTLP/HTTP JSON metrics
  request, ready to POST to `<collector>/v1/metrics`.
  """
  @spec otlp_metrics(Glider.db() | [Glider.db()], String.t()) :: String.t()
  def otlp_metrics(dbs \\ [], service \\ "glider"),
    do: Native.metrics_otlp(List.wrap(dbs), service)

  @doc """
  Emit `[:glider, :db]` with each graph's `t:db_metrics/0` as measurements.
  Closed graphs are skipped. Made for `:telemetry_poller`.
  """
  @spec emit_db_metrics(Glider.db() | [Glider.db()]) :: :ok
  def emit_db_metrics(dbs) do
    for db <- List.wrap(dbs), {:ok, m} <- [Native.db_metrics(db)] do
      {name, measurements} = Map.pop(m, :name)

      measurements =
        if measurements.memory_limit,
          do: measurements,
          else: Map.delete(measurements, :memory_limit)

      :telemetry.execute([:glider, :db], measurements, %{db: db, db_name: name})
    end

    :ok
  end

  @doc """
  Start the engine's own OTLP/HTTP exporter, configured from the standard
  environment (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`,
  `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_EXPORTER_OTLP_HEADERS`,
  `OTEL_METRIC_EXPORT_INTERVAL`, ...; see glider's docs/OBSERVABILITY.md). It
  pushes the engine's metrics — every open graph included — from a Rust
  thread. `http://` endpoints only.

  Options:

    * `:service` - `service.name` when `OTEL_SERVICE_NAME` is unset. Default
      `"glider"`.
    * `:traces` - also export a span per statement from the engine. Default
      `false`: on the BEAM, trace with `Glider.OpenTelemetry` instead, which
      parents spans under the calling process's context.

  Returns `{:ok, true}` when an exporter is running, `{:ok, false}` when the
  environment asks for none. The first start in the OS process wins.
  """
  @spec start_exporter(keyword()) :: {:ok, boolean()} | {:error, String.t()}
  def start_exporter(opts \\ []) do
    Native.start_exporter(
      Keyword.get(opts, :service, "glider"),
      Keyword.get(opts, :traces, false)
    )
  end

  @doc "Push the engine exporter's pending data now, e.g. before shutdown."
  @spec flush_exporter() :: :ok
  def flush_exporter, do: Native.flush_exporter()

  # ------------------------------------------------------------ for Glider

  @doc false
  # The engine's report as :stop measurements.
  def measurements(nil), do: %{}

  def measurements(op) do
    m = Map.take(op, [:rows, :touched, :page_reads, :page_writes, :page_hits, :page_misses])

    case op.duration_ns do
      nil -> m
      ns -> Map.put(m, :engine_duration, System.convert_time_unit(ns, :nanosecond, :native))
    end
  end

  @doc false
  def stop_metadata(meta, nil, result), do: Map.put(meta, :result, result)

  def stop_metadata(meta, op, result) do
    Map.merge(meta, %{
      result: result,
      operation: op.op,
      procedure: op.procedure,
      db_name: op.db
    })
  end
end
