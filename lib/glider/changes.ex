defmodule Glider.Changes do
  @moduledoc """
  The engine's `changes` extension: which nodes and edges changed since a
  revision.

  Things derived from a graph and kept outside it (embeddings that cost
  money to compute, summaries, compiled text for a language model) need to
  know what to recompute after the graph changes. `Glider.revision/2` says
  whether anything did; the change journal says exactly which nodes and
  edges did, by any path (statements, transactions, imports), and nothing
  that was rolled back.

      {:ok, db} = Glider.open("kg.gldb")
      :ok = Glider.Changes.install(db)

      # when deriving: keep the revision beside what you derived
      {:ok, rev} = Glider.revision(db)

      # later: what changed since then
      case Glider.Changes.since(db, rev) do
        {:ok, %Glider.Changes.Slice{changes: changes, after: nil, complete_up_to: now}} ->
          recompute(changes)
          keep(now)

        {:ok, %Glider.Changes.Slice{after: cursor}} ->
          # more than one slice: call again with after: cursor,
          # or use stream/3, which does that for you

        {:error, %Glider.Changes.Unanswerable{oldest: oldest}} ->
          # the journal cannot say: rebuild from a scan of the graph,
          # then carry on from `oldest` or later
          rebuild_everything()
      end

  Each change (`Glider.Changes.Change`) says what it is about (`:node`, `:edge`,
  or `:adjacency`, the edges at a node), what happened to it last (`:put`: it
  exists, with what the graph holds now; `:drop`: it is gone) and at what
  revision. Old values are not kept: the graph has the current ones.

  ## When it cannot answer

  The journal is bounded: its cap forgets the oldest entries, `release/3`
  forgets entries at or below a revision, and it knows nothing from before
  it was installed or before a `CLEAR`. Asked about a revision it cannot
  answer for, `since/3` returns `{:error, %Glider.Changes.Unanswerable{}}`
  carrying the oldest revision it does answer for, and `stream/3` raises the
  same struct when it is first run. Neither ever gives an empty list for it:
  an empty list of changes always means nothing changed.

  ## Budgets

  Every function takes `:max_millis` and `:max_steps`, the statement budget
  of `Glider.query/4`, and passes them to the engine. A procedure obeys them
  from the engine version whose procedures count steps (glider's
  `docs/DERIVED.md`, "Budgets for procedures"); before it, they are accepted
  and the procedure runs to its end.

  Every call is a `[:glider, :query, ...]` telemetry span with `:procedure`
  naming the engine procedure (`"changes.since"`, ...).
  """

  alias Glider.Changes.{Change, InTransaction, Slice, Status, Unanswerable}
  alias Glider.Procedure

  @max_rows 10_000

  @doc """
  Install the change journal in this database (a no-op if it already is).

  With `cap: n`, the journal holds at most `n` entries (at least 64; the
  engine's default is 1,000,000), set in the same transaction as the
  install, so the cap holds from the first write. A journal knows nothing
  from before it was installed.

      :ok = Glider.Changes.install(db, cap: 100_000)
  """
  @spec install(Glider.db(), keyword()) :: :ok | {:error, String.t()}
  def install(db, opts \\ []) do
    with {:ok, args, budget} <- Procedure.split(opts, [:cap], "Glider.Changes.install/2"),
         :ok <- cap_value(Keyword.get(args, :cap)) do
      Procedure.span(db, "changes.install", fn ->
        do_install(db, Keyword.get(args, :cap), budget)
      end)
    end
  end

  defp cap_value(nil), do: :ok
  defp cap_value(n) when is_integer(n) and n >= 64, do: :ok
  defp cap_value(n), do: {:error, "cap: must be a whole number at least 64, got: #{inspect(n)}"}

  defp do_install(db, nil, budget), do: create(db, budget)

  # The install and the cap in one transaction. Inside the caller's own,
  # both join it, and a refusal is returned, not thrown through the caller.
  defp do_install(db, cap, budget) do
    steps = fn ->
      with :ok <- create(db, budget), {:ok, _} <- cap(db, cap, budget), do: :ok
    end

    if Glider.in_transaction?(db) do
      steps.()
    else
      case Glider.transaction(db, fn ->
             case steps.() do
               :ok -> :ok
               {:error, reason} -> Glider.rollback(db, reason)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create(db, budget) do
    case Procedure.statement(db, "CREATE EXTENSION IF NOT EXISTS changes", [], nil, budget) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  The changes after `revision`, one slice of them.

  Options:

    * `:kinds` - only these kinds: a list of `:node`, `:edge`, `:adjacency`.
    * `:limit` - the most changes in this slice (at most and by default
      10,000).
    * `:after` - carry on after this position: the `after` of the previous
      slice, with the same `revision` and `:kinds`.
    * `:max_millis`, `:max_steps` - the statement budget.

  Changes come by kind (node, edge, adjacency), then id, each id once per
  kind with its latest change. A slice with `after: nil` is the last, and
  its `complete_up_to` is the committed revision it is complete up to,
  never more than `Glider.revision/2` says (the binding checks it); keep
  it and ask from it next time. Otherwise call again with
  `after: slice.after`.

  Refused inside a transaction, with
  `{:error, %Glider.Changes.InTransaction{}}`, before anything reaches the
  engine and without touching the transaction: there the journal would
  list the transaction's own pending writes and a position that may never
  be committed. Another process's call waits for an open transaction to
  end, as every call does, and then answers about what was committed.

      {:ok, %Glider.Changes.Slice{changes: [%Glider.Changes.Change{kind: :node, id: 7, change: :put}]}} =
        Glider.Changes.since(db, rev)

  Read `revision` at commit boundaries (outside a transaction): the
  revision a journal entry carries lies between the revision before its
  transaction and the one it committed at.

  When the journal cannot answer for `revision`, the result is
  `{:error, %Glider.Changes.Unanswerable{}}` (see the moduledoc); any other
  failure (the journal not installed, a bad argument) is
  `{:error, reason}` with a string. Options are checked before anything
  is sent.
  """
  @spec since(Glider.db(), non_neg_integer(), keyword()) ::
          {:ok, Slice.t()} | {:error, Unanswerable.t() | InTransaction.t() | String.t()}
  def since(db, revision, opts \\ []) when is_integer(revision) and revision >= 0 do
    with {:ok, args, budget} <-
           Procedure.split(opts, [:kinds, :limit, :after], "Glider.Changes.since/3"),
         :ok <- Procedure.positive(Keyword.get(args, :limit), "limit:"),
         :ok <- outside_transaction(db) do
      args = [revision: revision] ++ args
      max_rows = min(Keyword.get(args, :limit) || @max_rows, @max_rows)

      case Procedure.call(db, "changes.since", args, [max_rows: max_rows] ++ budget) do
        {:ok, r} -> committed(db, slice(r), budget)
        {:error, reason} -> {:error, unanswerable(db, revision, reason, budget)}
      end
    end
  end

  defp outside_transaction(db) do
    if Glider.in_transaction?(db), do: {:error, %InTransaction{}}, else: :ok
  end

  # A watermark handed to a caller is a committed revision: checked against
  # the revision, which only grows, read after the answer.
  defp committed(_db, %Slice{complete_up_to: nil} = slice, _budget), do: {:ok, slice}

  defp committed(db, %Slice{complete_up_to: up_to} = slice, budget) do
    case Glider.revision(db, budget) do
      {:ok, rev} when up_to <= rev ->
        {:ok, slice}

      {:ok, rev} ->
        {:error,
         "changes.since said it was complete up to #{up_to}, past the committed revision #{rev}; " <>
           "nothing is returned, since that position may never be committed"}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The changes after `revision` as a stream of `Glider.Changes.Change`,
  fetched a slice at a time (`:limit` changes a slice, default 10,000) only
  as the stream is consumed. The handle is free between slices, so writes
  can land in between; a change written meanwhile is listed if its position
  comes after the stream's (its kind and id), and is always listed by the
  next `since/3` from the revision read before the stream started.

  Takes the options of `since/3` except `:after`. Raises
  `Glider.Changes.Unanswerable` when the journal cannot answer for
  `revision`, from the first slice on (so on the first `Enum` call, never
  as an empty stream), `Glider.Changes.InTransaction` when consumed inside
  a transaction, and `Glider.Error` on any other failure.

      db
      |> Glider.Changes.stream(rev, kinds: [:node])
      |> Stream.filter(&(&1.change == :put))
      |> Stream.map(& &1.id)
      |> Enum.chunk_every(100)
      |> Enum.each(&reembed(db, &1))
  """
  @spec stream(Glider.db(), non_neg_integer(), keyword()) :: Enumerable.t()
  def stream(db, revision, opts \\ []) when is_integer(revision) and revision >= 0 do
    if Keyword.has_key?(opts, :after) do
      raise ArgumentError, "Glider.Changes.stream/3 takes no :after; it pages itself"
    end

    Stream.resource(
      fn -> {:next, nil} end,
      fn
        :done ->
          {:halt, :done}

        {:next, cursor} ->
          case since(db, revision, Keyword.put(opts, :after, cursor)) do
            {:ok, %Slice{changes: changes, after: nil}} -> {changes, :done}
            {:ok, %Slice{changes: changes, after: next}} -> {changes, {:next, next}}
            {:error, %Unanswerable{} = e} -> raise e
            {:error, %InTransaction{} = e} -> raise e
            {:error, reason} -> raise Glider.Error, message: reason, query: "changes.since"
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  The journal's state: the oldest revision it answers for and why, how many
  entries it holds and their bytes, its cap, and the database's revision.

      {:ok, %Glider.Changes.Status{oldest: 1042, why: :installed, entries: 0, cap: 1_000_000}} =
        Glider.Changes.status(db)

  The engine counts the entries by reading the journal (not the graph):
  a few milliseconds for a few hundred thousand entries.
  """
  @spec status(Glider.db(), keyword()) :: {:ok, Status.t()} | {:error, String.t()}
  def status(db, opts \\ []) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Changes.status/2"),
         {:ok, r} <- Procedure.call(db, "changes.status", [], [probe: true] ++ budget) do
      [[oldest, why, entries, bytes, cap, revision]] = r.rows

      {:ok,
       %Status{
         oldest: oldest,
         why: why(why),
         entries: entries,
         bytes: bytes,
         cap: cap,
         revision: revision
       }}
    end
  end

  @doc """
  Forget the changes at or below `below`, raising the oldest revision the
  journal answers for to it. With `limit: n`, forget at most `n` entries in
  this call; `more: true` says to call again.

      {:ok, %{released: 1200, more: false}} = Glider.Changes.release(db, rev)
  """
  @spec release(Glider.db(), non_neg_integer(), keyword()) ::
          {:ok, %{released: non_neg_integer(), more: boolean()}} | {:error, String.t()}
  def release(db, below, opts \\ []) when is_integer(below) and below >= 0 do
    with {:ok, args, budget} <- Procedure.split(opts, [:limit], "Glider.Changes.release/3"),
         {:ok, r} <- Procedure.call(db, "changes.release", [below: below] ++ args, budget) do
      {:ok, %{released: r.touched, more: String.contains?(r.message || "", "more:")}}
    end
  end

  @doc """
  Bound the journal to `entries` entries (at least 64). Lowering the cap
  forgets the oldest entries at once and raises the oldest revision it
  answers for; returns how many were forgotten.

      {:ok, 0} = Glider.Changes.cap(db, 100_000)
  """
  @spec cap(Glider.db(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def cap(db, entries, opts \\ []) when is_integer(entries) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Changes.cap/3"),
         {:ok, r} <- Procedure.call(db, "changes.cap", [entries: entries], budget) do
      {:ok, max(r.touched - 1, 0)}
    end
  end

  # ------------------------------------------------------------------ private

  defp slice(r) do
    changes =
      Enum.map(r.rows, fn [revision, kind, id, change] ->
        %Change{revision: revision, kind: kind(kind), id: id, change: change(change)}
      end)

    message = r.message || ""

    case Regex.run(~r/after: '([^']+)'/, message) do
      [_, cursor] ->
        %Slice{changes: changes, after: cursor, complete_up_to: nil}

      nil ->
        complete =
          case Regex.run(~r/complete up to revision (\d+)/, message) do
            [_, n] -> String.to_integer(n)
            nil -> nil
          end

        %Slice{changes: changes, after: nil, complete_up_to: complete}
    end
  end

  # The engine's refusals all begin this way; anything else (not installed,
  # a bad argument) stays a string.
  defp unanswerable(db, revision, "the change journal cannot answer" <> _ = message, budget) do
    reason =
      cond do
        message =~ "past this database's" -> :restarting
        message =~ ~r/: this database is at \d+/ -> :ahead
        true -> :below_oldest
      end

    {oldest, why} =
      case reason do
        :restarting ->
          {nil, nil}

        _ ->
          case status(db, budget) do
            {:ok, s} -> {s.oldest, s.why}
            {:error, _} -> {floor_in(message), nil}
          end
      end

    %Unanswerable{revision: revision, oldest: oldest, reason: reason, why: why, message: message}
  end

  defp unanswerable(_db, _revision, reason, _budget), do: reason

  defp floor_in(message) do
    case Regex.run(~r/it answers for revision (\d+) and later/, message) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  # Fixed vocabularies of the engine: mapped by table, never String.to_atom.
  defp kind("node"), do: :node
  defp kind("edge"), do: :edge
  defp kind("adjacency"), do: :adjacency

  defp change("put"), do: :put
  defp change("drop"), do: :drop

  defp why("installed"), do: :installed
  defp why("released"), do: :released
  defp why("cap"), do: :cap
  defp why("cleared"), do: :cleared
  defp why("reset"), do: :reset
  defp why(other), do: other
end
