defmodule Glider.Changes.Unanswerable do
  @moduledoc """
  The change journal cannot answer for the revision asked about: it never
  held, or no longer holds, every change after it. This is never "nothing
  changed". Rebuild what was derived from a scan of the graph, keep the
  revision read before the scan, and ask from there (it is at or above
  `oldest`).

  `Glider.Changes.since/3` returns it as `{:error, %Glider.Changes.Unanswerable{}}`;
  `Glider.Changes.stream/3` raises it.

    * `revision` - the revision asked about.
    * `oldest` - the oldest revision the journal answers for now. Always
      set for `:below_oldest`; `nil` while it is starting again
      (`reason: :restarting`), and for `:ahead` only if the journal's
      status could not be read just after.
    * `reason` - `:below_oldest` (older than `oldest`), `:ahead` (past this
      database's own revision: another line of history, or a later state of
      a copy), or `:restarting` (the journal holds positions past the
      database's, forgets them, and answers nothing until the writes that
      follow have emptied it).
    * `why` - with `:below_oldest` or `:ahead`, why `oldest` is where it is
      (as in `Glider.Changes.Status`).
    * `message` - the engine's explanation.
  """
  defexception [:revision, :oldest, :reason, :why, :message]

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          oldest: non_neg_integer() | nil,
          reason: :below_oldest | :ahead | :restarting,
          why: atom() | String.t() | nil,
          message: String.t()
        }
end
