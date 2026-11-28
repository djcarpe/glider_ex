defmodule Glider.Structure.Stale do
  @moduledoc """
  A kept colouring or dictionary was asked for with `fresh: :require` and
  the database has changed since it was made, so nothing was answered from
  it. Compute it again (`store:`), or ask with `fresh: :report`.

  Returned as `{:error, %Glider.Structure.Stale{}}`, raised by streams.

    * `kind` - `:colouring` or `:dictionary`.
    * `name` - its name.
    * `revision` - the revision it was made at.
  """
  defexception [:kind, :name, :revision]

  @type t :: %__MODULE__{
          kind: :colouring | :dictionary,
          name: String.t(),
          revision: non_neg_integer() | nil
        }

  @impl true
  def message(%__MODULE__{kind: kind, name: name, revision: rev}) do
    "the #{kind} kept as #{inspect(name)} was made at revision #{rev} and the database " <>
      "has changed since; it was asked for with fresh: :require"
  end
end
