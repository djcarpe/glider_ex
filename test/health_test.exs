defmodule Glider.HealthTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2]

  alias Glider.Changes.Status
  alias Glider.Health

  test "a memory graph: revision, lineage, counts, memory, no extensions, no journal" do
    {:ok, db} = Glider.open(max_memory: "64M")
    Glider.run!(db, "CREATE (:A)-[:R]->(:B)")
    {:ok, rev} = Glider.revision(db)

    assert {:ok,
            %Health{
              revision: ^rev,
              generation: "00000000000000000000000000000000",
              nodes: 2,
              edges: 1,
              memory_bytes: mem,
              max_memory: max,
              extensions: [],
              changes: nil,
              read_error: nil
            }} = Glider.health(db)

    assert mem > 0 and max == 64 <<< 20
  end

  test "names the installed extensions and carries the journal's status" do
    {:ok, db} = Glider.open()
    :ok = Glider.Changes.install(db, cap: 1_000)
    :ok = Glider.Check.install(db)
    Glider.run!(db, "CREATE (:A)")

    assert {:ok,
            %Health{extensions: exts, changes: %Status{cap: 1_000, entries: 1, why: :installed}}} =
             Glider.health(db)

    assert Enum.sort(Enum.map(exts, & &1.name)) == ["changes", "check"]
    assert Enum.all?(exts, &is_binary(&1.version))

    assert {:ok, %Health{changes: nil}} = Glider.health(db, changes: false)
    assert {:ok, %Health{}} = Glider.health(db, max_millis: 5_000, max_steps: 100_000)
    assert {:error, "Glider.health/2 has no option :deep"} = Glider.health(db, deep: true)
  end

  test "runs no check and changes nothing" do
    {:ok, db} = Glider.open()
    :ok = Glider.Changes.install(db)
    Glider.run!(db, "CREATE (:A)")
    {:ok, rev} = Glider.revision(db)
    {:ok, _} = Glider.health(db)
    assert {:ok, ^rev} = Glider.revision(db)
  end

  @tag :tmp_dir
  test "a file: sizes and its generation", %{tmp_dir: dir} do
    {:ok, db} = Glider.open(Path.join(dir, "h.gldb"))
    Glider.run!(db, "CREATE (:A)")

    assert {:ok, %Health{file_bytes: f, max_memory: nil, memory_bytes: m, generation: gen}} =
             Glider.health(db)

    assert f > 0 and m > 0 and gen != String.duplicate("0", 32)
  end

  @tag :tmp_dir
  test "reports a storage read error the engine recorded, once", %{tmp_dir: dir} do
    src = Path.join(dir, "src.gldb")
    {:ok, db} = Glider.open(src)

    for i <- 1..400,
        do: Glider.run!(db, "CREATE (:P {i: $i, s: $s})", i: i, s: String.duplicate("y", 200))

    :ok = Glider.checkpoint(db)
    Glider.close(db)
    clean = File.read!(src)
    page = 16_384

    # Damage one page at a time. Where the file still opens, a read that
    # does not itself report damage (an export walks the records through
    # the graph API) leaves the engine's record behind; health finds it.
    reported =
      for p <- 1..(div(byte_size(clean), page) - 1), reduce: [] do
        acc ->
          at = p * page + 100
          <<head::binary-size(^at), byte, rest::binary>> = clean
          path = Path.join(dir, "d#{p}.gldb")
          File.write!(path, <<head::binary, Bitwise.bxor(byte, 0x5A), rest::binary>>)

          case Glider.open(path) do
            {:error, _} ->
              acc

            {:ok, db} ->
              _ = Glider.export_jsonl(db)
              {:ok, %Health{read_error: first}} = Glider.health(db)
              {:ok, %Health{read_error: second}} = Glider.health(db)
              Glider.close(db)
              if first, do: [{p, first, second} | acc], else: acc
          end
      end

    assert reported != []

    for {_p, first, second} <- reported do
      assert first =~ "checksum mismatch"
      assert second == nil
    end
  end
end
