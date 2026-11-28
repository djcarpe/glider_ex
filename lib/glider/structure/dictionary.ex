defmodule Glider.Structure.Dictionary do
  @moduledoc """
  A kept dictionary of templates and chain patterns
  (`Glider.Structure.dictionaries/2`).

    * `name` - the name it was kept under.
    * `revision` - the committed revision it was made at (as for a
      `Glider.Structure.Colouring`).
    * `fresh` - whether the database is unchanged since in what counts (as
      for a colouring). A stale dictionary costs uses, never truth: an
      occurrence is written as a use only where it agrees with the graph now.
    * `hash` - the hash that names its text; a compact text written with it
      names it by this hash on its first line.
    * `templates`, `patterns` - how many of each it defines.
    * `bytes`, `tokens` - the size of its text.
    * `code` - the version of the code that made it.
    * `args` - the arguments it was made with, a map with binary keys.
    * `stored_bytes` - every record kept for it.
  """
  defstruct [
    :name,
    :revision,
    :fresh,
    :hash,
    :templates,
    :patterns,
    :bytes,
    :tokens,
    :code,
    :args,
    :stored_bytes
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          revision: non_neg_integer() | nil,
          fresh: boolean(),
          hash: String.t() | nil,
          templates: non_neg_integer() | nil,
          patterns: non_neg_integer() | nil,
          bytes: non_neg_integer() | nil,
          tokens: non_neg_integer() | nil,
          code: String.t(),
          args: map() | String.t() | nil,
          stored_bytes: non_neg_integer() | nil
        }
end
