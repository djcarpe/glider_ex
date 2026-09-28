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
  def close(_db), do: err()
  def version, do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
