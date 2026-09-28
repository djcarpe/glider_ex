defmodule Glider.MigrateTest do
  use ExUnit.Case, async: true

  # A two-node, one-edge database written by the legacy log-format engine
  # (generated with glider::legacy::graph::Graph; see the commit that added it).
  @fixture Path.expand("fixtures/legacy_v2.gldb", __DIR__)

  defp scratch(name) do
    dir = Path.join(System.tmp_dir!(), "glider_ex_migrate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, name)
  end

  test "a legacy file is recognised, and a paged one is not" do
    path = scratch("old.gldb")
    File.cp!(@fixture, path)
    assert is_binary(Glider.legacy(path))

    assert Glider.legacy(scratch("missing.gldb")) == nil

    paged = scratch("new.gldb")
    {:ok, db} = Glider.open(paged)
    :ok = Glider.close(db)
    assert Glider.legacy(paged) == nil
  end

  test "the paged engine refuses a legacy file until it is migrated in place" do
    path = scratch("swarm.gldb")
    File.cp!(@fixture, path)

    assert {:error, reason} = Glider.open(path)
    assert reason =~ "legacy" or reason =~ "migrate"

    assert {:ok, %{nodes: 2, edges: 1}} = Glider.migrate(path)
    assert File.exists?(path <> ".legacy.bak")
    refute File.exists?(path <> ".migrating")
    assert Glider.legacy(path) == nil

    {:ok, db} = Glider.open(path)

    {:ok, result} =
      Glider.query(
        db,
        "MATCH (t:HiveTask)-[r:IN_GOAL]->(g:HiveGoal) RETURN t._key, g.title, r._origin"
      )

    assert result.rows == [["task:t_1", "ship", "jido-swarm-1"]]
    :ok = Glider.close(db)

    # Migrating a paged database is refused, not repeated.
    assert {:error, _} = Glider.migrate(path)
  end
end
