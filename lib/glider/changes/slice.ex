defmodule Glider.Changes.Slice do
  @moduledoc """
  One slice of `Glider.Changes.since/3`.

    * `changes` - the `Glider.Changes.Change`s in this slice. Empty with
      `after: nil` means nothing changed.
    * `after` - `nil` for the last slice; otherwise the position to pass as
      `after:` to get the next.
    * `complete_up_to` - on the last slice, the database position the
      answer is complete up to (its revision, outside a transaction).
  """
  defstruct changes: [], after: nil, complete_up_to: nil

  @type t :: %__MODULE__{
          changes: [Glider.Changes.Change.t()],
          after: String.t() | nil,
          complete_up_to: non_neg_integer() | nil
        }
end
