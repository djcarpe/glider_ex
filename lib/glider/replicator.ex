defmodule Glider.Replicator do
  @moduledoc """
  Keeps a paged database replicated: a `Glider.Replication.sync/3` pass every
  `:interval` milliseconds, retention every `:retention_every` (an hour by
  default). Put it in a supervision tree beside whatever opens the database:

      children = [
        {Glider.Replicator,
         path: "/var/lib/app/graph.gldb",
         url: "s3://graphs/app",
         endpoint: "http://minio.internal:9000",
         db: db,
         interval: 1_000}
      ]

  `:db` is the open handle, if this VM holds the database open: the pass
  polls it while a base is copied. Every other option goes to
  `Glider.Replication.sync/3`.

  A memory graph opened with `log: true` has no path: give its handle as
  `:db` and leave `:path` out.

      {Glider.Replicator, db: db, url: "s3://graphs/app", endpoint: "http://minio.internal:9000"}

  Each pass then holds the handle only to capture what it ships and to
  record that it was shipped, never while it uploads. A failed pass is logged and counted, and the
  next one picks up whatever it left pending — nothing is dropped.

  Passes run in the replicator's own process, one at a time; `status/1` and
  `sync_now/1` wait for the pass in hand.
  """

  use GenServer
  require Logger

  alias Glider.Replication

  @type status :: %{
          path: String.t() | nil,
          url: String.t(),
          passes: non_neg_integer(),
          errors: non_neg_integer(),
          last: Replication.report() | nil,
          last_error: String.t() | nil,
          last_at: DateTime.t() | nil
        }

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, {__MODULE__, source(opts), Keyword.fetch!(opts, :url)}),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Where the replicator stands: passes, errors, the last report."
  @spec status(GenServer.server()) :: status()
  def status(server), do: GenServer.call(server, :status, :infinity)

  @doc "Run a pass now (with `force_snapshot: true` for a new base) and return its result."
  @spec sync_now(GenServer.server(), keyword()) ::
          {:ok, Replication.report()} | {:error, String.t()}
  def sync_now(server, opts \\ []), do: GenServer.call(server, {:sync_now, opts}, :infinity)

  @impl true
  def init(opts) do
    source = source(opts)
    path = if is_binary(source), do: source
    url = Keyword.fetch!(opts, :url)
    interval = Keyword.get(opts, :interval, 1_000)
    retention_every = Keyword.get(opts, :retention_every, 3_600_000)
    sync_opts = Keyword.drop(opts, [:path, :url, :interval, :retention_every])

    state = %{
      path: path,
      source: source,
      url: url,
      interval: interval,
      retention_every: retention_every,
      sync_opts: sync_opts,
      last_retention: System.monotonic_time(:millisecond),
      passes: 0,
      errors: 0,
      last: nil,
      last_error: nil,
      last_at: nil
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    retention? = now - state.last_retention >= state.retention_every
    {_result, state} = pass(state, enforce_retention: retention?)
    state = if retention?, do: %{state | last_retention: now}, else: state
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:path, :url, :passes, :errors, :last, :last_error, :last_at]),
     state}
  end

  def handle_call({:sync_now, opts}, _from, state) do
    {result, state} = pass(state, opts)
    {:reply, result, state}
  end

  defp pass(state, extra) do
    result = Replication.sync(state.source, state.url, Keyword.merge(state.sync_opts, extra))
    state = %{state | passes: state.passes + 1, last_at: DateTime.utc_now()}

    case result do
      {:ok, report} ->
        {result, %{state | last: report, last_error: nil}}

      {:error, reason} ->
        Logger.warning(
          "glider replication of #{state.path || "a memory graph"} to #{state.url}: #{reason} (retrying)"
        )

        {result, %{state | errors: state.errors + 1, last_error: reason}}
    end
  end

  # A file by its path, or a memory graph by its handle.
  defp source(opts) do
    case {Keyword.get(opts, :path), Keyword.get(opts, :db)} do
      {nil, nil} ->
        raise ArgumentError, "Glider.Replicator needs :path, or :db for a memory graph"

      {nil, db} ->
        db

      {path, _} ->
        to_string(path)
    end
  end
end
