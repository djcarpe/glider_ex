defmodule Glider.Changes.Status do
  @moduledoc """
  The change journal's state (`Glider.Changes.status/2`).

    * `oldest` - the oldest revision `since/3` answers for.
    * `why` - why it is that one: `:installed` (the journal knows nothing
      from before its install), `:released` (`release/3`), `:cap` (the cap
      forgot what was below), `:cleared` (a `CLEAR`), `:reset` (its state
      was lost and started again).
    * `entries`, `bytes` - what the journal holds.
    * `cap` - the most entries it holds.
    * `revision` - the database's revision.
  """
  defstruct [:oldest, :why, :entries, :bytes, :cap, :revision]

  @type t :: %__MODULE__{
          oldest: non_neg_integer(),
          why: :installed | :released | :cap | :cleared | :reset | String.t(),
          entries: non_neg_integer(),
          bytes: non_neg_integer(),
          cap: pos_integer(),
          revision: non_neg_integer()
        }
end
