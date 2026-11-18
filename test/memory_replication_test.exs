defmodule Glider.MemoryReplicationTest do
  @moduledoc """
  A memory graph replicated as a file is, and restored to either place:
  memory to a replica to memory, memory to a replica to a file, a file to a
  replica to memory, against a directory and against the S3 fake. Each
  round trip compares the data and carries the lineage on: a pass from the
  restored side ships only what it wrote, under the same generation, with no
  new base. And a pass leaves the handle free while it uploads.
  """
  use ExUnit.Case, async: true

  alias Glider.Replication

  @moduletag :tmp_dir

  @seed ~S|CREATE (:Job {name:"build"})-[:BLOCKS]->(:Job {name:"test"})|

  defp names(db) do
    {:ok, %{rows: rows}} = Glider.query(db, "MATCH (n:Job) RETURN n.name, n.done ORDER BY n.name")
    rows
  end

  defp edges(db) do
    {:ok, %{rows: rows}} =
      Glider.query(db, "MATCH (a:Job)-[r:BLOCKS]->(b:Job) RETURN a.name, b.name ORDER BY a.name, b.name")

    rows
  end

  defp same!(a, b) do
    assert names(a) == names(b)
    assert edges(a) == edges(b)
  end

  defp run!(db, q) do
    {:ok, _} = Glider.run(db, q)
    db
  end

  defp memory_graph do
    {:ok, db} = Glider.open(log: true)
    run!(db, @seed)
  end

  # ------------------------------------------------------------ round trips

  defp memory_to_memory(url, b) do
    db = memory_graph()
    assert {:ok, %{bases_uploaded: 1, generation: gen}} = Replication.sync(db, url, b)
    run!(db, ~S|CREATE (:Job {name:"deploy"})|)
    run!(db, ~S|MATCH (j:Job {name:"test"}) SET j.done = true|)

    assert {:ok, %{bases_uploaded: 0, segments_uploaded: 1, lag_bytes: 0, generation: ^gen}} =
             Replication.sync(db, url, b)

    assert {:ok, 0} = Replication.lag(db, url, b)

    assert {:ok, %{db: back, generation: ^gen, segments: 1}} = Replication.restore(url, :memory, b)
    same!(back, db)

    # Written to and shipped back: only what it wrote, on the same lineage.
    run!(back, ~S|CREATE (:Job {name:"ship"})|)
    assert {:ok, lag} = Replication.lag(back, url, b)
    assert lag > 0

    assert {:ok, %{bases_uploaded: 0, segments_uploaded: 1, generation: ^gen}} =
             Replication.sync(back, url, b)

    assert {:ok, %{db: again, generation: ^gen}} = Replication.restore(url, :memory, b)
    same!(again, back)
    assert length(names(again)) == 4
  end

  defp memory_to_file(dir, url, b) do
    db = memory_graph()
    assert {:ok, %{bases_uploaded: 1, generation: gen}} = Replication.sync(db, url, b)
    run!(db, ~S|CREATE (:Job {name:"deploy"})-[:BLOCKS]->(:Job {name:"ship"})|)
    assert {:ok, %{segments_uploaded: 1}} = Replication.sync(db, url, b)

    out = Path.join(dir, "from-memory.gldb")
    assert {:ok, %{generation: ^gen}} = Replication.restore(url, out, b)
    {:ok, file} = Glider.open(out)
    same!(file, db)

    run!(file, ~S|MATCH (j:Job {name:"build"}) SET j.done = true|)
    spool = Path.join(dir, "from-memory-spool")

    assert {:ok, %{bases_uploaded: 0, segments_uploaded: n, generation: ^gen}} =
             Replication.sync(out, url, [db: file, spool: spool] ++ b)

    assert n > 0
    assert {:ok, %{db: back, generation: ^gen}} = Replication.restore(url, :memory, b)
    same!(back, file)
    Glider.close(file)
  end

  defp file_to_memory(dir, url, b) do
    path = Path.join(dir, "source.gldb")
    spool = Path.join(dir, "source-spool")
    {:ok, file} = Glider.open(path)
    run!(file, @seed)

    assert {:ok, %{bases_uploaded: 1, generation: gen}} =
             Replication.sync(path, url, [db: file, spool: spool] ++ b)

    run!(file, ~S|CREATE (:Job {name:"deploy"})|)
    assert {:ok, %{bases_uploaded: 0}} = Replication.sync(path, url, [db: file, spool: spool] ++ b)

    assert {:ok, %{db: mem, generation: ^gen}} = Replication.restore(url, :memory, b)
    same!(mem, file)

    run!(mem, ~S|MATCH (j:Job {name:"deploy"}) SET j.done = true|)

    assert {:ok, %{bases_uploaded: 0, segments_uploaded: 1, generation: ^gen}} =
             Replication.sync(mem, url, b)

    out = Path.join(dir, "back-to-file.gldb")
    assert {:ok, %{generation: ^gen}} = Replication.restore(url, out, b)
    {:ok, back} = Glider.open(out)
    same!(back, mem)
    Glider.close(back)
    Glider.close(file)
  end

  describe "round trips through a directory" do
    test "memory to a replica to memory", %{tmp_dir: dir} do
      memory_to_memory(Path.join(dir, "remote"), [])
    end

    test "memory to a replica to a file", %{tmp_dir: dir} do
      memory_to_file(dir, Path.join(dir, "remote"), [])
    end

    test "a file to a replica to memory", %{tmp_dir: dir} do
      file_to_memory(dir, Path.join(dir, "remote"), [])
    end
  end

  describe "a memory graph" do
    test "without a log cannot be replicated", %{tmp_dir: dir} do
      {:ok, db} = Glider.open()
      assert {:error, reason} = Replication.sync(db, Path.join(dir, "remote"))
      assert reason =~ "log: true"
    end

    test "restored too big for max_memory is an error", %{tmp_dir: dir} do
      url = Path.join(dir, "remote")
      db = memory_graph()
      blob = String.duplicate("x", 4000)

      for i <- 1..800 do
        run!(db, "CREATE (:Big {i: #{i}, blob: \"#{blob}\"})")
      end

      {:ok, %{bases_uploaded: 1}} = Replication.sync(db, url)
      assert {:error, reason} = Replication.restore(url, :memory, max_memory: "64K")
      assert reason =~ "max_memory"
      assert {:ok, %{db: back}} = Replication.restore(url, :memory, max_memory: "64M")
      assert {:ok, %{rows: [[800]]}} = Glider.query(back, "MATCH (n:Big) RETURN count(n)")
    end

    test "retention and listing see its replica", %{tmp_dir: dir} do
      url = Path.join(dir, "remote")
      db = memory_graph()
      {:ok, %{generation: gen}} = Replication.sync(db, url)
      run!(db, ~S|CREATE (:Job {name:"deploy"})|)
      {:ok, _} = Replication.sync(db, url)
      Process.sleep(1100)
      {:ok, %{bases_uploaded: 1}} = Replication.sync(db, url, force_snapshot: true)

      assert {:ok, [^gen]} = Replication.generations(url)
      assert {:ok, %{bases: [_, _], segments: [_]}} = Replication.listing(url, gen)
      assert {:ok, deleted} = Replication.enforce_retention(db, url, retention: 0)
      assert deleted >= 2
      assert {:ok, %{bases: [_], segments: []}} = Replication.listing(url, gen)
      assert {:ok, %{db: back}} = Replication.restore(url, :memory)
      same!(back, db)
    end

    test "is kept replicated by Glider.Replicator", %{tmp_dir: dir} do
      url = Path.join(dir, "remote")
      db = memory_graph()
      pid = start_supervised!({Glider.Replicator, db: db, url: url, interval: 60_000})
      # The first pass runs at start, before anything waiting on the server.
      assert %{passes: 1, last: %{bases_uploaded: 1}} = Glider.Replicator.status(pid)

      run!(db, ~S|CREATE (:Job {name:"deploy"})|)
      assert {:ok, %{segments_uploaded: 1}} = Glider.Replicator.sync_now(pid)
      assert %{path: nil, passes: passes, errors: 0, last: %{generation: gen}} = Glider.Replicator.status(pid)
      assert passes >= 2
      assert {:ok, %{db: back, generation: ^gen}} = Replication.restore(url, :memory)
      same!(back, db)
    end
  end

  # -------------------------------------------------------------------- S3

  describe "S3" do
    @describetag :s3

    setup do
      fakes3 = Path.expand("../../glider/tests/fakes3.py", __DIR__)
      python = System.find_executable("python3")

      if python == nil or not File.exists?(fakes3) do
        {:ok, skip: true}
      else
        port = free_port()
        server = Port.open({:spawn_executable, python}, [:binary, args: ["-I", fakes3, Integer.to_string(port)]])
        {:os_pid, os_pid} = Port.info(server, :os_pid)
        on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)]) end)
        :ok = await_listening(port, 400)

        {:ok,
         port: port,
         s3: [
           endpoint: "http://127.0.0.1:#{port}",
           access_key_id: "glidertest",
           secret_access_key: "glidertestsecret"
         ]}
      end
    end

    test "memory to a replica to memory", ctx do
      unless ctx[:skip], do: memory_to_memory("s3://graphs/m2m", ctx.s3)
    end

    test "memory to a replica to a file", ctx do
      unless ctx[:skip], do: memory_to_file(ctx.tmp_dir, "s3://graphs/m2f", ctx.s3)
    end

    test "a file to a replica to memory", ctx do
      unless ctx[:skip], do: file_to_memory(ctx.tmp_dir, "s3://graphs/f2m", ctx.s3)
    end

    test "queries on the handle answer while a pass uploads a base to a slow server", ctx do
      unless ctx[:skip] do
        delay = 300
        slow = slow_proxy(ctx.port, delay)
        s3 = Keyword.put(ctx.s3, :endpoint, "http://127.0.0.1:#{slow}")
        db = memory_graph()
        blob = String.duplicate("y", 2000)

        for i <- 1..300 do
          run!(db, "CREATE (:Big {i: #{i}, blob: \"#{blob}\"})")
        end

        me = self()
        handler = "memory-pass-#{inspect(make_ref())}"

        :telemetry.attach(handler, [:glider, :replication, :sync], &__MODULE__.forward/4, {me, db})

        on_exit(fn -> :telemetry.detach(handler) end)

        # Another process, querying the same handle as fast as it can.
        stop = make_ref()

        reader =
          Task.async(fn ->
            Stream.repeatedly(fn ->
              receive do
                ^stop -> :stop
              after
                0 ->
                  t = System.monotonic_time(:millisecond)
                  {:ok, %{rows: [[300]]}} = Glider.query(db, "MATCH (n:Big) RETURN count(n)")
                  {t, System.monotonic_time(:millisecond) - t}
              end
            end)
            |> Enum.take_while(&(&1 != :stop))
          end)

        started = System.monotonic_time(:millisecond)
        assert {:ok, %{bases_uploaded: 1, bytes: bytes}} = Replication.sync(db, "s3://graphs/slow", s3)
        ended = System.monotonic_time(:millisecond)
        send(reader.pid, stop)
        answered = Task.await(reader, 30_000)

        assert bytes > 300 * 2000
        # Looking, listing the base's prefix, its db file and its base.json:
        # every request waits `delay` at the proxy.
        assert ended - started >= 3 * delay

        during = Enum.filter(answered, fn {t, _} -> t >= started and t + 1 < ended end)
        slowest = during |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
        assert length(during) >= 20, "#{length(during)} queries answered during a #{ended - started} ms pass"
        assert slowest < delay, "a query waited #{slowest} ms during the pass"

        assert_receive {:pass, %{bases: 1, bytes: ^bytes, duration: _}, %{result: :ok, path: nil, url: "s3://graphs/slow"}}

        assert {:ok, %{db: back}} = Replication.restore("s3://graphs/slow", :memory, ctx.s3)
        assert {:ok, %{rows: [[300]]}} = Glider.query(back, "MATCH (n:Big) RETURN count(n)")
      end
    end
  end

  @doc false
  def forward(_event, measurements, meta, {pid, db}) do
    if meta[:db] == db, do: send(pid, {:pass, measurements, meta})
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    port
  end

  # A TCP proxy to `target` that waits `delay` ms before passing each
  # connection on. glider's S3 client makes one connection per request, so
  # every request is that much slower.
  defp slow_proxy(target, delay) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    acceptor = spawn(fn -> accept(listen, target, delay) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    on_exit(fn -> Process.exit(acceptor, :kill) end)
    port
  end

  defp accept(listen, target, delay) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        pid = spawn(fn -> receive(do: (:go -> relay(client, target, delay))) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(listen, target, delay)

      {:error, _} ->
        :ok
    end
  end

  defp relay(client, target, delay) do
    Process.sleep(delay)
    {:ok, upstream} = :gen_tcp.connect(~c"127.0.0.1", target, [:binary, active: false])
    spawn(fn -> pipe(upstream, client) end)
    pipe(client, upstream)
  end

  defp pipe(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        :gen_tcp.send(to, data)
        pipe(from, to)

      {:error, _} ->
        :gen_tcp.shutdown(to, :write)
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
