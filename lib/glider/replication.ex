defmodule Glider.Replication do
  @moduledoc """
  Continuous replication of a paged glider database to S3, a directory or an
  `exec:` command, and restore from there: glider-stream's paged replication
  (glider's `docs/STREAM.md`, "Paged databases"), called in-process.

  A replica is base snapshots plus the write-ahead log shipped after them:

      <generation>/base/<lsn>/db, data/*.seg, base.json   one checkpoint's pages
      <generation>/segments/<offset>-<unix>.seg            log, whole transactions

  The paged tailer ships into a local spool (`<db>-stream/<hash of url>/`
  unless `:spool` says otherwise), and after every pass whatever it completed
  is uploaded — a base's `base.json` last, so a base is whole only once it is
  all there. A failed upload stays pending for the next pass. `restore/3`
  takes the newest base at or before `:as_of` and the log after it, and
  `Glider.open/2` on the result replays that log.

  ## Replica urls

    * `"/var/backups/app"` or `"file:///var/backups/app"` — a directory
    * `"s3://bucket/prefix"` — S3-compatible (MinIO, SeaweedFS, Ceph…) over a
      plaintext `:endpoint`; with no endpoint, or an `https://` one, the `aws`
      CLI on `PATH` is used instead (glider has no TLS stack)
    * `"exec:<label>"` — shell commands (see glider's docs)

  ## Options

    * `:endpoint` — S3 endpoint, e.g. `"http://minio.internal:9000"`
    * `:region` — S3 region (default `"us-east-1"`)
    * `:access_key_id`, `:secret_access_key` — default from
      `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
    * `:spool` — where the tailer ships before upload
    * `:min_bytes` — ship as soon as this much log is pending (default 0)
    * `:snapshot_interval` — seconds; take a new base when the newest is this
      old (default a day; 0 never, except when the log needed is gone)
    * `:retention`, `:retention_enabled` — seconds to keep old bases, log and
      idle generations (default a day, enabled)

  ## The writer

  A base is copied from a checkpoint the writer holds in place for the copy.
  The writer notices the request at its next commit, or when polled. When the
  database is open in this VM, pass the handle as `db:` and `sync/3` polls it
  while the pass runs; otherwise a base waits for the next commit.
  """

  alias Glider.Native

  @type url :: String.t()
  @type report :: %{
          generation: String.t(),
          bases_uploaded: non_neg_integer(),
          segments_uploaded: non_neg_integer(),
          bytes: non_neg_integer(),
          deleted: non_neg_integer(),
          lag_bytes: non_neg_integer() | nil
        }

  @backend_opts ~w(endpoint region access_key_id secret_access_key spool min_bytes snapshot_interval retention retention_enabled)a
  @poll_ms 100

  @doc """
  One pass: ship what is pending and upload it. Returns what was uploaded.

  Extra options: `:db` (an open handle to poll while a base is copied),
  `:force_snapshot` (take a new base now), `:enforce_retention` (run
  retention afterwards).
  """
  @spec sync(Path.t(), url(), keyword()) :: {:ok, report()} | {:error, String.t()}
  def sync(path, url, opts \\ []) do
    native_opts = native_opts(opts)
    force = Keyword.get(opts, :force_snapshot, false)
    retention = Keyword.get(opts, :enforce_retention, false)
    call = fn -> Native.replication_sync(to_string(path), url, native_opts, force, retention) end

    started = System.monotonic_time()

    result =
      case Keyword.get(opts, :db) do
        nil -> call.()
        db -> polling(db, call)
      end

    :telemetry.execute(
      [:glider, :replication, :sync],
      measurements(result, started),
      %{path: to_string(path), url: url, result: elem(result, 0)}
    )

    result
  end

  @doc """
  Rebuild a database at `out` from the replica at `url`. Options: `:as_of`
  (unix seconds: the newest base taken by then and the log shipped by then),
  `:generation` (a specific lineage), and the backend options. Open the
  result with `Glider.open/2` to finish; opening replays the log.
  """
  @spec restore(url(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def restore(url, out, opts \\ []) do
    Native.replication_restore(
      url,
      to_string(out),
      Keyword.get(opts, :generation),
      Keyword.get(opts, :as_of),
      native_opts(opts)
    )
  end

  @doc "Generations held at `url`, least recently active first."
  @spec generations(url(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def generations(url, opts \\ []), do: Native.replication_generations(url, native_opts(opts))

  @doc """
  What `url` holds for one generation: its bases (`lsn`, `epoch`, `ts`,
  `bytes`), segments (`offset`, `len`, `ts`), how far the log is whole
  (`complete_to`), `log_bytes` and `last_ts`.
  """
  @spec listing(url(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def listing(url, generation, opts \\ []),
    do: Native.replication_listing(url, generation, native_opts(opts))

  @doc "Committed log at `path` not yet at `url`, in bytes."
  @spec lag(Path.t(), url(), keyword()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def lag(path, url, opts \\ []), do: Native.replication_lag(to_string(path), url, native_opts(opts))

  @doc """
  Delete bases older than `:retention` (never the newest), the log below the
  oldest base kept, and generations idle longer than that (never the
  current one). Returns how many objects went.
  """
  @spec enforce_retention(Path.t(), url(), keyword()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def enforce_retention(path, url, opts \\ []),
    do: Native.replication_enforce_retention(to_string(path), url, native_opts(opts))

  # Run the pass in a task and poll the writer until it finishes, so a base
  # copy is never left waiting for a commit that may not come.
  defp polling(db, call) do
    task = Task.async(call)
    poll(db, task)
  end

  defp poll(db, task) do
    case Task.yield(task, @poll_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, "replication pass crashed: #{inspect(reason)}"}

      nil ->
        _ = Glider.poll_replication(db)
        poll(db, task)
    end
  end

  defp native_opts(opts) do
    for {k, v} <- opts, k in @backend_opts, not is_nil(v), into: %{} do
      {Atom.to_string(k), if(is_boolean(v) or is_integer(v), do: v, else: to_string(v))}
    end
  end

  defp measurements({:ok, r}, started) do
    %{
      duration: System.monotonic_time() - started,
      bytes: r.bytes,
      bases: r.bases_uploaded,
      segments: r.segments_uploaded,
      lag_bytes: r.lag_bytes || 0
    }
  end

  defp measurements(_error, started), do: %{duration: System.monotonic_time() - started}
end
