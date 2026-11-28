defmodule Glider.Changes.Slice do
  @moduledoc """
  One slice of `Glider.Changes.since/3`, read from the engine's end row.

    * `changes` - the `Glider.Changes.Change`s in this slice. Empty with
      `complete: true` means nothing changed.
    * `complete` - `true` when this slice ends the answer: with the slices
      before it, it is the whole answer.
    * `after` - `nil` on the last slice; otherwise an opaque cursor, to
      pass back exactly as given as `after:` with the same revision and
      `:kinds`, to the same database. Do not read or build one.
    * `complete_up_to` - the committed revision the answer is complete up
      to (the engine's watermark): that of the answer's first slice, so a
      change committed between two slices to an id already passed is
      listed by the next question from it. Keep the last slice's and ask
      from it next time.
  """
  defstruct changes: [], complete: false, after: nil, complete_up_to: nil

  @type t :: %__MODULE__{
          changes: [Glider.Changes.Change.t()],
          complete: boolean(),
          after: String.t() | nil,
          complete_up_to: non_neg_integer() | nil
        }
end
