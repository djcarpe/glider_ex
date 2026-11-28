defmodule Glider.Structure.Plan do
  @moduledoc """
  One slice of `Glider.Structure.plan/2`.

    * `total` - the `total` row (on the first slice), a map keyed by the
      engine's columns: `"id"` (the dictionary's hash), `"chosen"` (whether
      the compact text is shorter), `"uses"`, `"define_bytes"`,
      `"define_tokens"` (the dictionary), `"use_bytes"`, `"use_tokens"`
      (the compact text), `"plain_bytes"`, `"plain_tokens"`,
      `"saving_bytes"`, `"saving_tokens"`, and `"text"` (the text asked for
      with `text:`).
    * `candidates` - one map a template or chain pattern considered
      (`"kind"`, `"id"`, `"chosen"`, `"uses"`, `"nested_in"`, costs).
    * `complete`, `after` - from the end row, as in `Glider.Structure.Slice`.
    * `kept` - with `dictionary:`, that dictionary's
      `Glider.Structure.Dictionary` (revision, freshness) as of this call.
    * `message` - the engine's account, for people.
  """
  defstruct total: nil, candidates: [], complete: false, after: nil, kept: nil, message: nil

  @type t :: %__MODULE__{
          total: %{String.t() => Glider.prop()} | nil,
          candidates: [%{String.t() => Glider.prop()}],
          complete: boolean(),
          after: String.t() | nil,
          kept: Glider.Structure.Dictionary.t() | nil,
          message: String.t() | nil
        }
end
