defmodule Glider.HotTest do
  # The hot set (glider's docs/HOT.md) from the BEAM: opened with
  # `hot_size:`, reported by `Glider.stats/1` and the telemetry snapshot, and
  # remembered across opens and through a replica, so the first lookups of
  # what was hot read nothing from disk (the snapshot's page reads) and find
  # their pages hot (`Glider.stats/1`'s hot hits).
  use ExUnit.Case, async: true

  alias Glider.Replication

  @moduletag :tmp_dir

  @people 8
  @hot [cache_size: "4M", hot_size: "1M"]

  defp build(db) do
    for i <- 1..@people do
      {:ok, _} = Glider.run(db, ~s|CREATE (:Person {name:"p#{i}"})|)
    end

    for i <- 1..@people, d <- 1..3 do
      j = rem(i - 1 + d, @people) + 1

      {:ok, _} =
        Glider.run(
          db,
          "MATCH (a), (b) WHERE id(a) = #{i} AND id(b) = #{j} CREATE (a)-[:KNOWS]->(b)"
        )
    end

    # Items enough for pages of their own, which the lookups never touch.
    for chunk <- Enum.chunk_every(1..2000, 200) do
      creates =
        Enum.map_join(chunk, ", ", &~s|(:Item {i:#{&1}, pad:"#{String.duplicate("x", 40)}"})|)

      {:ok, _} = Glider.run(db, "CREATE " <> creates)
    end

    :ok = Glider.checkpoint(db)
  end

  # What a service asks all day: each person and whom they know.
  defp look_up_people(db) do
    for p <- 1..@people do
      {:ok, %{rows: rows}} =
        Glider.query(db, "MATCH (p)-[:KNOWS]->(q) WHERE id(p) = #{p} RETURN q.name")

      assert length(rows) == 3
    end
  end

  defp warm(db), do: for(_ <- 1..300, do: look_up_people(db))

  defp stat(db, key) do
    {:ok, s} = Glider.stats(db)
    Map.fetch!(s, key)
  end

  defp reads(db) do
    {:ok, m} = Glider.Telemetry.metrics(db)
    m.page_reads
  end

  # Pages the first lookups after an open read from disk, and the lookups
  # that found their page hot.
  defp first_lookups(db) do
    {r, h} = {reads(db), stat(db, "hot_hits")}
    look_up_people(db)
    {reads(db) - r, stat(db, "hot_hits") - h}
  end

  test "the hot set is remembered across opens and served from memory", %{tmp_dir: dir} do
    path = Path.join(dir, "app.gldb")
    {:ok, db} = Glider.open(path, @hot)
    build(db)
    warm(db)

    {:ok, s} = Glider.stats(db)
    assert s["hot_capacity"] > 0
    assert s["hot_pages"] > 0 and s["hot_hits"] > 0 and s["promotions"] > 0
    assert s["prewarmed"] == 0
    {:ok, m} = Glider.Telemetry.metrics(db)
    assert m.hot_pages == s["hot_pages"] and m.prewarmed == 0
    hot = s["hot_pages"]
    :ok = Glider.close(db)
    assert File.exists?(path <> "-hot"), "the close left the list beside the file"

    # Warm: the list is loaded before open returns.
    {:ok, db} = Glider.open(path, @hot)
    assert stat(db, "prewarmed") == hot
    assert stat(db, "hot_pages") == hot
    {:ok, m} = Glider.Telemetry.metrics(db)
    assert m.prewarmed == hot
    assert {0, hits} = first_lookups(db)
    assert hits > 0
    :ok = Glider.close(db)

    # Cold: the same open without the list.
    File.rm!(path <> "-hot")
    {:ok, db} = Glider.open(path, @hot)
    assert stat(db, "prewarmed") == 0
    assert {cold, 0} = first_lookups(db)
    assert cold > 0
    :ok = Glider.close(db)
  end

  test "a restored replica opens warm on what its source found hot", %{tmp_dir: dir} do
    path = Path.join(dir, "app.gldb")
    url = Path.join(dir, "remote")
    {:ok, db} = Glider.open(path, @hot)
    build(db)
    warm(db)
    # The handle stays open: sync/3 polls it for the base.
    assert {:ok, %{bases_uploaded: 1}} =
             Replication.sync(path, url, db: db, spool: Path.join(dir, "spool"))

    :ok = Glider.close(db)

    out = Path.join(dir, "restored.gldb")
    assert {:ok, _} = Replication.restore(url, out)
    assert File.exists?(out <> "-hot"), "the base carried the list"
    {:ok, back} = Glider.open(out, @hot)
    assert stat(back, "prewarmed") > 0
    assert {0, hits} = first_lookups(back)
    assert hits > 0
    :ok = Glider.close(back)

    # The same restore without the list is cold.
    cold = Path.join(dir, "restored-cold.gldb")
    assert {:ok, _} = Replication.restore(url, cold)
    File.rm!(cold <> "-hot")
    {:ok, back} = Glider.open(cold, @hot)
    assert stat(back, "prewarmed") == 0
    assert {cold, 0} = first_lookups(back)
    assert cold > 0
    :ok = Glider.close(back)
  end

  test "without hot_size there is no hot set and no list", %{tmp_dir: dir} do
    path = Path.join(dir, "plain.gldb")
    {:ok, db} = Glider.open(path, cache_size: "4M")
    build(db)
    warm(db)
    {:ok, s} = Glider.stats(db)
    refute Map.has_key?(s, "hot_capacity")
    {:ok, m} = Glider.Telemetry.metrics(db)
    assert {m.hot_pages, m.prewarmed} == {0, 0}
    :ok = Glider.close(db)
    refute File.exists?(path <> "-hot")
  end
end
