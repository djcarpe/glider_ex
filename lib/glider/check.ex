defmodule Glider.Check do
  @moduledoc """
  The engine's `check` extension: is the graph whole.

  `glider <db> verify` proves that pages and trees are sound; `check` proves
  that the graph those trees hold agrees with itself (every edge's endpoints
  exist, adjacency, label and type membership, counters and indexes agree
  with the records) and that what installed extensions derived from it
  still matches it. It reports and never repairs: nothing is written, and
  the revision is the same afterwards.

      :ok = Glider.Check.install(db)

      {:ok, %Glider.Check.Report{findings: [], after: nil}} = Glider.Check.run(db)

      {:ok, report} = Glider.Check.run(db, checks: [:orphans], labels: ["Tool"])
      for %Glider.Check.Finding{id: id, detail: detail} <- report.findings, do: IO.puts("\#{id}: \#{detail}")

  ## Checks

  | check | finds | severity |
  |---|---|---|
  | `:endpoints` | an edge whose source or target node does not exist | `:fault` |
  | `:adjacency` | an edge missing from an endpoint's adjacency, or an adjacency entry that is not its edge's | `:fault` |
  | `:membership` | a node or edge not listed under its label or type, or a listing without its record | `:fault` |
  | `:counters` | a count that differs from a scan; an id counter that would hand out an id in use | `:fault` |
  | `:indexes` | an index entry that does not match its node, a covered node missing from an index | `:fault` |
  | `:derived` | each installed extension's own check of what it derived | `:fault` |
  | `:duplicates` | parallel edges with the same endpoints, type and properties; with `label:` and `keys:`, nodes of the label equal on every key | `:candidate` |
  | `:orphans` | nodes with no edges, of `labels:` when given | `:candidate` |
  | `:required` | nodes of `label:` with no edge of `type:` in `dir:` | `:candidate` |

  With no `:checks` the first six run; the last three only when named,
  since what they find are facts about the data an application may or may
  not call faults. An installed extension that cannot be checked gives one
  `:info` finding.

  ## Slices

  `:limit` caps the records one call looks at, and a call also stops at
  9,990 findings. Whether a report ends the run and where the next slice
  starts are read from the engine's end row, never its message: a call
  that stops returns a report with `complete: false` and `after:` set to
  the end row's cursor, which is opaque; pass it back exactly as given as
  `after:` with the same other options to carry on (with other options the
  engine refuses it), or use
  `stream/2`, which does that and frees the handle between slices. Slices
  together report exactly what one whole run reports. A cursor is a
  position, not a snapshot: writes between slices give an answer about a
  mix of states.

  ## Budgets

  `:max_millis` and `:max_steps` are the statement budget of
  `Glider.query/4`, passed to the engine. `check.run` obeys them from the
  engine version whose procedures count steps (glider's `docs/DERIVED.md`,
  "Budgets for procedures"); before it, `:limit` is what bounds a call.

  Every call is a `[:glider, :query, ...]` telemetry span with `:procedure`
  `"check.run"`.
  """

  alias Glider.Check.{Finding, Report, Summary}
  alias Glider.Procedure

  @args [:checks, :labels, :label, :keys, :type, :dir, :limit, :after]

  # 10,000 findings a call, and the summary rows of the checks it ran.
  @max_rows 10_016

  @doc """
  Install the extension in this database (a no-op if it already is).
  Takes `:max_millis` and `:max_steps`.

      :ok = Glider.Check.install(db)
  """
  @spec install(Glider.db(), keyword()) :: :ok | {:error, String.t()}
  def install(db, opts \\ []) do
    with {:ok, [], budget} <- Procedure.split(opts, [], "Glider.Check.install/2") do
      Procedure.span(db, "check.install", fn ->
        case Procedure.statement(db, "CREATE EXTENSION IF NOT EXISTS check", [], nil, budget) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc """
  Run the checks, or one slice of them.

  Options:

    * `:checks` - which checks, as atoms or strings (see the moduledoc);
      default the six checks of the database.
    * `:labels` - for `:orphans`, only nodes of these labels.
    * `:label`, `:keys` - for `:duplicates`, compare the nodes of `label`
      on every key in `keys`; for `:required`, the nodes of `label`.
    * `:type`, `:dir` - for `:required`, the edge type each node of `label`
      must have, and its direction (`:out`, the default, `:in`, `:both`).
    * `:limit` - the most records this call looks at.
    * `:after` - carry on from the `after` of the previous report, as given.
    * `:max_millis`, `:max_steps` - the statement budget.

  Returns a `Glider.Check.Report`: the findings in the order the checks met
  them, one `Glider.Check.Summary` per check this call ran or stopped in,
  `complete`, and `after`, `nil` when the run is complete. It writes
  nothing, and inside a transaction a refusal (a bad argument) does not
  abort the transaction.

      {:ok, %Glider.Check.Report{findings: [%Glider.Check.Finding{severity: :fault, id: "e2"}]}} =
        Glider.Check.run(db)
  """
  @spec run(Glider.db(), keyword()) :: {:ok, Report.t()} | {:error, String.t()}
  def run(db, opts \\ []) do
    with {:ok, args, budget} <- Procedure.split(opts, @args, "Glider.Check.run/2"),
         :ok <- Procedure.positive(Keyword.get(args, :limit), "limit:"),
         {:ok, a} <-
           Procedure.sliced(db, "check.run", args, [max_rows: @max_rows, probe: true] ++ budget) do
      report(a)
    end
  end

  @doc """
  The checks as a stream of `Glider.Check.Report`s, one a slice of
  `:limit` records (default 10,000), fetched only as the stream is consumed.
  The handle is free between slices. Takes the options of `run/2` except
  `:after`; raises `Glider.Error` if a slice fails.

      faults =
        db
        |> Glider.Check.stream(limit: 50_000)
        |> Stream.flat_map(& &1.findings)
        |> Enum.filter(&(&1.severity == :fault))
  """
  @spec stream(Glider.db(), keyword()) :: Enumerable.t()
  def stream(db, opts \\ []) do
    if Keyword.has_key?(opts, :after) do
      raise ArgumentError, "Glider.Check.stream/2 takes no :after; it pages itself"
    end

    opts = Keyword.put_new(opts, :limit, 10_000)

    Procedure.stream(
      fn cursor ->
        with {:ok, report} <- run(db, Keyword.put(opts, :after, cursor)),
             do: {:ok, [report], %{answered: true, complete: report.complete, next: report.after}}
      end,
      fn e ->
        raise Glider.Error, message: "check.run did not answer: #{inspect(e)}", query: "check.run"
      end,
      fn reason -> raise Glider.Error, message: reason, query: "check.run" end
    )
  end

  # ------------------------------------------------------------------ private

  defp report(%{end: %{answered: false} = e}),
    do: {:error, "check.run did not answer (#{e.reason})"}

  defp report(%{rows: rows, end: e, message: message}) do
    {summaries, findings} =
      Enum.split_with(rows, fn [_check, severity | _] -> severity == "summary" end)

    {:ok,
     %Report{
       findings: Enum.map(findings, &finding/1),
       summaries: Enum.map(summaries, &summary/1),
       complete: e.complete,
       after: if(e.complete, do: nil, else: e.next),
       message: message
     }}
  end

  defp finding([check, severity, kind, id, detail]) do
    %Finding{check: check, severity: severity(severity), kind: kind, id: id, detail: detail}
  end

  defp summary([check, "summary", status, id, detail]) do
    counts = :json.decode(detail)

    %Summary{
      check: check,
      status: status(status),
      records: Map.get(counts, "records", 0),
      problems: Map.get(counts, "problems", 0),
      cursor: id
    }
  end

  # Fixed vocabularies of the engine: mapped by table, never String.to_atom.
  defp severity("fault"), do: :fault
  defp severity("candidate"), do: :candidate
  defp severity("info"), do: :info
  defp severity(other), do: other

  defp status("done"), do: :done
  defp status("partial"), do: :partial
end
