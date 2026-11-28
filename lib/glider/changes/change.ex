defmodule Glider.Changes.Change do
  @moduledoc """
  One entry of the change journal: the latest change to one node, edge or
  adjacency (the edges at a node) after the revision asked about.

    * `kind` - `:node`, `:edge` or `:adjacency`.
    * `id` - the node's or edge's id (for `:adjacency`, the node's).
    * `change` - `:put` (it exists, with what the graph holds now) or
      `:drop` (it is gone).
    * `revision` - the log position of that change.
  """
  defstruct [:kind, :id, :change, :revision]

  @type t :: %__MODULE__{
          kind: :node | :edge | :adjacency,
          id: non_neg_integer(),
          change: :put | :drop,
          revision: non_neg_integer()
        }
end
