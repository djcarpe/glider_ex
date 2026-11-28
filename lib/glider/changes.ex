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
        {:ok, %Glider.Changes.Slice{complete: true, changes: changes, complete_up_to: now}} ->
          recompute(changes)
          keep(now)

        {:ok, %Glider.Changes.Slice{complete: false, after: cursor}} ->
          # more than one slice: call again with after: cursor (as given),
          # or use stream/3, which does that for you

        {:error, %Glider.Changes.Unanswerable{reason: reason, oldest: oldest}} ->
          # the journal cannot say: rebuild from a scan of the graph,
          # then carry on from `oldest` or later
          rebuild_everything()
      end

  Each change (`Glider.Changes.Change`) says what it is about (`:node`, `:edge`,
  or `:adjacency`, the edges at a node), what happened to it last (`:put`: it
  exists, with what the graph holds now; `:drop`: it is gone) and at what
  revision. Old values are not kept: the graph has the current ones.

  ## Answers in slices, read as data

  `since/3` reads everything about a slice from the row the engine ends
  every such answer with (glider's `docs/EXTENSIONS.md`, "Answers in
  slices"): whether it could answer, whether the slice is the last, the one
  cursor to continue from, the watermark the answer is complete up to and
  the oldest revision the journal answers for. Nothing is read from the
  engine's message. A cursor is opaque: pass it back as given.

  ## When it cannot answer

  The journal is bounded: its cap forgets the oldest entries, `release/3`
  forgets entries at or below a revision, and it knows nothing from before
  it was installed or before a `CLEAR`. Asked about a revision it cannot
  answer for, `since/3` returns `{:error, %Glider.Changes.Unanswerable{}}`
  with the engine's reason and, where there is one, the oldest revision it
  does answer for; `stream/3` raises the same struct from whichever slice
  meets it. Neither ever gives an empty list for it: an empty list of
  changes always means nothing changed.

  ## Inside a transaction

  `since/3` and `stream/3` answer about committed changes only: the
  transaction's pending writes are not listed, the watermark is the
  committed revision, and a question that cannot be answered does not
  abort the transaction (see `since/3`).

  ## Budgets

  Every function takes `:max_millis` and `:max_steps`, the statement budget
  of `Glider.query/4`, and passes them to the engine. A procedure obeys them
  from the engine version whose procedures count steps (glider's
  `docs/DERIVED.md`, "Budgets for procedures"); before it, they are accepted
  and the procedure runs to its end.

  Every call is a `[:glider, :query, ...]` telemetry span with `:procedure`
  naming the engine procedure (`"changes.since"`, ...).
  """

  alias Glider.Changes.{Change, Slice, Status, Unanswerable}
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
      9,999).
    * `:after` - carry on from the `after` of the previous slice, passed
      back exactly as given, with the same `revision` and `:kinds`.
    * `:max_millis`, `:max_steps` - the statement budget.

  Changes come by kind (node, edge, adjacency), then id, each id once per
  kind with its latest change. Everything about the slice is read from the
  engine's end row: `complete` says whether it ends the answer, `after` is
  the cursor for the next one (an opaque value, never read or built here),
  and `complete_up_to` is the committed revision the whole answer is
  complete up to. Keep the last slice's `complete_up_to` and ask from it
  next time.

      {:ok, %Glider.Changes.Slice{complete: true, changes: [%Glider.Changes.Change{kind: :node, id: 7, change: :put}]}} =
        Glider.Changes.since(db, rev)

  ## Inside a transaction

  It may be called inside a transaction, and answers there about committed
  changes only, as if the transaction were not open: the transaction's own
  pending writes are not listed, `complete_up_to` is the committed
  revision (never a position the transaction may roll back), and a
  revision past the committed one is `:ahead`. What the transaction writes
  is listed by the next question from that watermark once it commits, and
  never if it rolls back. Nothing it does writes, and neither a question
  it cannot answer nor a refused argument aborts the caller's transaction.

  Read `revision` at commit boundaries: the revision a journal entry
  carries lies between the revision before its transaction and the one it
  committed at.

  When the journal cannot answer for `revision` (or, continuing, for the
  cursor), the result is `{:error, %Glider.Changes.Unanswerable{}}` with
  the engine's reason and the oldest revision it answers for. Any other
  failure (the extension not installed, a bad argument, a cursor from
  another question or database) is `{:error, reason}` with a string.
  Options are checked before anything is sent.
  """
  @spec since(Glider.db(), non_neg_integer(), keyword()) ::
          {:ok, Slice.t()} | {:error, Unanswerable.t() | String.t()}
  def since(db, revision, opts \\ []) when is_integer(revision) and revision >= 0 do
    with {:ok, args, budget} <-
           Procedure.split(opts, [:kinds, :limit, :after], "Glider.Changes.since/3"),
         :ok <- Procedure.positive(Keyword.get(args, :limit), "limit:"),
         {:ok, a} <-
           Procedure.sliced(
             db,
             "changes.since",
             [revision: revision] ++ args,
             [max_rows: @max_rows, probe: true] ++ budget
           ) do
      answer(a, revision)
    end
  end

  defp answer(%{end: %{answered: false} = e, message: message}, revision) do
    {:error,
     %Unanswerable{revision: revision, reason: e.reason, oldest: e.oldest, message: message}}
  end

  defp answer(%{rows: rows, end: e}, _revision) do
    changes =
      Enum.map(rows, fn [rev, kind, id, change] ->
        %Change{revision: rev, kind: kind(kind), id: id, change: change(change)}
      end)

    {:ok,
     %Slice{
       changes: changes,
       complete: e.complete,
       after: if(e.complete, do: nil, else: e.next),
       complete_up_to: e.watermark
     }}
  end

  @doc """
  The changes after `revision` as a stream of `Glider.Changes.Change`,
  fetched a slice at a time (`:limit` changes a slice) only as the stream
  is consumed. Each slice continues from the cursor the previous one's end
  row gave, passed back as given, and the stream ends on the slice that
  says it is complete. The handle is free between slices.

  The cursor carries the first slice's watermark, so a change committed
  between two slices to an id already passed is not lost: it is listed by
  the next `since/3` from the watermark (`since/3` with `limit:` gives you
  the last slice's `complete_up_to`; with the stream, read
  `Glider.revision/2` before it starts and ask from that).

  Takes the options of `since/3` except `:after`. Raises
  `Glider.Changes.Unanswerable` when the journal cannot answer, whether on
  the first slice or on a later one (a `release/3` or the cap between two
  slices), never ending as if the answer were complete; and
  `Glider.Error` on any other failure. Inside a transaction it answers as
  `since/3` does.

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

    with {:error, reason} <-
           Procedure.split(opts, [:kinds, :limit], "Glider.Changes.stream/3"),
         do: raise(ArgumentError, reason)

    Procedure.stream(
      fn cursor ->
        with {:ok, args, budget} <-
               Procedure.split(Keyword.put(opts, :after, cursor), [:kinds, :limit, :after], ""),
             :ok <- Procedure.positive(Keyword.get(args, :limit), "limit:"),
             {:ok, a} <-
               Procedure.sliced(
                 db,
                 "changes.since",
                 [revision: revision] ++ args,
                 [max_rows: @max_rows, probe: true] ++ budget
               ) do
          case answer(a, revision) do
            {:ok, slice} -> {:ok, slice.changes, a.end}
            {:error, _} -> {:ok, [], a.end |> Map.put(:message, a.message)}
          end
        end
      end,
      fn e ->
        raise Unanswerable,
          revision: revision,
          reason: e.reason,
          oldest: e.oldest,
          message: Map.get(e, :message)
      end,
      fn reason -> raise Glider.Error, message: reason, query: "changes.since" end
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
  this call; `more: true` says it stopped at that limit, so call again
  (the next call may find nothing left to forget).

      {:ok, %{released: 1200, more: false}} = Glider.Changes.release(db, rev)
  """
  @spec release(Glider.db(), non_neg_integer(), keyword()) ::
          {:ok, %{released: non_neg_integer(), more: boolean()}} | {:error, String.t()}
  def release(db, below, opts \\ []) when is_integer(below) and below >= 0 do
    with {:ok, args, budget} <- Procedure.split(opts, [:limit], "Glider.Changes.release/3"),
         {:ok, r} <- Procedure.call(db, "changes.release", [below: below] ++ args, budget) do
      limit = Keyword.get(args, :limit)
      {:ok, %{released: r.touched, more: is_integer(limit) and r.touched >= limit}}
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
