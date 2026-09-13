defmodule Glider.Node do
  @moduledoc """
  A node returned by a query.

  Properties are a plain map with string keys, because glider property keys are
  arbitrary strings and turning user data into atoms would be an unbounded atom
  leak — the atom table is never garbage collected.
  """

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          labels: [String.t()],
          props: %{String.t() => Glider.prop()}
        }

  defstruct id: 0, labels: [], props: %{}
end

defmodule Glider.Rel do
  @moduledoc """
  A relationship returned by a query. Directed: `from` and `to` are node ids.
  """

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          type: String.t(),
          from: non_neg_integer(),
          to: non_neg_integer(),
          props: %{String.t() => Glider.prop()}
        }

  defstruct id: 0, type: "", from: 0, to: 0, props: %{}
end

defmodule Glider.Result do
  @moduledoc """
  The result of a query.

  `graph` holds every node and relationship that appeared in `rows`,
  deduplicated, with the endpoints of any returned relationship pulled in so
  the set is always drawable. That means `MATCH ()-[r]->() RETURN r` still
  gives you both endpoints without asking for them.
  """

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[Glider.cell()]],
          graph: %{nodes: [Glider.Node.t()], edges: [Glider.Rel.t()]},
          message: String.t() | nil,
          touched: non_neg_integer()
        }

  defstruct columns: [], rows: [], graph: %{nodes: [], edges: []}, message: nil, touched: 0
end
