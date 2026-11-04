defmodule Glider.Native do
  @moduledoc false
  # Raw NIF surface. Everything here returns bare values or raises; the public
  # wrapping into {:ok, _} / {:error, _} happens in `Glider`.
  #
  # Not part of the public API — the shapes here follow whatever is cheapest to
  # produce in Rust, not whatever is nicest to use.

  use Rustler, otp_app: :glider_ex, crate: "glider_nif"

  def open_memory(_max_bytes), do: err()
  def open_file(_path, _sync, _cache_size, _work_mem, _checkpoint_bytes), do: err()
  def legacy_kind(_path), do: err()
  def migrate(_path), do: err()
  def query(_db, _q, _params), do: err()
  def schema(_db), do: err()
  def expand(_db, _id, _limit), do: err()
  def import_jsonl(_db, _jsonl), do: err()
  def export_jsonl(_db), do: err()
  def checkpoint(_db), do: err()
  def begin(_db), do: err()
  def commit(_db), do: err()
  def rollback(_db), do: err()
  def in_transaction(_db), do: err()
  def poll_replication(_db), do: err()
  def replication_sync(_db_path, _url, _opts, _force_snapshot, _enforce_retention), do: err()
  def replication_enforce_retention(_db_path, _url, _opts), do: err()
  def replication_lag(_db_path, _url, _opts), do: err()
  def replication_restore(_url, _out, _generation, _as_of, _opts), do: err()
  def replication_generations(_url, _opts), do: err()
  def replication_listing(_url, _generation, _opts), do: err()
  def close(_db), do: err()
  def version, do: err()
  def telemetry_snapshot, do: err()
  def db_metrics(_db), do: err()
  def metrics_prometheus(_dbs), do: err()
  def metrics_otlp(_dbs, _service), do: err()
  def start_exporter(_service, _traces), do: err()
  def flush_exporter, do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
