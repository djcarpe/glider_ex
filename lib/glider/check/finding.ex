defmodule Glider.Check.Finding do
  @moduledoc """
  One thing `Glider.Check.run/2` found.

    * `check` - the check that found it (`"endpoints"`, `"orphans"`, ...).
    * `severity` - `:fault` (the database disagrees with itself),
      `:candidate` (a fact about the data for a person or a rule to decide
      on) or `:info` (an installed extension that cannot be checked).
    * `kind` - what is wrong, in a word (`"missing_target"`, `"orphan"`;
      an extension's findings carry its name, `"context.stale_node"`).
    * `id` - the record at fault: `"n12"` for a node, `"e12"` for an edge
      (the handles `Glider.Context` uses and accepts back), or the name of
      the label, type, index or counter.
    * `detail` - what is wrong, in a sentence.
  """
  defstruct [:check, :severity, :kind, :id, :detail]

  @type t :: %__MODULE__{
          check: String.t(),
          severity: :fault | :candidate | :info | String.t(),
          kind: String.t(),
          id: String.t() | nil,
          detail: String.t() | nil
        }
end
