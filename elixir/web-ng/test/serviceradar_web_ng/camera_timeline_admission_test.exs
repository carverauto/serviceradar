defmodule ServiceRadarWebNG.CameraTimelineAdmissionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.CameraTimelineAdmission
  alias ServiceRadarWebNG.CameraTimelineReader

  @moduletag :db_free

  test "enforces per-session (default 4) and per-node bounds without queuing" do
    table = CameraTimelineAdmission.new_table(:admission_bounds_test)
    opts = [table: table, max_per_session: 4, max_per_node: 6]

    tokens_s1 =
      for _ <- 1..4 do
        assert {:ok, token} = CameraTimelineAdmission.acquire("user-1", "cam-1", opts)
        token
      end

    # 5th concurrent read on same {user_id, camera_source_id} is refused immediately
    assert CameraTimelineAdmission.acquire("user-1", "cam-1", opts) ==
             {:error, :playback_capacity_exhausted}

    assert CameraTimelineAdmission.counts("user-1", "cam-1", opts) == %{session: 4, node: 4}

    # Another session can take the remaining 2 node-wide slots (total 6)
    assert {:ok, t5} = CameraTimelineAdmission.acquire("user-1", "cam-2", opts)
    assert {:ok, t6} = CameraTimelineAdmission.acquire("user-2", "cam-1", opts)

    # 7th node-wide concurrent read is refused even for a brand-new session
    assert CameraTimelineAdmission.acquire("user-3", "cam-3", opts) ==
             {:error, :playback_capacity_exhausted}

    assert CameraTimelineAdmission.counts("user-3", "cam-3", opts) == %{session: 0, node: 6}

    Enum.each([t5, t6 | tokens_s1], &CameraTimelineAdmission.release/1)

    assert CameraTimelineAdmission.counts("user-1", "cam-1", opts) == %{session: 0, node: 0}
    assert :ets.lookup(table, {:session, "user-1", "cam-1"}) == []
  end

  test "with_slot/4 always releases slots on normal return, exception, and throw" do
    table = CameraTimelineAdmission.new_table(:admission_cleanup_test)
    opts = [table: table, max_per_session: 1, max_per_node: 2]

    assert CameraTimelineAdmission.with_slot("user-a", "cam-a", opts, fn ->
             assert CameraTimelineAdmission.counts("user-a", "cam-a", opts) == %{
                      session: 1,
                      node: 1
                    }

             {:ok, :served}
           end) == {:ok, :served}

    assert_raise RuntimeError, "synthetic reader crash", fn ->
      CameraTimelineAdmission.with_slot("user-a", "cam-a", opts, fn ->
        raise "synthetic reader crash"
      end)
    end

    assert catch_throw(
             CameraTimelineAdmission.with_slot("user-a", "cam-a", opts, fn ->
               throw(:synthetic_abort)
             end)
           ) == :synthetic_abort

    assert CameraTimelineAdmission.counts("user-a", "cam-a", opts) == %{session: 0, node: 0}
    assert :ets.lookup(table, {:session, "user-a", "cam-a"}) == []

    # Slot is immediately reusable after abnormal exits
    assert CameraTimelineAdmission.with_slot("user-a", "cam-a", opts, fn -> :reacquired end) ==
             :reacquired
  end

  test "CameraTimelineReader behaviour seams report unavailable copies and enforce digest + fallback invariants" do
    payload = "synthetic-verified-fragment-payload"
    sha = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    local_plan = %{
      copy: :local,
      entry_id: "33333333-3333-4333-8333-333333333301",
      provisional?: true,
      expected_length: byte_size(payload),
      expected_sha256: sha
    }

    archive_plan = %{
      copy: :archive,
      entry_id: "33333333-3333-4333-8333-333333333301",
      provisional?: false,
      expected_length: byte_size(payload),
      expected_sha256: sha,
      credential_error: nil
    }

    # Without a reader a local copy is unavailable; no archive reader is installed yet (D.2).
    assert CameraTimelineReader.fetch_local(local_plan, 1_000) == {:error, :reader_unavailable}
    assert CameraTimelineReader.fetch_archive(archive_plan, 1_000) == {:error, :archive_reader_not_installed}
    refute CameraTimelineReader.archive_reader_installed?()

    unavailable = %{local: fn _plan, _dl -> {:error, :unavailable} end}

    # A failed local read stays the answer when there is no archive reader to fall back to...
    assert CameraTimelineReader.execute_plans([local_plan, archive_plan], :auto, readers: unavailable) ==
             {:error, :reader_unavailable}

    # ...and archive-only footage reports that archive playback is not available.
    assert CameraTimelineReader.execute_plans([archive_plan], :auto) == {:error, :archive_reader_not_installed}
    assert CameraTimelineReader.execute_plans([archive_plan], :archive) == {:error, :archive_reader_not_installed}

    # Provisional local copy returns "local; provisional" header on digest match
    assert {:ok, %{copy: :local, provisional?: true, copy_header: "local; provisional"}} =
             CameraTimelineReader.execute_plans([local_plan, archive_plan], :auto,
               readers: %{local: fn _plan, _dl -> {:ok, payload} end}
             )

    # Corrupt local bytes trigger mark_local_integrity_failure and fall back to verified archive
    test_pid = self()

    assert {:ok, %{copy: :archive, copy_header: "archive", bytes: ^payload}} =
             CameraTimelineReader.execute_plans([local_plan, archive_plan], :auto,
               readers: %{
                 local: fn _plan, _dl -> {:ok, "corrupted-bytes"} end,
                 archive: fn _plan, _dl -> {:ok, payload} end
               },
               mark_local_integrity_failure: fn entry_id ->
                 send(test_pid, {:marked_missing, entry_id})
                 {:ok, %{entry: %{}, archive_verified?: true}}
               end
             )

    assert_received {:marked_missing, "33333333-3333-4333-8333-333333333301"}

    # Forced local never falls back even when archive_plan is passed
    assert CameraTimelineReader.execute_plans([local_plan, archive_plan], :local,
             readers: %{
               local: fn _plan, _dl -> {:error, :unavailable} end,
               archive: fn _plan, _dl -> {:ok, payload} end
             }
           ) == {:error, :reader_unavailable}
  end
end
