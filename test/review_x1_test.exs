defmodule Glider.ReviewX1Test do
  # The review of the derived-data slice (X1): each finding's test, turned to
  # assert the fixed behaviour.
  use ExUnit.Case, async: true

  alias Glider.Changes.Unanswerable

  defp count(db) do
    {:ok, %{"nodes" => n}} = Glider.stats(db)
    n
  end

  # ---------------------------------------------- 1: watermarks are committed
  #
  # Since the engine reads the committed journal inside a transaction, since/3
  # answers there again (the InTransaction refusal is gone); the losses are
  # shown not to happen in test/watermark_test.exs.

  test "a question that cannot be answered inside a transaction leaves it to commit" do
    {:ok, db} = Glider.open()
    :ok = Glider.Changes.install(db)
    Glider.run!(db, "CREATE (:A)")
    {:ok, rev} = Glider.revision(db)

    tx =
      Glider.transaction(db, fn ->
        Glider.run!(db, "CREATE (:Derived)")
        Glider.Changes.since(db, rev + 1_000_000)
      end)

    assert {:ok, {:error, %Unanswerable{reason: :ahead}}} = tx
    assert count(db) == 2
  end

  test "an Unanswerable carries the oldest answerable revision where the engine names one" do
    {:ok, db} = Glider.open()
    Glider.run!(db, "CREATE (:A)")
    :ok = Glider.Changes.install(db)
    {:ok, rev} = Glider.revision(db)

    assert {:error, %Unanswerable{reason: :ahead, oldest: o1}} =
             Glider.Changes.since(db, rev + 1_000_000)

    assert {:error, %Unanswerable{reason: :installed, oldest: o2}} =
             Glider.Changes.since(db, 0)

    assert is_integer(o1) and is_integer(o2)
  end

  # ------------------------------------- 2: a dead process never owns the handle

  defp hold(db) do
    parent = self()

    holder =
      spawn(fn ->
        Glider.transaction(db, fn ->
          send(parent, :holding)

          receive do
            :release -> :ok
          end
        end)

        send(parent, :holder_done)
      end)

    assert_receive :holding
    holder
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    # :noproc when it had already finished
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:killed, :noproc]
  end

  defp assert_free(db) do
    # within a second, not after the 60 s transaction wait
    task = Task.async(fn -> Glider.run(db, "CREATE (:After)") end)
    assert {:ok, 1} = Task.await(task, 5_000)
    assert {:ok, :x} = Glider.transaction(db, fn -> :x end)
    refute Glider.in_transaction?(db)
  end

  test "a process killed while it waits to begin does not leave the handle owned" do
    {:ok, db} = Glider.open()
    holder = hold(db)
    parent = self()
    waiter = spawn(fn -> Glider.transaction(db, fn -> send(parent, :waiter_in) end) end)
    # let it reach the wait inside the native begin
    Process.sleep(200)
    kill(waiter)
    send(holder, :release)
    assert_receive :holder_done
    refute_receive :waiter_in, 100
    assert_free(db)
    assert count(db) == 1
  end

  test "killed just before the wait, and just after waking" do
    for delay <- [0, 1, 2, 5, 10, 20] do
      {:ok, db} = Glider.open()
      holder = hold(db)
      waiter = spawn(fn -> Glider.transaction(db, fn -> Glider.run!(db, "CREATE (:W)") end) end)
      if delay > 0, do: Process.sleep(delay)
      # release first, then kill: the waiter may be waking, just awake, or in
      send(holder, :release)
      if delay > 2, do: Process.sleep(delay - 2)
      kill(waiter)
      assert_receive :holder_done
      assert_free(db)
      # the waiter's write is either committed whole (it finished) or absent
      assert count(db) in [1, 2]
    end

    {:ok, db} = Glider.open()
    waiter = spawn(fn -> Glider.transaction(db, fn -> :ok end) end)
    kill(waiter)
    assert_free(db)
  end

  test "killed just after its first statement: rolled back, and the handle is free" do
    {:ok, db} = Glider.open()
    parent = self()

    owner =
      spawn(fn ->
        Glider.transaction(db, fn ->
          Glider.run!(db, "CREATE (:Doomed)")
          send(parent, :wrote)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :wrote
    kill(owner)
    assert_free(db)
    assert count(db) == 1
  end

  # ------------------------------------------------------- 3: health and damage

  defp damaged(dir) do
    src = Path.join(dir, "src.gldb")
    {:ok, db} = Glider.open(src)

    for i <- 1..400,
        do: Glider.run!(db, "CREATE (:P {i: $i, s: $s})", i: i, s: String.duplicate("y", 200))

    :ok = Glider.checkpoint(db)
    Glider.close(db)
    clean = File.read!(src)
    page = 16_384

    Enum.find_value(1..(div(byte_size(clean), page) - 1), fn p ->
      at = p * page + 100
      <<head::binary-size(^at), byte, rest::binary>> = clean
      path = Path.join(dir, "d#{p}.gldb")
      File.write!(path, <<head::binary, Bitwise.bxor(byte, 0x5A), rest::binary>>)

      case Glider.open(path) do
        {:ok, db} ->
          _ = Glider.export_jsonl(db)
          {:ok, %Glider.Health{read_error: e}} = Glider.health(db)
          Glider.close(db)
          if e, do: path

        _ ->
          nil
      end
    end)
  end

  @tag :tmp_dir
  test "health inside a transaction reports a pending read error and leaves the transaction",
       %{tmp_dir: dir} do
    path = damaged(dir)
    assert path

    {:ok, db} = Glider.open(path)

    tx =
      Glider.transaction(db, fn ->
        _ = Glider.export_jsonl(db)
        {:ok, %Glider.Health{read_error: e}} = Glider.health(db)
        assert e =~ "checksum mismatch"
        # not cleared: health again, then the next statement, are told
        {:ok, %Glider.Health{read_error: ^e}} = Glider.health(db)

        assert {:error, "database image is damaged: " <> rest} =
                 Glider.query(db, "MATCH (n) RETURN count(n)")

        assert rest =~ e
        :done
      end)

    # the statement's failure aborted the transaction, as it would have
    # without health; health itself did not
    assert {:error, _} = tx
    assert {:ok, %Glider.Health{read_error: nil}} = Glider.health(db)
  end

  @tag :tmp_dir
  test "health that finds no damage commits with the transaction", %{tmp_dir: dir} do
    {:ok, db} = Glider.open(Path.join(dir, "ok.gldb"))
    :ok = Glider.Changes.install(db)

    assert {:ok, :ok} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:A)")
               {:ok, %Glider.Health{read_error: nil}} = Glider.health(db)
               :ok
             end)

    assert count(db) == 1
  end

  # --------------------------------------------------------------------- 4: low

  test "install with a refused cap inside a caller's transaction returns an error" do
    {:ok, db} = Glider.open()

    tx =
      Glider.transaction(db, fn ->
        Glider.run!(db, "CREATE (:Mine)")
        Glider.Changes.install(db, cap: 1)
      end)

    assert {:ok, {:error, msg}} = tx
    assert msg =~ "at least 64"
    assert count(db) == 1
  end

  test "install with a cap inside a caller's transaction joins it" do
    {:ok, db} = Glider.open()
    assert {:ok, :ok} = Glider.transaction(db, fn -> Glider.Changes.install(db, cap: 100) end)
    assert {:ok, %{cap: 100}} = Glider.Changes.status(db)

    assert {:error, :undo} =
             Glider.transaction(db, fn ->
               :ok = Glider.Changes.cap(db, 200) |> then(fn {:ok, _} -> :ok end)
               Glider.rollback(db, :undo)
             end)

    assert {:ok, %{cap: 100}} = Glider.Changes.status(db)
  end

  test "a failed write, then commit, then the handle" do
    {:ok, db} = Glider.open()
    :ok = Glider.Changes.install(db)

    assert {:error, _} =
             Glider.transaction(db, fn ->
               Glider.run!(db, "CREATE (:A)")
               {:error, _} = Glider.run(db, "CREATE (:B {v: $v})", v: deep(200))
               Glider.run(db, "CREATE (:C)")
             end)

    assert count(db) == 0
    assert {:ok, {:ok, 1}} = Glider.transaction(db, fn -> Glider.run(db, "CREATE (:D)") end)
    assert count(db) == 1
  end

  defp deep(0), do: 1
  defp deep(n), do: [deep(n - 1)]

  test "a bad limit is an error tuple naming it, before anything is sent" do
    {:ok, db} = Glider.open()
    :ok = Glider.Changes.install(db)
    :ok = Glider.Check.install(db)

    for limit <- [0, -1, 1.5, "3"] do
      assert {:error, "limit: must be a whole number at least 1" <> _} =
               Glider.Changes.since(db, 0, limit: limit)

      assert {:error, "limit: must be a whole number at least 1" <> _} =
               Glider.Check.run(db, limit: limit)
    end
  end

  test "both installs take the budget and are spans naming their procedure" do
    {:ok, db} = Glider.open()
    id = make_ref()
    test = self()

    :telemetry.attach(id, [:glider, :query, :stop], &__MODULE__.forward/4, {test, db})

    on_exit(fn -> :telemetry.detach(id) end)

    assert :ok = Glider.Changes.install(db, max_millis: 5_000, max_steps: 1_000_000)
    assert :ok = Glider.Check.install(db, max_millis: 5_000)
    assert_receive {:stop, %{procedure: "changes.install", result: :ok}}
    assert_receive {:stop, %{procedure: "check.install", result: :ok}}

    assert {:error, "Glider.Check.install/2 has no option :cap"} =
             Glider.Check.install(db, cap: 1)
  end

  @tag :tmp_dir
  test "self-committing calls inside a transaction are refused and commit nothing", %{
    tmp_dir: dir
  } do
    line = ~s({"type":"node","id":1,"labels":["J"],"props":{}})
    jl = Path.join(dir, "in.jsonl")
    File.write!(jl, line <> "\n")

    ops = [
      import_jsonl: fn db -> Glider.import_jsonl(db, line) end,
      import_file: fn db -> Glider.import_file(db, jl) end,
      write_batch: fn db -> Glider.write_batch(db, [{"CREATE (:W)", %{}}]) end,
      compact: fn db -> Glider.run(db, "COMPACT") end
    ]

    for {name, op} <- ops do
      {:ok, db} = Glider.open(Path.join(dir, "#{name}.gldb"))

      tx =
        Glider.transaction(db, fn ->
          Glider.run!(db, "CREATE (:Before)")
          assert {:error, reason} = op.(db)
          assert reason =~ "commits on its own" or reason =~ "cannot join", "#{name}: #{reason}"
          :done
        end)

      assert {:error, _} = tx
      assert count(db) == 0, "#{name} committed"
      Glider.close(db)
    end
  end

  # ------------------------------------------------- lows left by the review

  test "revision/2 and generation/2 refuse an option they do not document, by name" do
    {:ok, db} = Glider.open()
    assert {:error, "Glider.revision/2 has no option :probe"} = Glider.revision(db, probe: true)

    assert {:error, "Glider.generation/2 has no option :probe"} =
             Glider.generation(db, probe: true)

    assert {:ok, _} = Glider.revision(db, max_steps: 100)
  end

  @tag :tmp_dir
  test "stats reports a recorded read error the same whether or not health ran first",
       %{tmp_dir: dir} do
    path = damaged(dir)
    assert path

    seen =
      for health_first <- [false, true] do
        {:ok, db} = Glider.open(path)
        _ = Glider.export_jsonl(db)

        reported =
          if health_first do
            {:ok, %Glider.Health{read_error: e}} = Glider.health(db)
            e
          end

        {:ok, %{"integrity_error" => error}} = Glider.stats(db)
        assert reported in [nil, error]
        # left in place: stats again, and the next statement still fails with it
        {:ok, %{"integrity_error" => ^error}} = Glider.stats(db)

        assert {:error, "database image is damaged: " <> _} =
                 Glider.query(db, "MATCH (n) RETURN n")

        Glider.close(db)
        error
      end

    assert [same, same] = seen
  end

  def forward(_event, _measurements, %{db: db} = meta, {test, db}), do: send(test, {:stop, meta})
  def forward(_event, _measurements, _meta, _config), do: :ok
end
