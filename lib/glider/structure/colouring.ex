defmodule Glider.Structure.Colouring do
  @moduledoc """
  A kept colouring (`Glider.Structure.stored/2`).

    * `name` - the name it was kept under.
    * `revision` - the committed revision it was computed at (or the
      position inside the transaction that kept it, below the revision
      that transaction committed at).
    * `fresh` - whether the database is unchanged since in what counts
      (with the `changes` journal installed, no node or edge changed;
      without it, nothing but this extension's own writes).
    * `depth`, `stable` - the depth asked for, and where the partition
      stopped changing (`nil` when it did not within the depth).
    * `nodes`, `colors` - how many nodes it holds and their distinct colours.
    * `code` - the version of the code that computed it.
    * `args` - the arguments it was computed with, a map with binary keys.
  """
  defstruct [:name, :revision, :fresh, :depth, :stable, :nodes, :colors, :code, :args]

  @type t :: %__MODULE__{
          name: String.t(),
          revision: non_neg_integer() | nil,
          fresh: boolean(),
          depth: non_neg_integer() | nil,
          stable: non_neg_integer() | nil,
          nodes: non_neg_integer() | nil,
          colors: non_neg_integer() | nil,
          code: String.t(),
          args: map() | String.t() | nil
        }
end
