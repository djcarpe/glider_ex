defmodule Glider.Structure.Slice do
  @moduledoc """
  One slice of a `Glider.Structure` answer (`colors/2`, `classes/2`,
  `read/3`, `templates/2`, `paths/2`), read from the engine's end row.

    * `rows` - the procedure's rows, each a map keyed by the engine's
      column names (binaries, from data): `"id"`, `"color"` for colours,
      `"class"`, `"size"`, `"first"`, `"members"` for classes, and so on
      (see glider's `docs/EXTENSIONS.md`, "structure").
    * `complete` - `true` when this slice ends the answer.
    * `after` - `nil` on the last slice; otherwise the opaque cursor to
      pass back exactly as given as `after:`, with the same other options.
    * `kept` - for `read/3`, the kept colouring's `Glider.Structure.Colouring`
      (its revision and whether it is fresh) as of this slice; `nil`
      otherwise.
    * `message` - the engine's account, for people; nothing is read from it.
  """
  defstruct rows: [], complete: false, after: nil, kept: nil, message: nil

  @type t :: %__MODULE__{
          rows: [%{String.t() => Glider.prop()}],
          complete: boolean(),
          after: String.t() | nil,
          kept: Glider.Structure.Colouring.t() | nil,
          message: String.t() | nil
        }
end
