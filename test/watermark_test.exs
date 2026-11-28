defmodule Glider.WatermarkTest do
  # Answers in slices read as data (the end row), and the two losses the
  # engine's review found, reproduced through Elixir.
  use ExUnit.Case, async: true

  alias Glider.Changes
  alias Glider.Changes.{Change, Slice, Unanswerable}
  alias Glider.Procedure

  defp journaled(path \\ nil) do
    {:ok, db} = if path, do: Glider.open(path), else: Glider.open()
    :ok = Changes.install(db)
    Glider.run!(db, "CREATE (:Seed)")
    db
  end

  defp node_ids(changes), do: for(%Change{kind: :node, id: id} <- changes, do: id)

  defp all(db, rev, opts) do
    Stream.unfold(nil, fn
      :done ->
        nil

      cursor ->
        {:ok, %Slice{} = s} = Changes.since(db, rev, [after: cursor] ++ opts)
        {s, if(s.complete, do: :done, else: s.after)}
    end)
    |> Enum.to_list()
  end

  @tag :tmp_dir
  test "a watermark taken inside a transaction that rolls back and is overtaken loses nothing",
       %{tmp_dir: dir} do
    db = journaled(Path.join(dir, "w.gldb"))
    {:ok, rev0} = Glider.revision(db)

    {:error, :undo} =
      Glider.transaction(db, fn ->
        for i <- 1..20, do: Glider.run!(db, "CREATE (:Pending {i: $i})", i: i)
        # answered inside the transaction, about committed changes only
        assert {:ok, %Slice{changes: [], complete: true, complete_up_to: kept}} =
                 Changes.since(db, rev0)

        assert Enum.to_list(Changes.stream(db, rev0)) == []
        send(self(), {:kept, kept})
        # and the transaction carries on
        assert {:ok, 1} = Glider.run(db, "CREATE (:StillWritable)")
        Glider.rollback(db, :undo)
      end)

    assert_received {:kept, kept}
    # the watermark was the committed revision, not a pending position
    assert kept == rev0

    # overtaken: later commits run past the rolled-back positions
    for i <- 1..40, do: Glider.run!(db, "CREATE (:Later {i: $i})", i: i)
    {:ok, now} = Glider.revision(db)

    {:ok, %Slice{changes: changes, complete: true, complete_up_to: up_to}} =
      Changes.since(db, kept)

    assert up_to == now
    assert length(node_ids(changes)) == 40
    assert length(Enum.to_list(Changes.stream(db, kept, kinds: [:node]))) == 40
  end

  test "a commit between two slices to an id already passed is listed from the watermark" do
    db = journaled()
    {:ok, rev0} = Glider.revision(db)
    for i <- 1..5, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)

    {:ok, %Slice{changes: first, complete: false, after: cursor, complete_up_to: w1}} =
      Changes.since(db, rev0, kinds: [:node], limit: 2)

    [passed | _] = node_ids(first)
    # committed between the slices, to an id the cursor has passed
    Glider.run!(db, "MATCH (n) WHERE id(n) = $id SET n.touched = true", id: passed)

    rest = all(db, rev0, kinds: [:node], limit: 2, after: cursor)
    last = List.last(rest)
    assert last.complete
    # the answer is complete up to its first slice's watermark, not past it
    assert last.complete_up_to == w1
    assert length(node_ids(first ++ Enum.flat_map(rest, & &1.changes))) == 5

    # so the next question from it lists the change
    {:ok, %Slice{changes: again}} = Changes.since(db, last.complete_up_to, kinds: [:node])
    assert passed in node_ids(again)
  end

  test "the stream follows the sealed cursor and the next question finds a change it passed" do
    db = journaled()
    {:ok, rev0} = Glider.revision(db)
    for i <- 1..6, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)
    {:ok, before} = Glider.revision(db)

    seen =
      db
      |> Changes.stream(rev0, kinds: [:node], limit: 2)
      |> Stream.with_index()
      |> Enum.map(fn {%Change{id: id}, i} ->
        # the second slice is not fetched yet
        if i == 0, do: Glider.run!(db, "MATCH (n) WHERE id(n) = $id SET n.x = 1", id: id)
        id
      end)

    assert length(seen) == 6
    {:ok, %Slice{changes: again}} = Changes.since(db, before, kinds: [:node])
    assert node_ids(again) == [hd(seen)]
  end

  test "a stream raises Unanswerable when the journal stops answering between slices" do
    db = journaled()
    {:ok, rev0} = Glider.revision(db)
    for i <- 1..6, do: Glider.run!(db, "CREATE (:N {i: $i})", i: i)

    e =
      assert_raise Unanswerable, fn ->
        db
        |> Changes.stream(rev0, kinds: [:node], limit: 2)
        |> Stream.with_index()
        |> Enum.each(fn {_, i} ->
          if i == 0 do
            {:ok, now} = Glider.revision(db)
            {:ok, %{released: n}} = Changes.release(db, now)
            assert n > 0
          end
        end)
      end

    assert e.reason == :released and e.revision == rev0 and is_integer(e.oldest)
  end

  test "a cursor is passed back as given and is good only for its question" do
    db = journaled()
    {:ok, rev0} = Glider.revision(db)
    Glider.run!(db, "CREATE (:A)-[:R]->(:B)")

    {:ok, %Slice{after: cursor}} = Changes.since(db, rev0, kinds: [:node], limit: 1)
    assert is_binary(cursor)
    assert {:ok, %Slice{}} = Changes.since(db, rev0, kinds: [:node], limit: 1, after: cursor)
    assert {:error, reason} = Changes.since(db, rev0, kinds: [:edge], after: cursor)
    assert is_binary(reason)
  end

  test "an answer without a well-formed end row is an error, never a complete answer" do
    no_column = %{columns: ["revision"], rows: [[1]], message: nil}
    assert {:error, _} = Procedure.split_end(no_column, "x")

    no_row = %{columns: ["a", "slice"], rows: [], message: nil}
    assert {:error, _} = Procedure.split_end(no_row, "x")

    not_end = %{columns: ["a", "slice"], rows: [[1, nil]], message: nil}
    assert {:error, _} = Procedure.split_end(not_end, "x")

    unknown =
      ~s({"answered":false,"complete":false,"next":null,"reason":"gremlins","oldest":null,"watermark":null})

    assert {:error, msg} = Procedure.split_end(%{columns: ["slice"], rows: [[unknown]]}, "x")
    assert msg =~ "gremlins"

    # a slice that is neither complete nor says where to go on ends nothing
    stuck = fn _ -> {:ok, [1], %{answered: true, complete: false, next: nil}} end

    stream =
      Procedure.stream(stuck, fn _ -> raise "cannot" end, &raise(Glider.Error, message: &1))

    assert_raise Glider.Error, fn -> Enum.to_list(stream) end
  end

  test "nothing about a slice is read from the message" do
    for file <- ~w(lib/glider/changes.ex lib/glider/check.ex lib/glider/procedure.ex) do
      source = File.read!(file)
      refute source =~ "Regex", file
      refute source =~ "String.contains?", file
      refute source =~ ~r/message\s*=~/, file
    end
  end
end
