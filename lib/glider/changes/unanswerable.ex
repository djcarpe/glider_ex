defmodule Glider.Changes.Unanswerable do
  @moduledoc """
  The change journal cannot answer for the revision asked about: it never
  held, or no longer holds, every change after it. This is never "nothing
  changed". Rebuild what was derived from a scan of the graph, keep the
  revision read before the scan, and ask from there (at or above `oldest`,
  where there is one).

  `Glider.Changes.since/3` returns it as `{:error, %Glider.Changes.Unanswerable{}}`;
  `Glider.Changes.stream/3` raises it, from whichever slice finds it.

  The engine says it as data (the end row's `answered: false`), and it is
  not a failure of the statement: inside a transaction it leaves the
  transaction as it was.

    * `revision` - the revision asked about.
    * `reason` - why, one of the engine's fixed set:
      * `:not_installed` - there is no journal in the committed state (it
        is installed only by the open transaction);
      * `:installed` - the revision is before the journal was installed;
      * `:released` - `Glider.Changes.release/3` forgot the changes at or
        below `oldest`;
      * `:cap` - the cap pushed out the changes at or below `oldest`;
      * `:cleared` - the graph was cleared (or written in bulk) at `oldest`;
      * `:reset` - the journal's state was lost and started again at `oldest`;
      * `:ahead` - the revision (or a cursor's) is past the committed
        revision: another line of history, a later state of a copy, or a
        position of a transaction that never committed;
      * `:restarting` - positions went back; the journal answers nothing
        until it starts again.
    * `oldest` - the oldest revision the journal answers for, where the
      engine names one; `nil` otherwise.
    * `message` - the engine's explanation, for people (its wording is not
      a contract and nothing is read from it).
  """
  defexception [:revision, :reason, :oldest, :message]

  @type reason ::
          :not_installed
          | :installed
          | :released
          | :cap
          | :cleared
          | :reset
          | :ahead
          | :restarting

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          reason: reason(),
          oldest: non_neg_integer() | nil,
          message: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{revision: rev, reason: reason, oldest: oldest, message: text}) do
    floor = if oldest, do: "; it answers for revision #{oldest} and later", else: ""
    base = "the change journal cannot answer for revision #{rev} (#{reason})#{floor}"
    if text, do: base <> ": " <> text, else: base
  end
end
