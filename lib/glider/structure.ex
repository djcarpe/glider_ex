defmodule Glider.Structure do
  @moduledoc """
  The engine's `structure` extension: which nodes are built alike, which
  shapes repeat, and a compact notation that says each repeated shape once.

  It reports and never merges: two stations of one design are two
  stations, and nothing here adds, deletes, connects or relabels a node.
  The only writes are the ones asked for: `store:` keeps a colouring or a
  dictionary in the extension's own keyspace, `write:` sets a colour as a
  node property.

      :ok = Glider.Structure.install(db)

      # which nodes are the same shape, to depth 4 along these edges
      {:ok, %Glider.Structure.Slice{rows: rows}} =
        Glider.Structure.colors(db, depth: 4, types: ["HAS_SIDE", "HAS_ELEMENT"], labels: ["Station"])

      # keep a dictionary of the repeated shapes once...
      {:ok, %Glider.Structure.Plan{}} =
        Glider.Structure.plan(db, types: ["HAS_STATION", "HAS_SIDE"], store: "plant")

      # ...then describe any selection of nodes with it, shortly and exactly
      {:ok, %Glider.Structure.Compact{text: text, hash: hash, fresh: true}} =
        Glider.Structure.compact(db, [242, 243, 244], "plant")

      {:ok, dictionary} = Glider.Structure.dictionary_text(db, "plant")

  ## What there is

    * Colours (`colors/2`): Weisfeiler-Lehman colours, equal exactly when
      the surroundings to a depth cannot be told apart by labels, chosen
      properties and typed, directed edges. Kept colourings: `store:`,
      `read/3`, `stored/2`, `drop/3`.
    * Classes (`classes/2`): interchangeable nodes, by neighbours (exact)
      or by colour.
    * Templates (`templates/2`, `expand/3`): shapes that repeat along a
      hierarchy, their instances, and each instance rebuilt from the
      definition.
    * Path patterns and chains (`paths/2`).
    * The plan (`plan/2`): which templates and chain patterns make a text
      shorter, measured by writing it both ways. Kept dictionaries:
      `store:`, `dictionaries/2`, `drop_dictionary/3`.
    * The compact notation `glider-compact/1` (`compact/4`,
      `dictionary_text/3`).

  Glider's `docs/EXTENSIONS.md`, "structure" and "Templates", says what
  each argument means; option names here are the engine's, as atoms, and
  values are passed as `$` parameters (atoms such as `:out`, `:stable`,
  `:require` as their names).

  ## Results

  Rows are maps keyed by the engine's column names (binaries from data,
  never atoms). Kept colourings and dictionaries are
  `Glider.Structure.Colouring` and `Glider.Structure.Dictionary`.

  ## Slices and streams

  `colors/2`, `classes/2`, `read/3`, `templates/2`, `paths/2` and `plan/2`
  answer a slice at a time (at most 9,999 rows and the engine's end row a
  call; `limit:` lowers it). Whether a slice ends the answer and where the
  next one starts are read from the end row, as for `Glider.Changes` and
  `Glider.Check`, by the same code: pass `after` back exactly as given with
  the same other options. `stream/3` does that lazily. A slice of a
  colouring computed in the call bounds what is returned, not the work; a
  kept colouring is read in true slices.

  ## Freshness

  A kept colouring or dictionary records the revision it was made at and
  says whether the database has changed since (with the `changes` journal
  installed, only a node or edge change counts). `fresh: :require` refuses
  a stale one with the distinct `{:error, %Glider.Structure.Stale{}}`,
  decided from the engine's own freshness flag in the same transaction as
  the call, never from a message.

  ## Budgets, transactions, telemetry

  Every function takes `:max_millis` and `:max_steps`, the statement
  budget, and passes it on; unknown options are errors that name them.
  A procedure obeys it from the engine version whose `structure`
  procedures count steps (glider's `docs/DERIVED.md`, "Budgets for
  procedures"); before it, the budget is accepted and the procedure runs to
  its end, so bound a whole-graph call with `labels:`, `types:` or a kept
  colouring or dictionary instead.
  A call that writes nothing (no `store:` or `write:`) writes nothing
  inside a caller's transaction either, and its refusal does not abort
  that transaction. Every statement is a `[:glider, :query, ...]`
  telemetry span with `:procedure` naming the engine procedure
  (`"structure.colors"`, ...).
  """

  alias Glider.Procedure
  alias Glider.Structure.{Colouring, Compact, Dictionary, Plan, Slice, Stale}

  @max_rows 10_000

  @colors [
    :depth,
    :max_depth,
    :types,
    :dir,
    :props,
    :labels,
    :identity,
    :store,
    :write,
    :summary,
    :after,
    :limit
  ]
  @classes [
    :by,
    :labels,
    :keys,
    :types,
    :dir,
    :colors,
    :identity,
    :min_size,
    :members,
    :summary,
    :fresh,
    :depth,
    :props,
    :after,
    :limit
  ]
  @read [:identity, :fresh, :after, :limit]
  @templates [
    :types,
    :dir,
    :labels,
    :min_nodes,
    :min_count,
    :max_nodes,
    :identity,
    :instances,
    :grouped,
    :dictionary,
    :fresh,
    :after,
    :limit
  ]
  @expand [
    :root,
    :dictionary,
    :fresh,
    :types,
    :dir,
    :labels,
    :min_nodes,
    :min_count,
    :max_nodes,
    :identity
  ]
  @paths [:kind, :types, :dir, :labels, :min_count, :max_hops, :after, :limit]
  @plan [
    :types,
    :dir,
    :labels,
    :nodes,
    :min_nodes,
    :min_count,
    :max_nodes,
    :identity,
    :by,
    :lambda,
    :store,
    :dictionary,
    :fresh,
    :text,
    :find,
    :after,
    :limit
  ]
  @compact [:fresh, :by, :find]

  @doc """
  Install the extension in this database (a no-op if it already is).
  Takes `:max_millis` and `:max_steps`.

      :ok = Glider.Structure.install(db)
  """
  @spec install(Glider.db(), keyword()) :: :ok | {:error, String.t()}
  def install(db, opts \\ []) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Structure.install/2") do
      Procedure.span(db, "structure.install", fn ->
        case Procedure.statement(
               db,
               "CREATE EXTENSION IF NOT EXISTS structure",
               [],
               nil,
               budget
             ) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end)
    end
  end

  # ------------------------------------------------------------ colours

  @doc """
  Colour every node (of `:labels`, when given), one slice of the answer.

  Options: `:depth` (a number, default 3, or `:stable`), `:max_depth`,
  `:types`, `:dir` (`:out`, `:in`, `:both`), `:props`, `:labels`,
  `:identity`, `:store` (keep it under a name), `:write` (set the colour as
  this property), `:summary` (one row per depth instead), `:after`,
  `:limit`, and the budget.

  Rows are `%{"id" => id, "color" => hex}` (and `"identity"`), in id order;
  with `summary: true`, `%{"depth" => d, "colors" => n, "selected" => m}`.

      {:ok, %Glider.Structure.Slice{rows: [%{"id" => 7, "color" => _} | _], complete: true}} =
        Glider.Structure.colors(db, depth: 2, labels: ["Station"])
  """
  @spec colors(Glider.db(), keyword()) :: {:ok, Slice.t()} | {:error, String.t()}
  def colors(db, opts \\ []) do
    with {:ok, args, budget} <- Procedure.split(opts, @colors, "Glider.Structure.colors/2"),
         :ok <- limit(args) do
      slice(db, "structure.colors", args, budget)
    end
  end

  @doc """
  Interchangeable nodes, largest class first, one slice of the answer.

  Options: `:by` (`:neighbours`, the default, or `:colors`), `:labels`,
  `:keys`, `:types`, `:dir`, `:colors` (a kept colouring's name, with
  `by: :colors`), `:fresh` (`:report` or `:require`, for a kept colouring),
  `:depth`, `:props` (for colours computed in the call), `:identity`,
  `:min_size`, `:members`, `:summary`, `:after`, `:limit`, and the budget.

  Rows are `%{"class" => n, "size" => s, "first" => id, "members" => [id]}`
  (and `"identities"`). The members are distinct nodes that the structure
  cannot tell apart, never one thing.

      {:ok, %Glider.Structure.Slice{rows: [%{"size" => 3, "members" => members}]}} =
        Glider.Structure.classes(db, by: :colors, colors: "designs")
  """
  @spec classes(Glider.db(), keyword()) ::
          {:ok, Slice.t()} | {:error, Stale.t() | String.t()}
  def classes(db, opts \\ []) do
    with {:ok, args, budget} <- Procedure.split(opts, @classes, "Glider.Structure.classes/2"),
         :ok <- limit(args) do
      case Keyword.get(args, :colors) do
        name when is_binary(name) ->
          guarded(db, :colouring, name, args, budget, fn _kept ->
            slice(db, "structure.classes", args, budget)
          end)

        _ ->
          slice(db, "structure.classes", args, budget)
      end
    end
  end

  @doc """
  Read a kept colouring back, one slice of it, with whether the database
  has moved since it was computed.

  Options: `:identity`, `:fresh` (`:report`, the default, or `:require`),
  `:after`, `:limit`, and the budget. The slice's `kept` is the
  colouring's `Glider.Structure.Colouring` (revision, `fresh`), read in the
  same transaction as the rows.

      {:ok, %Glider.Structure.Slice{rows: rows, kept: %Glider.Structure.Colouring{fresh: true}}} =
        Glider.Structure.read(db, "designs")
  """
  @spec read(Glider.db(), String.t(), keyword()) ::
          {:ok, Slice.t()} | {:error, Stale.t() | String.t()}
  def read(db, name, opts \\ []) when is_binary(name) do
    with {:ok, args, budget} <- Procedure.split(opts, @read, "Glider.Structure.read/3"),
         :ok <- limit(args) do
      guarded(db, :colouring, name, args, budget, fn kept ->
        with {:ok, s} <- slice(db, "structure.read", [name: name] ++ args, budget),
             do: {:ok, %{s | kept: kept}}
      end)
    end
  end

  @doc """
  The kept colourings, as `Glider.Structure.Colouring`s.

      {:ok, [%Glider.Structure.Colouring{name: "designs", fresh: true}]} =
        Glider.Structure.stored(db)
  """
  @spec stored(Glider.db(), keyword()) :: {:ok, [Colouring.t()]} | {:error, String.t()}
  def stored(db, opts \\ []) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Structure.stored/2"),
         {:ok, r} <- Procedure.call(db, "structure.stored", [], [probe: true] ++ budget) do
      {:ok, r.columns |> Procedure.maps(r.rows) |> Enum.map(&colouring/1)}
    end
  end

  @doc """
  Forget a kept colouring.

      :ok = Glider.Structure.drop(db, "designs")
  """
  @spec drop(Glider.db(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def drop(db, name, opts \\ []) when is_binary(name) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Structure.drop/3"),
         {:ok, _} <- Procedure.call(db, "structure.drop", [name: name], budget),
         do: :ok
  end

  # ------------------------------------------------------------ templates

  @doc """
  Shapes that repeat along a hierarchy, largest estimated saving first,
  one slice of the answer.

  Options: `:types`, `:dir` (`:out` or `:in`), `:labels`, `:min_nodes`,
  `:min_count`, `:max_nodes`, `:identity`, `:instances` (a template id, or
  `"*"`, to list instances instead), `:grouped`, `:dictionary` (a kept
  dictionary's templates instead), `:fresh`, `:after`, `:limit`, and the
  budget.

  Rows are `%{"rank", "template", "root", "nodes", "edges", "slots",
  "instances", "plain_tokens", "saving_bytes", "saving_tokens",
  "definition"}`; with `:instances`, `%{"template", "root", "handle",
  "slots"}`.

      {:ok, %Glider.Structure.Slice{rows: [%{"template" => id, "instances" => 3} | _]}} =
        Glider.Structure.templates(db, types: ["HAS"])
  """
  @spec templates(Glider.db(), keyword()) ::
          {:ok, Slice.t()} | {:error, Stale.t() | String.t()}
  def templates(db, opts \\ []) do
    with {:ok, args, budget} <-
           Procedure.split(opts, @templates, "Glider.Structure.templates/2"),
         :ok <- limit(args) do
      with_dictionary(db, args, budget, fn _ ->
        slice(db, "structure.templates", args, budget)
      end)
    end
  end

  @doc """
  Exactly the nodes, edges and values of a template's instances (`of:` a
  template id, `root:` an id or a list of at most 1,000), or of a chain's
  interior (`of: "chain:<id>"`), rebuilt from the definition after checking
  each root in full.

  Options: `:root`, `:dictionary` (use a kept dictionary's templates),
  `:fresh`, the arguments `templates/2` was asked with (`:types`, `:dir`,
  `:labels`, `:min_nodes`, `:min_count`, `:max_nodes`, `:identity`), and
  the budget.

  Rows are maps: `"kind"` (`"node"` or `"edge"`), `"id"`, `"labels"`,
  `"type"`, `"from"`, `"to"`, `"props"` (a map with binary keys) and
  `"root"`.

      {:ok, [%{"kind" => "node", "id" => 7, "props" => %{"code" => "S1"}} | _]} =
        Glider.Structure.expand(db, template, root: 7, types: ["HAS"])
  """
  @spec expand(Glider.db(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Stale.t() | String.t()}
  def expand(db, of, opts \\ []) when is_binary(of) do
    with {:ok, args, budget} <- Procedure.split(opts, @expand, "Glider.Structure.expand/3") do
      with_dictionary(db, args, budget, fn _ ->
        with {:ok, r} <-
               Procedure.call(
                 db,
                 "structure.expand",
                 [of: of] ++ args,
                 [max_rows: @max_rows, probe: true] ++ budget
               ) do
          {:ok, r.columns |> Procedure.maps(r.rows) |> Enum.map(&props_map/1)}
        end
      end)
    end
  end

  @doc """
  Label and edge-type sequences that many paths follow (`kind: :patterns`,
  the default), or runs of nodes with one way in and one way out
  (`kind: :chains`), one slice of the answer.

  Options: `:kind`, `:types`, `:dir`, `:labels`, `:min_count`, `:max_hops`,
  `:after`, `:limit`, and the budget. Pattern rows are `%{"rank",
  "pattern", "path", "hops", "paths", "ends", "maximal"}`; chain rows
  `%{"chain", "pattern", "path", "hops", "from", "to", "interior", "nodes"}`.

      {:ok, %Glider.Structure.Slice{rows: [%{"path" => "(:Station) -HAS-> (:Side)"}]}} =
        Glider.Structure.paths(db, types: ["HAS"])
  """
  @spec paths(Glider.db(), keyword()) :: {:ok, Slice.t()} | {:error, String.t()}
  def paths(db, opts \\ []) do
    with {:ok, args, budget} <- Procedure.split(opts, @paths, "Glider.Structure.paths/2"),
         :ok <- limit(args) do
      slice(db, "structure.paths", args, budget)
    end
  end

  # ------------------------------------------------------------ the plan

  @doc """
  Which templates and chain patterns make the text of the graph (or of
  `nodes:`) shorter, measured by writing it both ways; one slice of the
  candidates.

  Options: `:types`, `:dir`, `:labels`, `:nodes`, `:min_nodes`,
  `:min_count`, `:max_nodes`, `:identity`, `:by` (`:tokens` or `:bytes`),
  `:lambda`, `:store` (keep the chosen dictionary under a name),
  `:dictionary` (write with a kept one), `:fresh`, `:text` (`:compact`,
  `:plain` or `:dictionary`), `:find`, `:after`, `:limit`, and the budget.

  Returns a `Glider.Structure.Plan`. Without a kept dictionary and
  `nodes:`, this reads the whole graph.

      {:ok, %Glider.Structure.Plan{total: %{"chosen" => true, "id" => hash}}} =
        Glider.Structure.plan(db, types: ["HAS"], store: "plant")
  """
  @spec plan(Glider.db(), keyword()) :: {:ok, Plan.t()} | {:error, Stale.t() | String.t()}
  def plan(db, opts \\ []) do
    with {:ok, args, budget} <- Procedure.split(opts, @plan, "Glider.Structure.plan/2"),
         :ok <- limit(args),
         :ok <- ids(Keyword.get(args, :nodes)) do
      with_dictionary(db, args, budget, fn kept ->
        with {:ok, a} <- sliced(db, "structure.plan", args, budget) do
          rows = Procedure.maps(a.columns, a.rows)
          {total, candidates} = Enum.split_with(rows, &(&1["kind"] == "total"))

          {:ok,
           %Plan{
             total: List.first(total),
             candidates: candidates,
             complete: a.end.complete,
             after: if(a.end.complete, do: nil, else: a.end.next),
             kept: kept,
             message: a.message
           }}
        end
      end)
    end
  end

  @doc """
  The kept dictionaries, as `Glider.Structure.Dictionary`s.

      {:ok, [%Glider.Structure.Dictionary{name: "plant", hash: hash, fresh: true}]} =
        Glider.Structure.dictionaries(db)
  """
  @spec dictionaries(Glider.db(), keyword()) :: {:ok, [Dictionary.t()]} | {:error, String.t()}
  def dictionaries(db, opts \\ []) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Structure.dictionaries/2"),
         {:ok, r} <- Procedure.call(db, "structure.dictionaries", [], [probe: true] ++ budget) do
      {:ok, r.columns |> Procedure.maps(r.rows) |> Enum.map(&dictionary/1)}
    end
  end

  @doc """
  Forget a kept dictionary.

      :ok = Glider.Structure.drop_dictionary(db, "plant")
  """
  @spec drop_dictionary(Glider.db(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def drop_dictionary(db, name, opts \\ []) when is_binary(name) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Structure.drop_dictionary/3"),
         {:ok, _} <- Procedure.call(db, "structure.drop", [dictionary: name], budget),
         do: :ok
  end

  # ------------------------------------------------------------ the notation

  @doc """
  Write a selection of nodes (ids) in `glider-compact/1` with the kept
  dictionary `dictionary`, for a reader (a language model) that has the
  dictionary's text (`dictionary_text/3`) once.

  Returns a `Glider.Structure.Compact`: the text, the hash of the
  dictionary it was written with (the text's first line names it when a
  template or pattern is used), the dictionary's revision and whether the
  engine says it is fresh (read in the same transaction as the text), and
  the sizes of the text and of the same nodes written plainly.

  Options: `:fresh` (`:report`, the default, or `:require`, which refuses a
  stale dictionary with `{:error, %Glider.Structure.Stale{}}`), `:by`
  (`:tokens` or `:bytes`), `:find` (`:graph` finds the selection's
  instances over the whole graph instead, the same text, for checking), and
  the budget. It reads only the selection, the owners above it and the
  definitions it can use, and writes nothing.

  A stale dictionary costs uses, never truth: a node is written as part of
  a use only where it agrees with the graph now in everything the
  definition says; anything else is written plainly.

      {:ok, %Glider.Structure.Compact{text: "# glider-compact/1 dictionary " <> _, fresh: true}} =
        Glider.Structure.compact(db, station_ids, "plant")
  """
  @spec compact(Glider.db(), [non_neg_integer()], String.t(), keyword()) ::
          {:ok, Compact.t()} | {:error, Stale.t() | String.t()}
  def compact(db, nodes, dictionary, opts \\ []) when is_list(nodes) and is_binary(dictionary) do
    with {:ok, args, budget} <- Procedure.split(opts, @compact, "Glider.Structure.compact/4"),
         :ok <- ids(nodes) do
      args = [dictionary: dictionary, nodes: nodes, text: "compact", limit: 1] ++ args

      guarded(db, :dictionary, dictionary, args, budget, fn kept ->
        with {:ok, total} <- total(db, args, budget) do
          {:ok,
           %Compact{
             text: total["text"],
             hash: total["id"],
             dictionary: dictionary,
             revision: kept.revision,
             fresh: kept.fresh,
             bytes: total["use_bytes"],
             tokens: total["use_tokens"],
             plain_bytes: total["plain_bytes"],
             plain_tokens: total["plain_tokens"],
             saving_bytes: total["saving_bytes"],
             saving_tokens: total["saving_tokens"]
           }}
        end
      end)
    end
  end

  @doc """
  A kept dictionary's own text in `glider-compact/1` (its legend,
  definitions and patterns), to give a reader once beside the texts
  `compact/4` writes with it. Reads the kept dictionary only.

  Options: `:fresh` and the budget.

      {:ok, "# .k: a template's k-th node" <> _} = Glider.Structure.dictionary_text(db, "plant")
  """
  @spec dictionary_text(Glider.db(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Stale.t() | String.t()}
  def dictionary_text(db, dictionary, opts \\ []) when is_binary(dictionary) do
    with {:ok, args, budget} <-
           Procedure.split(opts, [:fresh], "Glider.Structure.dictionary_text/3") do
      args = [dictionary: dictionary, nodes: [], text: "dictionary", limit: 1] ++ args

      guarded(db, :dictionary, dictionary, args, budget, fn _kept ->
        with {:ok, total} <- total(db, args, budget), do: {:ok, total["text"]}
      end)
    end
  end

  # ------------------------------------------------------------ streams

  @doc """
  An answer in slices as a lazy stream of its rows (maps), fetched a slice
  at a time only as the stream is consumed, following the end row's cursor
  as given and stopping on the slice that says it is complete. The handle
  is free between slices.

  `procedure` is `:colors`, `:classes`, `:templates`, `:paths`, or
  `{:read, name}` for a kept colouring; `opts` are that function's,
  except `:after`. Raises `Glider.Structure.Stale` for a stale kept
  record asked for with `fresh: :require`, and `Glider.Error` on any other
  failure, from whichever slice meets it.

      db
      |> Glider.Structure.stream({:read, "designs"}, limit: 5_000)
      |> Enum.group_by(& &1["color"], & &1["id"])
  """
  @spec stream(Glider.db(), atom() | {:read, String.t()}, keyword()) :: Enumerable.t()
  def stream(db, procedure, opts \\ []) do
    if Keyword.has_key?(opts, :after) do
      raise ArgumentError, "Glider.Structure.stream/3 takes no :after; it pages itself"
    end

    fetch =
      case procedure do
        :colors -> &colors(db, &1)
        :classes -> &classes(db, &1)
        :templates -> &templates(db, &1)
        :paths -> &paths(db, &1)
        {:read, name} when is_binary(name) -> &read(db, name, &1)
        other -> raise ArgumentError, "Glider.Structure.stream/3 cannot stream #{inspect(other)}"
      end

    Procedure.stream(
      fn cursor ->
        with {:ok, %Slice{} = s} <- fetch.(Keyword.put(opts, :after, cursor)),
             do: {:ok, s.rows, %{answered: true, complete: s.complete, next: s.after}}
      end,
      fn e -> raise Glider.Error, message: "structure did not answer: #{inspect(e)}" end,
      fn
        %Stale{} = e -> raise e
        reason -> raise Glider.Error, message: reason
      end
    )
  end

  # ------------------------------------------------------------ private

  defp slice(db, procedure, args, budget) do
    with {:ok, a} <- sliced(db, procedure, args, budget) do
      {:ok,
       %Slice{
         rows: Procedure.maps(a.columns, a.rows),
         complete: a.end.complete,
         after: if(a.end.complete, do: nil, else: a.end.next),
         message: a.message
       }}
    end
  end

  # A call that keeps or writes nothing is a probe: inside a caller's
  # transaction its refusal does not abort the transaction.
  defp sliced(db, procedure, args, budget) do
    writes? = Keyword.get(args, :store) != nil or Keyword.get(args, :write) != nil
    opts = [max_rows: @max_rows, probe: not writes?] ++ budget

    case Procedure.sliced(db, procedure, args, opts) do
      {:ok, %{end: %{answered: false} = e}} ->
        {:error, "#{procedure} did not answer (#{e.reason})"}

      other ->
        other
    end
  end

  defp total(db, args, budget) do
    with {:ok, a} <- sliced(db, "structure.plan", args, budget) do
      case Enum.find(Procedure.maps(a.columns, a.rows), &(&1["kind"] == "total")) do
        nil -> {:error, "structure.plan gave no total row"}
        total -> {:ok, total}
      end
    end
  end

  defp with_dictionary(db, args, budget, fun) do
    case Keyword.get(args, :dictionary) do
      name when is_binary(name) -> guarded(db, :dictionary, name, args, budget, fun)
      _ -> fun.(nil)
    end
  end

  # Read the kept record's metadata and run `fun` in one transaction, so
  # what it says of freshness is what held for the call; refuse a stale one
  # asked for with fresh: :require as the distinct Stale error, decided
  # from the engine's freshness flag. A name that is not kept is left to
  # the engine to refuse.
  defp guarded(db, kind, name, args, budget, fun) do
    Procedure.together(db, fn ->
      with {:ok, kept} <- kept(db, kind, name, budget) do
        if kept && kept.fresh == false && require?(Keyword.get(args, :fresh)) do
          {:error, %Stale{kind: kind, name: name, revision: kept.revision}}
        else
          fun.(kept)
        end
      end
    end)
  end

  defp kept(db, :colouring, name, budget) do
    with {:ok, all} <- stored(db, budget), do: {:ok, Enum.find(all, &(&1.name == name))}
  end

  defp kept(db, :dictionary, name, budget) do
    with {:ok, all} <- dictionaries(db, budget), do: {:ok, Enum.find(all, &(&1.name == name))}
  end

  defp require?(fresh), do: fresh in [:require, "require"]

  defp limit(args), do: Procedure.positive(Keyword.get(args, :limit), "limit:")

  defp ids(nil), do: :ok

  defp ids(list) when is_list(list) do
    if Enum.all?(list, &(is_integer(&1) and &1 >= 0)),
      do: :ok,
      else: {:error, "nodes: must be a list of node ids, got: #{inspect(list)}"}
  end

  defp ids(other), do: {:error, "nodes: must be a list of node ids, got: #{inspect(other)}"}

  defp props_map(%{"props" => props} = row) when is_list(props),
    do: %{row | "props" => Map.new(props, fn [k, v] -> {k, v} end)}

  defp props_map(row), do: row

  defp colouring(m) do
    %Colouring{
      name: m["name"],
      revision: m["revision"],
      fresh: m["fresh"],
      depth: m["depth"],
      stable: m["stable"],
      nodes: m["nodes"],
      colors: m["colors"],
      code: m["code"],
      args: args_json(m["args"])
    }
  end

  defp dictionary(m) do
    %Dictionary{
      name: m["name"],
      revision: m["revision"],
      fresh: m["fresh"],
      hash: m["hash"],
      templates: m["templates"],
      patterns: m["patterns"],
      bytes: m["bytes"],
      tokens: m["tokens"],
      code: m["code"],
      args: args_json(m["args"]),
      stored_bytes: m["stored_bytes"]
    }
  end

  defp args_json(nil), do: nil

  defp args_json(text) when is_binary(text) do
    :json.decode(text)
  rescue
    _ -> text
  end
end
