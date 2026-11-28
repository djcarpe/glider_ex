defmodule Glider.Check.Summary do
  @moduledoc """
  How one check went in one call: `status` `:done`, or `:partial` when the
  call stopped inside it (then `cursor` is the same opaque cursor as the
  report's `after`), with the
  records it looked at and the problems it found in this call.
  """
  defstruct [:check, :status, :records, :problems, :cursor]

  @type t :: %__MODULE__{
          check: String.t(),
          status: :done | :partial,
          records: non_neg_integer(),
          problems: non_neg_integer(),
          cursor: String.t() | nil
        }
end
