defmodule Glider.TransactionTest do
  # Can any part of a transaction the engine rolled back, or one the caller
  # abandoned, end up committed? Every way in through `Glider.transaction/2`.
  use ExUnit.Case, async: true

  defp count(db) do
    {:ok, %{"nodes" => n}} = Glider.stats(db)
    n
  end

  test "COMPACT inside a transaction is refused rather than committing what is pending" do
    # Before the binding opened transactions with the engine's begin(), this
    # committed the CREATE, and the rollback that followed undid nothing.
    {:ok, db} = Glider.open()

    assert {:error, :abandoned} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Pending)")
               assert {:error, reason} = Glider.run(db, "COMPACT")
               assert reason =~ "commits on its own"
               Glider.rollback(db, :abandoned)
             end)

    assert count(db) == 0
  end

  @tag :tmp_dir
  test "on a file too, and a later commit commits nothing", %{tmp_dir: dir} do
    {:ok, db} = Glider.open(Path.join(dir, "tx.gldb"))
    {:ok, rev} = Glider.revision(db)

    assert {:error, reason} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Pending)")
               {:error, _} = Glider.run(db, "COMPACT")
               Glider.run(db, "CREATE (:After)")
               :done
             end)

    assert reason =~ "rolled back"
    assert count(db) == 0
    assert {:ok, ^rev} = Glider.revision(db)
  end

  test "an import or a batch inside a transaction is refused and commits nothing" do
    {:ok, db} = Glider.open()

    assert {:error, _} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Pending)")

               assert {:error, reason} =
                        Glider.import_jsonl(
                          db,
                          ~s({"type":"node","id":1,"labels":["J"],"props":{}})
                        )

               assert reason =~ "commits on its own"
               :done
             end)

    assert {:error, _} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Pending)")
               assert {:error, _} = Glider.write_batch(db, [{"CREATE (:B)", %{}}])
               :done
             end)

    assert count(db) == 0
  end

  @tag :tmp_dir
  test "an import from a file inside a transaction is refused too", %{tmp_dir: dir} do
    path = Path.join(dir, "in.jsonl")
    File.write!(path, ~s({"type":"node","id":1,"labels":["J"],"props":{}}\n))
    {:ok, db} = Glider.open()

    assert {:error, _} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Pending)")
               assert {:error, _} = Glider.import_file(db, path)
               :done
             end)

    assert count(db) == 0
    assert {:ok, %{nodes: 1}} = Glider.import_file(db, path)
  end

  test "a failing statement, caught by the caller, still leaves nothing to commit" do
    {:ok, db} = Glider.open()

    assert {:error, reason} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Before)")

               try do
                 Glider.run!(db, "MATCH ((")
               rescue
                 Glider.Error -> :swallowed
               end

               Glider.run(db, "CREATE (:After)")
               :done
             end)

    assert reason =~ "rolled back"
    assert count(db) == 0
  end

  test "a memory graph that runs out of memory mid-transaction commits none of it" do
    {:ok, db} = Glider.open(max_memory: "2M")
    :ok = Glider.Changes.install(db)
    big = String.duplicate("x", 100_000)

    assert {:error, reason} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:Keep)")

               results =
                 for i <- 1..60, do: Glider.run(db, "CREATE (:Big {s: $s, i: $i})", s: big, i: i)

               assert Enum.any?(results, &match?({:error, _}, &1))
               # the caller carries on after the failure
               Glider.run(db, "CREATE (:After)")
               :done
             end)

    assert reason =~ "rolled back"
    assert count(db) == 0
  end

  test "a transaction that commits still commits, and the handle autocommits after" do
    {:ok, db} = Glider.open()
    assert {:ok, :ok} = Glider.transaction(db, fn -> Glider.run!(db, "CREATE (:A)") && :ok end)
    Glider.run!(db, "CREATE (:B)")

    assert {:error, :x} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:C)") && Glider.rollback(db, :x)
             end)

    # COMPACT is allowed again once the transaction has ended
    assert {:ok, _} = Glider.run(db, "COMPACT")
    assert count(db) == 2
  end
end
