defmodule Glider.ChangesTest do
  use ExUnit.Case, async: true

  alias Glider.Changes
  alias Glider.Changes.{Change, Slice, Status, Unanswerable}

  defp journaled(opts \\ []) do
    {:ok, db} = Glider.open()
    Glider.run!(db, "CREATE (:Before)")
    :ok = Changes.install(db, opts)
    db
  end

  defp ids(changes, kind), do: for(%Change{kind: ^kind, id: id} <- changes, do: id)

  describe "revision" do
    test "grows with every change, stays put without one, and stats carry it" do
      {:ok, db} = Glider.open()
      {:ok, r0} = Glider.revision(db)
      assert {:ok, "00000000000000000000000000000000"} = Glider.generation(db)

      Glider.run!(db, "CREATE (:A {v: 1})")
      {:ok, r1} = Glider.revision(db)
      assert r1 > r0

      # a write that changes nothing, a read, a rolled-back transaction
      Glider.run!(db, "MATCH (a:A) SET a.v = 1")
      Glider.query!(db, "MATCH (a) RETURN a")

      {:error, :undo} =
        Glider.transaction(db, fn ->
          Glider.run!(db, "CREATE (:B)") && Glider.rollback(db, :undo)
        end)

      assert {:ok, ^r1} = Glider.revision(db)

      {:ok, stats} = Glider.stats(db)
      assert stats["revision"] == r1
      assert stats["generation"] == "00000000000000000000000000000000"
    end

    @tag :tmp_dir
    test "is durable across a reopen, with a file's own generation", %{tmp_dir: dir} do
      path = Path.join(dir, "rev.gldb")
      {:ok, db} = Glider.open(path)
      Glider.run!(db, "CREATE (:A)")
      {:ok, rev} = Glider.revision(db)
      {:ok, gen} = Glider.generation(db)
      assert gen =~ ~r/^[0-9a-f]{32}$/ and gen != String.duplicate("0", 32)
      :ok = Glider.checkpoint(db)
      Glider.close(db)

      {:ok, db} = Glider.open(path)
      assert {:ok, ^rev} = Glider.revision(db)
      assert {:ok, ^gen} = Glider.generation(db)
    end

    test "takes the budget options and refuses unknown ones" do
      {:ok, db} = Glider.open()
      assert {:ok, _} = Glider.revision(db, max_millis: 1_000, max_steps: 1_000)
      assert {:error, "Glider.revision/2 has no option :bogus"} = Glider.revision(db, bogus: 1)
      assert_raise ArgumentError, fn -> Glider.revision(db, max_steps: -1) end
    end
  end

  describe "since" do
    test "lists exactly what changed, by kind then id, with what happened last" do
      db = journaled()
      {:ok, rev} = Glider.revision(db)
      assert {:ok, %Slice{changes: [], after: nil, complete_up_to: ^rev}} = Changes.since(db, rev)

      Glider.run!(db, "CREATE (:A {k: 1})-[:R]->(:B {k: 2})")
      Glider.run!(db, "MATCH (b:Before) DELETE b")
      {:ok, now} = Glider.revision(db)

      assert {:ok, %Slice{changes: changes, after: nil, complete_up_to: ^now}} =
               Changes.since(db, rev)

      [before] =
        Glider.all(db, "MATCH (a:A) RETURN id(a)") |> List.flatten() |> Enum.map(&(&1 - 1))

      assert [%Change{kind: :node, id: ^before, change: :drop} | _] = changes
      assert length(ids(changes, :node)) == 3
      assert length(ids(changes, :edge)) == 1
      assert length(ids(changes, :adjacency)) == 2
      assert Enum.all?(changes, &(&1.revision > rev and &1.revision <= now))

      assert Enum.map(changes, & &1.kind) |> Enum.chunk_by(& &1) |> Enum.map(&hd/1) == [
               :node,
               :edge,
               :adjacency
             ]

      assert ids(changes, :node) == Enum.sort(ids(changes, :node))

      # only what is asked for
      assert {:ok, %Slice{changes: edges}} = Changes.since(db, rev, kinds: [:edge])
      assert Enum.all?(edges, &(&1.kind == :edge))
    end

    test "nothing rolled back appears" do
      db = journaled()
      {:ok, rev} = Glider.revision(db)

      {:error, _} =
        Glider.transaction(db, fn ->
          Glider.run!(db, "CREATE (:Gone)")
          Glider.rollback(db, :no)
        end)

      {:error, _} =
        Glider.transaction(db, fn ->
          Glider.run(db, "CREATE (:Gone)") && Glider.run(db, "MATCH ((")
        end)

      assert {:ok, %Slice{changes: []}} = Changes.since(db, rev)
    end

    test "slices continue with after: and together are the whole answer" do
      db = journaled()
      {:ok, rev} = Glider.revision(db)
      for i <- 1..7, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)

      {:ok, %Slice{changes: whole, after: nil}} = Changes.since(db, rev)

      sliced =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            {:ok, %Slice{changes: changes, after: next}} =
              Changes.since(db, rev, limit: 3, after: cursor)

            assert length(changes) <= 3
            {changes, next || :done}
        end)
        |> Enum.concat()

      assert sliced == whole
      assert length(whole) == 7
    end

    test "the stream fetches slices lazily and gives the same changes" do
      db = journaled()
      {:ok, rev} = Glider.revision(db)
      for i <- 1..5, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)
      {:ok, %Slice{changes: whole}} = Changes.since(db, rev)

      stream = Changes.stream(db, rev, limit: 2)
      # nothing runs until it is consumed: a write now is still seen
      Glider.run!(db, "CREATE (:Late)")
      all = Enum.to_list(stream)
      assert Enum.take(all, 5) == whole
      assert length(all) == 6
      assert Enum.take(stream, 1) == [hd(whole)]
    end
  end

  describe "cannot answer is never nothing changed" do
    test "before the install: a distinct error carrying the oldest answerable revision" do
      {:ok, db} = Glider.open()
      Glider.run!(db, "CREATE (:A)")
      {:ok, before} = Glider.revision(db)
      :ok = Changes.install(db)
      {:ok, %Status{oldest: oldest, why: :installed}} = Changes.status(db)
      assert oldest >= before

      result = Changes.since(db, 0)

      assert {:error,
              %Unanswerable{revision: 0, oldest: ^oldest, reason: :below_oldest, why: :installed} =
                e} =
               result

      assert e.message =~ "cannot answer for revision 0"
      assert Exception.message(e) =~ "#{oldest}"
      # the shapes a caller writes for "nothing changed" do not match it
      refute match?({:ok, _}, result)
      refute match?({:ok, %Slice{changes: []}}, result)

      # and from the oldest revision on, it answers
      assert {:ok, %Slice{}} = Changes.since(db, oldest)
    end

    test "the stream raises the same error when it is first run, never yielding an empty list" do
      db = journaled()
      stream = Changes.stream(db, 0)
      e = assert_raise Unanswerable, fn -> Enum.to_list(stream) end
      assert e.reason == :below_oldest and is_integer(e.oldest)
      assert_raise Unanswerable, fn -> Enum.count(stream) end
      assert_raise Unanswerable, fn -> Enum.take(stream, 1) end
    end

    test "after release: the floor rises and says why" do
      db = journaled()
      {:ok, r1} = Glider.revision(db)
      Glider.run!(db, "CREATE (:A)")
      {:ok, r2} = Glider.revision(db)
      Glider.run!(db, "CREATE (:B)")

      assert {:ok, %{released: 1, more: false}} = Changes.release(db, r2)
      assert {:error, %Unanswerable{oldest: ^r2, why: :released}} = Changes.since(db, r1)
      assert {:ok, %Slice{changes: [%Change{kind: :node}]}} = Changes.since(db, r2)
    end

    test "past the cap: the oldest changes are forgotten and asking for them is refused" do
      db = journaled(cap: 64)
      {:ok, %Status{cap: 64}} = Changes.status(db)
      {:ok, rev} = Glider.revision(db)
      for i <- 1..200, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)

      assert {:error, %Unanswerable{reason: :below_oldest, why: :cap, oldest: oldest}} =
               Changes.since(db, rev)

      assert oldest > rev
      {:ok, %Status{entries: entries}} = Changes.status(db)
      assert entries <= 64
    end

    test "after CLEAR, and for a revision this database has not reached" do
      db = journaled()
      {:ok, rev} = Glider.revision(db)
      Glider.run!(db, "CLEAR")
      assert {:error, %Unanswerable{why: :cleared}} = Changes.since(db, rev)

      {:ok, now} = Glider.revision(db)

      assert {:error, %Unanswerable{reason: :ahead, revision: r}} =
               Changes.since(db, now + 1_000_000)

      assert r == now + 1_000_000
    end

    test "a journal that is not installed is a plain error, not an empty answer" do
      {:ok, db} = Glider.open()
      assert {:error, reason} = Changes.since(db, 0)
      assert is_binary(reason) and reason =~ "CREATE EXTENSION changes"
      assert_raise Glider.Error, fn -> Enum.to_list(Changes.stream(db, 0)) end
    end
  end

  describe "status, release, cap" do
    test "status reports oldest, why, entries, bytes, cap and revision" do
      db = journaled()
      Glider.run!(db, "CREATE (:A)")
      {:ok, rev} = Glider.revision(db)

      assert {:ok, %Status{why: :installed, entries: 1, cap: 1_000_000, revision: ^rev, bytes: b}} =
               Changes.status(db)

      assert b > 0
    end

    test "release in slices with limit:" do
      db = journaled()
      for i <- 1..5, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)
      {:ok, rev} = Glider.revision(db)
      assert {:ok, %{released: 2, more: true}} = Changes.release(db, rev, limit: 2)
      assert {:ok, %{released: 3, more: false}} = Changes.release(db, rev)
      assert {:ok, %Status{entries: 0, oldest: ^rev}} = Changes.status(db)
    end

    test "cap lowers the bound and forgets at once; install with cap: sets it from the start" do
      db = journaled()
      for i <- 1..100, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)
      assert {:ok, forgotten} = Changes.cap(db, 64)
      assert forgotten > 0
      assert {:ok, %Status{cap: 64}} = Changes.status(db)
      assert {:error, reason} = Changes.cap(db, 3)
      assert reason =~ "at least 64"
    end

    test "an install whose cap is refused installs nothing" do
      {:ok, db} = Glider.open()
      assert {:error, _} = Changes.install(db, cap: 1)
      {:ok, exts} = Glider.extensions(db)
      assert %{installed: nil} = Enum.find(exts, &(&1.name == "changes"))
    end

    test "unknown options are errors that name them" do
      db = journaled()

      assert {:error, "Glider.Changes.since/3 has no option :revision"} =
               Changes.since(db, 0, revision: 1)

      assert {:error, "Glider.Changes.install/2 has no option :entries"} =
               Changes.install(db, entries: 64)

      assert {:error, "Glider.Changes.status/2 has no option :x"} = Changes.status(db, x: 1)
      assert_raise ArgumentError, fn -> Changes.stream(db, 0, after: "node:1") end
    end
  end
end
