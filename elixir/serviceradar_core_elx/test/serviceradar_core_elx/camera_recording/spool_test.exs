defmodule ServiceRadarCoreElx.CameraRecording.SpoolTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.Spool

  @identity %{
    source_id: "00000000-0000-4000-8000-000000000021",
    profile: "synthetic-baseline",
    recorder_epoch: 4,
    block_sequence: 0,
    clock: %{clock_epoch: "synthetic-clock-1", timebase: 90_000, dts_source: :pts_no_reordering, utc_mapping: :unknown}
  }
  @limits %{
    max_init_bytes: 128,
    max_fragment_bytes: 64,
    max_block_bytes: 128,
    max_fragments: 2,
    max_fragment_duration_ns: 2_000_000_000
  }

  setup do
    root = Path.join(System.tmp_dir!(), "recording-spool-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # Invented bytes exercise storage only; the packaging suite owns decodable media.
  test "committed byte map survives writer exit and readers do not depend on its process", %{root: root} do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, spool} = Spool.create(root, @identity, "synthetic-init", @limits)
        before = Spool.snapshot(spool)
        {:ok, spool, first} = Spool.append(spool, "fragment-one", timing(0))
        {:ok, spool, second} = Spool.append(spool, "fragment-two", timing(2))
        send(parent, {:written, before, Spool.snapshot(spool), first, second})
      end)

    assert_receive {:written, before, snapshot, first, second}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert {:error, :not_readable} = Spool.read_fragment(before, 0)
    assert first["offset"] == 0
    assert second["offset"] == byte_size("fragment-one")
    assert snapshot.high_water == byte_size("fragment-onefragment-two")
    assert snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert {:ok, "fragment-two"} = fn -> Spool.read_fragment(snapshot, 1) end |> Task.async() |> Task.await()
    assert {:ok, "synthetic-init"} = Spool.read_init(snapshot)
    assert {:ok, recovered} = Spool.recover(snapshot.directory, @identity, @limits)
    assert Spool.snapshot(recovered) == snapshot
  end

  test "recovery discards an incomplete journal record and uncommitted media before resuming", %{root: root} do
    {:ok, spool} = Spool.create(root, @identity, "init", @limits)
    {:ok, spool, _} = Spool.append(spool, "committed", timing(0))
    snapshot = Spool.snapshot(spool)
    media_path = Path.join(snapshot.directory, "media.m4s")
    journal_path = Path.join(snapshot.directory, "journal")
    committed_journal = File.read!(journal_path)

    # Crash after media write and during the next framed journal write.
    File.write!(media_path, "uncommitted", [:append])
    File.write!(journal_path, <<200::32, "partial">>, [:append])
    assert {:error, :stale_spool} = Spool.append(spool, "next", timing(2))
    assert {:ok, recovered} = Spool.recover(snapshot.directory, @identity, @limits)
    assert File.read!(media_path) == "committed"
    assert File.read!(journal_path) == committed_journal
    assert {:ok, resumed, _} = Spool.append(recovered, "next", timing(2))
    assert {:ok, "next"} = Spool.read_fragment(Spool.snapshot(resumed), 1)
  end

  test "complete corrupt journal or committed media is rejected without truncating evidence", %{root: root} do
    for {corruption, sequence} <- Enum.with_index([:journal, :media, :truncated_media]) do
      identity = %{@identity | block_sequence: sequence}
      {:ok, spool} = Spool.create(root, identity, "init", @limits)
      {:ok, spool, _} = Spool.append(spool, "committed", timing(0))
      snapshot = Spool.snapshot(spool)
      media_path = Path.join(snapshot.directory, "media.m4s")
      journal_path = Path.join(snapshot.directory, "journal")

      case corruption do
        :journal ->
          journal = File.read!(journal_path)
          <<prefix::binary-size(byte_size(journal) - 1), last>> = journal
          File.write!(journal_path, <<prefix::binary, Bitwise.bxor(last, 1)>>)

        :media ->
          File.write!(media_path, "corrupted")

        :truncated_media ->
          File.write!(media_path, "short")
      end

      journal_before = File.read!(journal_path)
      media_before = File.read!(media_path)
      assert {:error, reason} = Spool.recover(snapshot.directory, identity, @limits)
      assert reason in [:invalid_journal_record, :media_digest_mismatch, :truncated_media]
      assert File.read!(journal_path) == journal_before
      assert File.read!(media_path) == media_before
    end
  end

  test "seal survives recovery, verifies the whole block, and rejects stale writers", %{root: root} do
    {:ok, spool} = Spool.create(root, @identity, "init", @limits)
    assert {:error, :empty_block} = Spool.seal(spool)
    {:ok, appended, _} = Spool.append(spool, "one", timing(0))
    {:ok, sealed} = Spool.seal(appended)
    snapshot = Spool.snapshot(sealed)
    assert snapshot.sealed?
    assert snapshot.sha256 == Base.encode16(:crypto.hash(:sha256, "one"), case: :lower)
    assert {:error, :sealed} = Spool.append(sealed, "two", timing(2))
    assert {:error, :stale_spool} = Spool.append(appended, "two", timing(2))
    assert {:ok, recovered} = Spool.recover(snapshot.directory, @identity, @limits)
    assert Spool.snapshot(recovered) == snapshot
    assert {:error, :sealed} = Spool.append(recovered, "two", timing(2))
  end

  test "fragment bytes, duration, continuity, count and packed bytes have independent limits", %{root: root} do
    {:ok, spool} = Spool.create(root, @identity, "init", @limits)
    assert {:error, :fragment_too_large} = Spool.append(spool, :binary.copy(<<1>>, 65), timing(0))
    assert {:error, :fragment_too_long} = Spool.append(spool, "ok", %{start_ns: 0, duration_ns: 2_000_000_001})

    assert {:error, :invalid_timing} =
             Spool.append(spool, "ok", %{start_ns: 9_223_372_036_854_775_807, duration_ns: 1})

    {:ok, spool, _} = Spool.append(spool, "ok", timing(0))
    assert {:error, :discontinuity} = Spool.append(spool, "gap", timing(4))
    {:ok, spool, _} = Spool.append(spool, "ok", timing(2))
    assert {:error, :block_full} = Spool.append(spool, "ok", timing(4))
    assert Spool.snapshot(spool).high_water == 4

    {:ok, bytes_spool} = Spool.create(root, %{@identity | block_sequence: 1}, "init", %{@limits | max_block_bytes: 3})
    {:ok, bytes_spool, _} = Spool.append(bytes_spool, "ok", timing(0))
    assert {:error, :block_full} = Spool.append(bytes_spool, "ok", timing(2))
    assert {:ok, sealed} = Spool.seal(bytes_spool)
    assert Spool.snapshot(sealed).high_water == 2
  end

  test "block identity prevents reuse across epochs and recovery fails for the wrong identity", %{root: root} do
    {:ok, first} = Spool.create(root, @identity, "init", @limits)
    assert {:error, :eexist} = Spool.create(root, @identity, "init", @limits)
    revised_clock = %{@identity | clock: %{@identity.clock | clock_epoch: "revised-clock"}}
    assert {:error, :eexist} = Spool.create(root, revised_clock, "init", @limits)
    later_identity = %{@identity | recorder_epoch: 5}
    assert {:ok, later} = Spool.create(root, later_identity, "init", @limits)
    refute Spool.snapshot(first).directory == Spool.snapshot(later).directory

    assert {:error, :identity_or_header_mismatch} =
             Spool.recover(Spool.snapshot(first).directory, later_identity, @limits)

    File.chmod!(root, 0o755)
    assert {:error, :root_not_private} = Spool.create(root, %{@identity | recorder_epoch: 6}, "init", @limits)
  end

  defp timing(seconds), do: %{start_ns: seconds * 1_000_000_000, duration_ns: 2_000_000_000}
end
