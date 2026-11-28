defmodule Glider.CheckTest do
  use ExUnit.Case, async: true

  alias Glider.Check
  alias Glider.Check.{Finding, Report, Summary}

  @database ~w(endpoints adjacency membership counters indexes derived)

  defp sound do
    {:ok, db} = Glider.open()
    :ok = Check.install(db)
    :ok = Glider.Changes.install(db)
    :ok = Glider.Context.install(db)

    Glider.run!(
      db,
      "CREATE (a:Part {name: 'bolt'})-[:FITS]->(b:Part {name: 'nut'}), (:Part {name: 'washer'})"
    )

    Glider.run!(db, "CREATE INDEX ON :Part(name)")
    {:ok, _} = Glider.Context.index(db)
    db
  end

  # A database whose edge e2 ends at node 99, which does not exist: built by
  # bulk-loading a source that breaks its contract (glider's
  # `Graph::bulk_load` does not check; `check.run` does). Nothing an Elixir
  # caller can do writes such an edge.
  defp dangling(dir) do
    path = Path.join(dir, "dangling.gldb")
    File.write!(path, :zlib.gunzip(File.read!("test/fixtures/dangling_edge.gldb.gz")))
    {:ok, db} = Glider.open(path)
    :ok = Check.install(db)
    db
  end

  test "a sound graph: no findings, and a done summary for each of the database's checks" do
    db = sound()
    {:ok, rev} = Glider.revision(db)

    assert {:ok, %Report{findings: [], after: nil, summaries: summaries, message: message}} =
             Check.run(db)

    assert Enum.map(summaries, & &1.check) == @database
    assert Enum.all?(summaries, &match?(%Summary{status: :done, problems: 0, cursor: nil}, &1))
    assert Enum.find(summaries, &(&1.check == "derived")).records > 0
    assert message =~ "0 problems"
    # it repairs and writes nothing
    assert {:ok, ^rev} = Glider.revision(db)
  end

  @tag :tmp_dir
  test "a planted fault is reported with the record it names", %{tmp_dir: dir} do
    db = dangling(dir)

    assert {:ok, %Report{findings: [finding], after: nil, summaries: [endpoints | _]}} =
             Check.run(db)

    assert %Finding{
             check: "endpoints",
             severity: :fault,
             kind: "missing_target",
             id: "e2",
             detail: "edge e2 [:FITS] ends at n99, which does not exist"
           } = finding

    assert %Summary{check: "endpoints", status: :done, records: 3, problems: 1} = endpoints
    # and the same finding, sliced
    assert [^finding] = db |> Check.stream(limit: 1) |> Enum.flat_map(& &1.findings)
  end

  test "data checks need naming, take their arguments, and report candidates" do
    db = sound()

    Glider.run!(
      db,
      "MATCH (a:Part {name: 'bolt'}), (b:Part {name: 'nut'}) CREATE (a)-[:FITS]->(b)"
    )

    Glider.run!(db, "CREATE (:Part {name: 'bolt'})")
    [washer] = Glider.all(db, "MATCH (p:Part {name: 'washer'}) RETURN id(p)") |> List.flatten()

    # the default run stays silent about facts of the data
    assert {:ok, %Report{findings: []}} = Check.run(db)

    {:ok, %Report{findings: orphans}} = Check.run(db, checks: [:orphans], labels: ["Part"])
    assert "n#{washer}" in Enum.map(orphans, & &1.id)
    assert Enum.all?(orphans, &(&1.severity == :candidate and &1.check == "orphans"))

    {:ok, %Report{findings: dups}} =
      Check.run(db, checks: ["duplicates"], label: "Part", keys: ["name"])

    assert Enum.any?(dups, &(&1.id =~ ~r/^e\d+$/))
    assert Enum.any?(dups, &(&1.id =~ ~r/^n\d+$/))

    {:ok, %Report{findings: req}} =
      Check.run(db, checks: [:required], label: "Part", type: "FITS", dir: :out)

    assert "n#{washer}" in Enum.map(req, & &1.id)

    assert {:error, reason} = Check.run(db, checks: [:required])
    assert reason =~ "label: and type:"
    assert {:error, reason} = Check.run(db, checks: [:nonsense])
    assert reason =~ "no check 'nonsense'"
  end

  test "slices together report exactly what one whole run reports" do
    db = sound()
    for i <- 1..20, do: Glider.run!(db, "CREATE (:Loose {i: $i})", i: i)
    opts = [checks: @database ++ ["orphans"]]
    {:ok, whole} = Check.run(db, opts)
    assert whole.after == nil

    reports = db |> Check.stream([limit: 3] ++ opts) |> Enum.to_list()
    assert length(reports) > 3
    assert Enum.all?(Enum.drop(reports, -1), &is_binary(&1.after))
    assert List.last(reports).after == nil
    assert Enum.flat_map(reports, & &1.findings) == whole.findings

    totals = fn reports ->
      reports
      |> Enum.flat_map(& &1.summaries)
      |> Enum.group_by(& &1.check, &{&1.records, &1.problems})
      |> Map.new(fn {c, l} ->
        {c, l |> Enum.unzip() |> then(fn {r, p} -> {Enum.sum(r), Enum.sum(p)} end)}
      end)
    end

    assert totals.(reports) == totals.([whole])

    # one slice by hand, continued with after:
    {:ok, %Report{after: cursor, summaries: summaries}} = Check.run(db, [limit: 1] ++ opts)
    assert %Summary{status: :partial, cursor: ^cursor} = List.last(summaries)

    assert {:ok, %Report{}} = Check.run(db, [limit: 1, after: cursor] ++ opts)
  end

  test "the stream is lazy and frees the handle between slices" do
    db = sound()
    stream = Check.stream(db, limit: 2)
    [first] = Enum.take(stream, 1)
    assert is_binary(first.after)
    # the handle is usable between slices
    assert {:ok, _} = Glider.revision(db)
    assert_raise ArgumentError, fn -> Check.stream(db, after: first.after) end
  end

  test "options are allow-listed and the extension must be installed" do
    {:ok, db} = Glider.open()
    assert {:error, reason} = Check.run(db)
    assert reason =~ "CREATE EXTENSION check"
    :ok = Check.install(db)
    assert {:error, "Glider.Check.run/2 has no option :bogus"} = Check.run(db, bogus: true)
    assert {:ok, %Report{}} = Check.run(db, max_millis: 10_000, max_steps: 1_000_000)
    assert_raise Glider.Error, fn -> Enum.to_list(Check.stream(db, checks: [:nonsense])) end
  end
end
