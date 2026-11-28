defmodule Glider.Changes.InTransaction do
  @moduledoc """
  `Glider.Changes.since/3` (or a `Glider.Changes.stream/3` being consumed)
  was called inside a transaction, and refused before anything reached the
  engine; the transaction is untouched.

  Inside a transaction the journal lists the transaction's own pending
  writes, and the position it would report as complete is one that is
  never committed if the transaction rolls back: asked from later, it would
  leave out changes committed in between. Ask outside the transaction,
  before it or after it ends. This is not "nothing changed", and not
  "cannot answer": nothing was asked.
  """
  defexception message:
                 "Glider.Changes.since/3 is refused inside a transaction: ask before it or after it ends"

  @type t :: %__MODULE__{message: String.t()}
end
