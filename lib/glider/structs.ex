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

  When requested with `Glider.query/4` and `graph: true`, `graph` holds
  every node and relationship that appeared in `rows`,
  deduplicated, with the endpoints of any returned relationship pulled in so
  the set is always drawable. That means `MATCH ()-[r]->() RETURN r` still
  gives you both endpoints. The default projection is empty.
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

defmodule Glider.Health do
  @moduledoc """
  What `Glider.health/2` reports.

    * `revision`, `generation` - the database's revision and lineage
      (`Glider.revision/2`, `Glider.generation/2`).
    * `nodes`, `edges` - counts the engine keeps, not a scan.
    * `memory_bytes` - a memory graph's pages; for a file, the cached pages.
    * `max_memory` - a memory graph's limit; `nil` for a file.
    * `file_bytes`, `log_bytes` - the file's size and the log a crash
      would replay (0 for a memory graph).
    * `extensions` - the extensions installed in this database, as
      `%{name: name, version: version}`.
    * `changes` - the change journal's `Glider.Changes.Status` when it is
      installed (and not skipped with `changes: false`), else `nil`.
    * `read_error` - the storage read error the engine has recorded since
      it was last reported, or `nil`.
  """

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          generation: String.t(),
          nodes: non_neg_integer(),
          edges: non_neg_integer(),
          memory_bytes: non_neg_integer() | nil,
          max_memory: non_neg_integer() | nil,
          file_bytes: non_neg_integer(),
          log_bytes: non_neg_integer(),
          extensions: [%{name: String.t(), version: String.t()}],
          changes: Glider.Changes.Status.t() | nil,
          read_error: String.t() | nil
        }

  defstruct [
    :revision,
    :generation,
    :nodes,
    :edges,
    :memory_bytes,
    :max_memory,
    :file_bytes,
    :log_bytes,
    :changes,
    :read_error,
    extensions: []
  ]
end
