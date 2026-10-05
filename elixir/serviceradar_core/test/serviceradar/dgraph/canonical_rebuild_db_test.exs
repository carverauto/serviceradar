defmodule ServiceRadar.Dgraph.CanonicalRebuildDbTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Dgraph.CanonicalRebuild

  @moduletag :integration

  # Synthetic canonical edges; only their identity matters to the rebuild.
  defp edges(count, prefix \\ "host") do
    for index <- 1..count do
      %{
        source: "sr:#{prefix}#{index}.example.com",
        target: "sr:#{prefix}#{index + 1}.example.com",
        kind: :canonical_topology
      }
    end
  end

  # Fake Dgraph operations: record every chunk, optionally fail the upsert of
  # one chunk once, and report a fixed set of stored-but-unwanted keys.
  defp ops(test_pid, opts \\ []) do
    fail_chunk_once = Keyword.get(opts, :fail_chunk_once)
    stale = Keyword.get(opts, :stale, [])
    failed = :counters.new(1, [])

    %{
      upsert: fn chunk ->
        first = hd(chunk)
        send(test_pid, {:upsert_chunk, first})

        if fail_chunk_once && first == fail_chunk_once && :counters.get(failed, 1) == 0 do
          :counters.add(failed, 1, 1)
          {:error, "synthetic chunk failure"}
        else
          :ok
        end
      end,
      stale_keys: fn _desired ->
        send(test_pid, :stale_keys_read)
        {:ok, stale}
      end,
      delete: fn keys ->
        send(test_pid, {:delete_chunk, keys})
        :ok
      end
    }
  end

  defp received_upsert_chunks do
    receive do
      {:upsert_chunk, first} -> [first | received_upsert_chunks()]
    after
      0 -> []
    end
  end

  test "an interrupted rebuild resumes from its cursor instead of starting over" do
    desired = edges(1_000)
    ordered = Enum.sort_by(desired, &:erlang.term_to_binary(&1, [:deterministic]))
    chunk_firsts = ordered |> Enum.chunk_every(100) |> Enum.map(&hd/1)
    failing = Enum.at(chunk_firsts, 4)
    ops = ops(self(), fail_chunk_once: failing)

    assert {:error, "synthetic chunk failure"} =
             CanonicalRebuild.run(desired, ops, chunk_size: 100)

    assert received_upsert_chunks() == Enum.take(chunk_firsts, 5)
    assert {:ok, %{phase: "upsert", next_chunk: 4}} = CanonicalRebuild.cursor()

    # The retry starts at the chunk that failed; chunks 0..3 are not rewritten.
    assert :ok = CanonicalRebuild.run(Enum.shuffle(desired), ops, chunk_size: 100)
    assert received_upsert_chunks() == Enum.drop(chunk_firsts, 4)
    assert_received :stale_keys_read
    assert {:ok, nil} = CanonicalRebuild.cursor()
  end

  test "a changed desired set invalidates the cursor and restarts from the first chunk" do
    first_set = edges(500)

    first_chunks =
      first_set
      |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))
      |> Enum.chunk_every(100)

    failing = first_chunks |> Enum.at(3) |> hd()

    assert {:error, _} =
             CanonicalRebuild.run(first_set, ops(self(), fail_chunk_once: failing),
               chunk_size: 100
             )

    assert {:ok, %{next_chunk: 3}} = CanonicalRebuild.cursor()
    _ = received_upsert_chunks()

    changed = edges(500, "node")

    changed_firsts =
      changed
      |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))
      |> Enum.chunk_every(100)
      |> Enum.map(&hd/1)

    assert :ok = CanonicalRebuild.run(changed, ops(self()), chunk_size: 100)
    assert received_upsert_chunks() == changed_firsts
    assert {:ok, nil} = CanonicalRebuild.cursor()
  end

  test "a rebuild over a large graph deletes every stale edge, in bounded chunks" do
    stale =
      for index <- 1..2_000,
          do: "CANONICAL_TOPOLOGY|sr:gone#{index}.example.com|sr:gone#{index + 1}.example.com||"

    assert :ok = CanonicalRebuild.run(edges(3_000), ops(self(), stale: stale))

    deleted = Enum.flat_map(received_delete_chunks(), & &1)
    assert Enum.sort(deleted) == Enum.sort(stale)
    assert length(received_upsert_chunks()) == 15
    assert {:ok, nil} = CanonicalRebuild.cursor()
  end

  test "a failed delete chunk resumes in the delete phase without rewriting upserts" do
    stale =
      for index <- 1..300,
          do: "CANONICAL_TOPOLOGY|sr:old#{index}.example.com|sr:old#{index}.example.org||"

    test_pid = self()
    attempts = :counters.new(1, [])

    flaky = %{
      ops(test_pid, stale: stale)
      | delete: fn keys ->
          :counters.add(attempts, 1, 1)
          send(test_pid, {:delete_chunk, keys})
          if :counters.get(attempts, 1) == 2, do: {:error, "synthetic delete failure"}, else: :ok
        end
    }

    desired = edges(250)
    assert {:error, "synthetic delete failure"} = CanonicalRebuild.run(desired, flaky)
    assert {:ok, %{phase: "delete"}} = CanonicalRebuild.cursor()
    _ = received_upsert_chunks()

    assert :ok = CanonicalRebuild.run(desired, flaky)
    assert received_upsert_chunks() == []
    assert {:ok, nil} = CanonicalRebuild.cursor()
  end

  defp received_delete_chunks do
    receive do
      {:delete_chunk, keys} -> [keys | received_delete_chunks()]
    after
      0 -> []
    end
  end
end
