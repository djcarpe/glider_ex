defmodule Glider.Check.Report do
  @moduledoc """
  The result of one `Glider.Check.run/2` call (one slice).

    * `findings` - `Glider.Check.Finding`s, in the order the checks met them.
    * `summaries` - one `Glider.Check.Summary` per check this call ran.
    * `complete` - `true` when this slice ends the run (from the engine's
      end row).
    * `after` - `nil` when the run is complete; otherwise the opaque cursor
      the end row gives, to pass back exactly as given as `after:` with the
      same other options for the next slice.
    * `message` - the engine's one-line account.

  A complete run with no findings of severity `:fault` is a database whose
  records agree with each other and with what its extensions derived.
  """
  defstruct findings: [], summaries: [], complete: false, after: nil, message: nil

  @type t :: %__MODULE__{
          findings: [Glider.Check.Finding.t()],
          summaries: [Glider.Check.Summary.t()],
          complete: boolean(),
          after: String.t() | nil,
          message: String.t() | nil
        }
end
