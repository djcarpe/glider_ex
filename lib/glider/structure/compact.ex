defmodule Glider.Structure.Compact do
  @moduledoc """
  A selection of nodes written in `glider-compact/1` with a kept
  dictionary (`Glider.Structure.compact/4`).

    * `text` - the text. Its first line names the dictionary by hash when
      any of its templates or patterns is used, and the dictionary is not
      repeated: give a reader `Glider.Structure.dictionary_text/3` once.
    * `hash` - the hash of the dictionary it was written with.
    * `dictionary` - the dictionary's name.
    * `revision`, `fresh` - the dictionary's revision and whether it is
      fresh, as the engine says in the same transaction as the text.
    * `bytes`, `tokens` - the size of the text.
    * `plain_bytes`, `plain_tokens` - the size of the same nodes written
      plainly; `saving_bytes`, `saving_tokens` the difference.
  """
  defstruct [
    :text,
    :hash,
    :dictionary,
    :revision,
    :fresh,
    :bytes,
    :tokens,
    :plain_bytes,
    :plain_tokens,
    :saving_bytes,
    :saving_tokens
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          hash: String.t(),
          dictionary: String.t(),
          revision: non_neg_integer(),
          fresh: boolean(),
          bytes: non_neg_integer(),
          tokens: non_neg_integer(),
          plain_bytes: non_neg_integer(),
          plain_tokens: non_neg_integer(),
          saving_bytes: integer(),
          saving_tokens: integer()
        }
end
