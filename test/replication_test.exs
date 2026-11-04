defmodule Glider.ReplicationTest do
  use ExUnit.Case, async: true

  alias Glider.Replication

  @moduletag :tmp_dir

  @seed ~S|CREATE (:Job {name:"build"})-[:BLOCKS]->(:Job {name:"test"})|

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "app.gldb")
    {:ok, db} = Glider.open(path)
    {:ok, _} = Glider.run(db, @seed)
    on_exit(fn -> Glider.close(db) end)
    %{dir: dir, path: path, db: db, url: Path.join(dir, "remote"), spool: Path.join(dir, "spool")}
  end

  defp names(db) do
    {:ok, %{rows: rows}} = Glider.query(db, "MATCH (n:Job) RETURN n.name, n.done ORDER BY n.name")
    rows
  end

  describe "sync and restore" do
    test "a base, then the log, and a restore that answers like the source", ctx do
      # The handle holds the file open, so the base needs it polled: sync/3 does.
      assert {:ok, %{bases_uploaded: 1} = first} =
               Replication.sync(ctx.path, ctx.url, db: ctx.db, spool: ctx.spool)

      {:ok, _} = Glider.run(ctx.db, ~S|CREATE (:Job {name:"deploy"})|)
      {:ok, _} = Glider.run(ctx.db, ~S|MATCH (j:Job {name:"test"}) SET j.done = true|)

      assert {:ok, %{bases_uploaded: 0, segments_uploaded: n, lag_bytes: 0}} =
               Replication.sync(ctx.path, ctx.url, db: ctx.db, spool: ctx.spool)

      assert n > 0
      assert {:ok, 0} = Replication.lag(ctx.path, ctx.url)

      out = Path.join(ctx.dir, "restored.gldb")
      assert {:ok, %{generation: gen, segments: s}} = Replication.restore(ctx.url, out)
      assert gen == first.generation
      assert s >= 1

      {:ok, back} = Glider.open(out)
      assert names(back) == names(ctx.db)
      assert length(names(back)) == 3
    end

    test "a restore never overwrites a file", ctx do
      {:ok, _} = Replication.sync(ctx.path, ctx.url, db: ctx.db, spool: ctx.spool)
      assert {:error, reason} = Replication.restore(ctx.url, ctx.path)
      assert reason =~ "already exists"
    end

    test "force_snapshot takes a new base", ctx do
      {:ok, %{bases_uploaded: 1}} = Replication.sync(ctx.path, ctx.url, db: ctx.db, spool: ctx.spool)
      # A base is a checkpoint: with nothing written since, a forced one is the same base.
      {:ok, _} = Glider.run(ctx.db, ~S|CREATE (:Job {name:"deploy"})|)

      assert {:ok, %{bases_uploaded: 1}} =
               Replication.sync(ctx.path, ctx.url, db: ctx.db, spool: ctx.spool, force_snapshot: true)

      {:ok, [gen]} = Replication.generations(ctx.url)
      assert {:ok, %{bases: [_, _]}} = Replication.listing(ctx.url, gen)
    end
  end

  describe "listing" do
    test "generations and what each holds", ctx do
      assert {:ok, []} = Replication.generations(ctx.url)
      {:ok, %{generation: gen}} = Replication.sync(ctx.path, ctx.url, db: ctx.db, spool: ctx.spool)
      assert {:ok, [^gen]} = Replication.generations(ctx.url)

      assert {:ok, %{bases: [%{lsn: lsn, ts: ts}], segments: _, complete_to: to}} =
               Replication.listing(ctx.url, gen)

      assert is_integer(ts) and to >= lsn
    end

    test "an in-memory or missing path is not a paged database", ctx do
      assert {:error, reason} = Replication.sync(Path.join(ctx.dir, "nope.gldb"), ctx.url)
      assert reason =~ "not a paged database"
    end
  end

  describe "Glider.Replicator" do
    test "replicates on a schedule and on demand", ctx do
      pid =
        start_supervised!(
          {Glider.Replicator, path: ctx.path, url: ctx.url, db: ctx.db, spool: ctx.spool, interval: 60_000}
        )

      # The first pass runs at start; sync_now waits behind it.
      {:ok, _} = Glider.run(ctx.db, ~S|CREATE (:Job {name:"deploy"})|)
      assert {:ok, %{segments_uploaded: _}} = Glider.Replicator.sync_now(pid)

      assert %{passes: passes, errors: 0, last: %{generation: gen}} = Glider.Replicator.status(pid)
      assert passes >= 2
      assert {:ok, %{bases: [_ | _]}} = Replication.listing(ctx.url, gen)

      out = Path.join(ctx.dir, "restored.gldb")
      {:ok, _} = Replication.restore(ctx.url, out)
      {:ok, back} = Glider.open(out)
      assert names(back) == names(ctx.db)
    end
  end

  describe "S3" do
    @describetag :s3

    setup do
      fakes3 = Path.expand("../../glider/tests/fakes3.py", __DIR__)
      python = System.find_executable("python3")

      if python == nil or not File.exists?(fakes3) do
        {:ok, skip: true}
      else
        {:ok, sock} = :gen_tcp.listen(0, [])
        {:ok, port} = :inet.port(sock)
        :ok = :gen_tcp.close(sock)
        server = Port.open({:spawn_executable, python}, [:binary, args: ["-I", fakes3, Integer.to_string(port)]])
        {:os_pid, os_pid} = Port.info(server, :os_pid)
        on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)]) end)
        :ok = await_listening(port, 100)
        {:ok, endpoint: "http://127.0.0.1:#{port}"}
      end
    end

    test "round trip through a signature-checking S3 server", ctx do
      if ctx[:skip] do
        IO.puts("skipped: python3 or ../glider/tests/fakes3.py not found")
      else
        s3 = [
          endpoint: ctx.endpoint,
          access_key_id: "glidertest",
          secret_access_key: "glidertestsecret",
          spool: ctx.spool
        ]

        url = "s3://graphs/app"
        assert {:ok, %{bases_uploaded: 1}} = Replication.sync(ctx.path, url, [db: ctx.db] ++ s3)
        {:ok, _} = Glider.run(ctx.db, ~S|CREATE (:Job {name:"deploy"})|)
        assert {:ok, %{segments_uploaded: n}} = Replication.sync(ctx.path, url, [db: ctx.db] ++ s3)
        assert n > 0

        out = Path.join(ctx.dir, "from-s3.gldb")
        assert {:ok, _} = Replication.restore(url, out, s3)
        {:ok, back} = Glider.open(out)
        assert names(back) == names(ctx.db)
      end
    end
  end

  defp await_listening(_port, 0), do: {:error, :fakes3_did_not_start}

  defp await_listening(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:ok, s} ->
        :gen_tcp.close(s)
        :ok

      {:error, _} ->
        receive do
        after
          50 -> await_listening(port, tries - 1)
        end
    end
  end
end
