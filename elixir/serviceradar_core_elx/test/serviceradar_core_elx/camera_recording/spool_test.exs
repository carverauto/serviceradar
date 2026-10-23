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

  test "a create whose init path exceeds the limit removes only that directory", %{root: root} do
    {:ok, existing} = Spool.create(root, @identity, "init", @limits)
    existing_dir = Spool.snapshot(existing).directory
    block_id = Path.basename(existing_dir)
    existing_bytes = directory_bytes(existing_dir)

    probe = Path.join(root, "probe")
    max_len = longest_directory(probe)

    long_root =
      path_of_length(Path.join(root, "long"), max_len - byte_size(block_id) - 9)

    File.mkdir_p!(long_root)
    File.chmod!(long_root, 0o700)
    kept = Path.join(long_root, "kept")
    File.mkdir!(kept)
    File.write!(Path.join(kept, "note"), "keep")
    block_dir = Path.join(long_root, block_id)
    assert byte_size(block_dir) == max_len - 8
    assert :ok = File.mkdir(block_dir)

    assert {:ok, journal_fd} =
             :file.open(String.to_charlist(Path.join(block_dir, "journal")), [
               :raw,
               :binary,
               :write,
               :exclusive
             ])

    :file.close(journal_fd)
    File.rm!(Path.join(block_dir, "journal"))

    assert {:error, :enametoolong} =
             :file.open(String.to_charlist(Path.join(block_dir, "init.mp4")), [
               :raw,
               :binary,
               :write,
               :exclusive
             ])

    assert :ok = File.rmdir(block_dir)

    assert {:error, :enametoolong} = Spool.create(long_root, @identity, "init", @limits)
    refute File.exists?(block_dir)
    assert File.ls!(long_root) == ["kept"]
    assert {:error, :enametoolong} = Spool.create(long_root, @identity, "init", @limits)
    refute File.exists?(block_dir)
    assert File.read!(Path.join(kept, "note")) == "keep"
    assert directory_bytes(existing_dir) == existing_bytes
    assert {:ok, _recovered} = Spool.recover(existing_dir, @identity, @limits)
  end

  test "a create whose journal path exceeds the limit removes only that directory", %{root: root} do
    {:ok, existing} = Spool.create(root, @identity, "init", @limits)
    existing_dir = Spool.snapshot(existing).directory
    block_id = Path.basename(existing_dir)
    existing_bytes = directory_bytes(existing_dir)
    max_len = longest_directory(Path.join(root, "probe"))

    short_root =
      path_of_length(Path.join(root, "short"), max_len - byte_size(block_id) - 8)

    File.mkdir_p!(short_root)
    File.chmod!(short_root, 0o700)
    short_kept = Path.join(short_root, "kept")
    File.mkdir!(short_kept)
    File.write!(Path.join(short_kept, "note"), "keep")
    short_block = Path.join(short_root, block_id)
    assert byte_size(short_block) == max_len - 7
    assert :ok = File.mkdir(short_block)

    assert {:error, :enametoolong} =
             :file.open(String.to_charlist(Path.join(short_block, "journal")), [
               :raw,
               :binary,
               :write,
               :exclusive
             ])

    assert :ok = File.rmdir(short_block)
    assert {:error, :enametoolong} = Spool.create(short_root, @identity, "init", @limits)
    refute File.exists?(short_block)
    assert File.ls!(short_root) == ["kept"]
    assert {:error, :enametoolong} = Spool.create(short_root, @identity, "init", @limits)
    refute File.exists?(short_block)
    assert File.read!(Path.join(short_kept, "note")) == "keep"
    assert directory_bytes(existing_dir) == existing_bytes

    {:ok, retried} = Spool.create(root, %{@identity | block_sequence: 9}, "init", @limits)
    assert {:ok, "init"} = Spool.read_init(Spool.snapshot(retried))
  end

  test "create leaves an existing block directory unchanged", %{root: root} do
    {:ok, recoverable} = Spool.create(root, @identity, "init", @limits)
    recoverable_dir = Spool.snapshot(recoverable).directory
    recoverable_bytes = directory_bytes(recoverable_dir)
    assert {:error, :eexist} = Spool.create(root, @identity, "init", @limits)
    assert directory_bytes(recoverable_dir) == recoverable_bytes
    assert {:ok, recovered} = Spool.recover(recoverable_dir, @identity, @limits)
    assert Spool.snapshot(recovered).directory == recoverable_dir

    incomplete_identity = %{@identity | block_sequence: 7}
    {:ok, incomplete} = Spool.create(root, incomplete_identity, "init", @limits)
    incomplete_dir = Spool.snapshot(incomplete).directory
    File.rm_rf!(incomplete_dir)
    File.mkdir!(incomplete_dir)
    assert {:error, :eexist} = Spool.create(root, incomplete_identity, "init", @limits)
    assert File.ls!(incomplete_dir) == []
    assert {:error, _} = Spool.recover(incomplete_dir, incomplete_identity, @limits)
    File.rm_rf!(incomplete_dir)
    assert {:ok, _replaced} = Spool.create(root, incomplete_identity, "init", @limits)

    corrupt_identity = %{@identity | block_sequence: 8}
    {:ok, corrupt} = Spool.create(root, corrupt_identity, "init", @limits)
    corrupt_dir = Spool.snapshot(corrupt).directory
    journal_path = Path.join(corrupt_dir, "journal")
    journal = File.read!(journal_path)
    <<prefix::binary-size(byte_size(journal) - 1), last>> = journal
    File.write!(journal_path, <<prefix::binary, Bitwise.bxor(last, 1)>>)
    corrupt_bytes = directory_bytes(corrupt_dir)
    assert {:error, :eexist} = Spool.create(root, corrupt_identity, "init", @limits)
    assert directory_bytes(corrupt_dir) == corrupt_bytes

    assert {:error, reason} = Spool.recover(corrupt_dir, corrupt_identity, @limits)
    assert reason in [:invalid_journal_record, :journal_digest_mismatch]
    assert directory_bytes(corrupt_dir) == corrupt_bytes
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

  defp directory_bytes(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Map.new(fn name -> {name, File.read!(Path.join(directory, name))} end)
  end

  defp longest_directory(anchor) do
    File.mkdir_p!(anchor)
    deepen(anchor)
  end

  defp deepen(path) do
    next = Path.join(path, String.duplicate("p", 200))

    case File.mkdir(next) do
      :ok -> deepen(next)
      {:error, :enametoolong} -> longest_child(path)
      {:error, reason} -> flunk("directory length probe failed: #{inspect(reason)}")
    end
  end

  defp longest_child(parent) do
    Enum.reduce(1..255, byte_size(parent), fn len, best ->
      child = Path.join(parent, String.duplicate("c", len))

      case File.mkdir(child) do
        :ok ->
          File.rmdir!(child)
          byte_size(child)

        {:error, :enametoolong} ->
          best

        {:error, reason} ->
          flunk("directory length probe failed: #{inspect(reason)}")
      end
    end)
  end

  defp path_of_length(anchor, target) when is_integer(target) do
    File.mkdir_p!(anchor)

    if target <= byte_size(anchor) do
      flunk("path limit leaves no room under #{anchor}")
    else
      extend_path(anchor, target)
    end
  end

  defp extend_path(path, target) when byte_size(path) == target, do: path

  defp extend_path(path, target) when byte_size(path) < target do
    take = min(target - byte_size(path) - 1, 200)

    if take < 1 do
      flunk("path limit cannot fit another component")
    else
      extend_path(Path.join(path, String.duplicate("d", take)), target)
    end
  end
end
