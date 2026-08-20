defmodule ServiceRadar.Inventory.SyncIngestorActiveIpCrossHandoffTest do
  @moduledoc """
  Unboxed concurrent cross-handoff coverage for active-IP release locking.

  Shared sandbox cannot model independent transaction locks. This suite runs
  under `@tag sandbox: :unboxed` so two ingest tasks take real FOR UPDATE /
  insert_all locks — the interaction that previously deadlocked under
  concurrent opposite-order handoffs (#4796 / PR #4898).
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed

  # Large enough to exercise lock ordering across many pairs without making CI
  # pathologically slow. The original independent reproduction used 120 pairs.
  @pair_count 48

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_active_ip_cross_handoff_test)
    {:ok, actor: actor}
  end

  test "concurrent opposite-order IP swaps succeed without dual holders", %{actor: actor} do
    pairs =
      for i <- 1..@pair_count do
        a_id = "xhandoff-a-#{i}-#{System.unique_integer([:positive])}"
        b_id = "xhandoff-b-#{i}-#{System.unique_integer([:positive])}"
        ip_a = unique_test_ip()
        ip_b = unique_test_ip()

        assert :ok =
                 SyncIngestor.ingest_updates(
                   [
                     integration_update(a_id, ip_a, "a-#{i}"),
                     integration_update(b_id, ip_b, "b-#{i}")
                   ],
                   actor: actor
                 )

        a_uid = device_uid_for_integration!(a_id, actor)
        b_uid = device_uid_for_integration!(b_id, actor)

        %{
          a_id: a_id,
          b_id: b_id,
          a_uid: a_uid,
          b_uid: b_uid,
          ip_a: ip_a,
          ip_b: ip_b
        }
      end

    uids = Enum.flat_map(pairs, fn p -> [p.a_uid, p.b_uid] end)

    on_exit(fn ->
      cleanup_devices!(uids)
    end)

    # Task 1 swaps A↔B in ascending pair order; task 2 swaps in reverse.
    # That is the lock-order pattern that previously 40P01'd when only release
    # owners were locked before insert_all.
    forward_updates =
      Enum.flat_map(pairs, fn p ->
        [
          integration_update(p.a_id, p.ip_b, "a-swap-fwd"),
          integration_update(p.b_id, p.ip_a, "b-swap-fwd")
        ]
      end)

    reverse_updates =
      pairs
      |> Enum.reverse()
      |> Enum.flat_map(fn p ->
        [
          integration_update(p.a_id, p.ip_b, "a-swap-rev"),
          integration_update(p.b_id, p.ip_a, "b-swap-rev")
        ]
      end)

    task_fwd =
      Task.async(fn ->
        SyncIngestor.ingest_updates(forward_updates, actor: actor)
      end)

    task_rev =
      Task.async(fn ->
        SyncIngestor.ingest_updates(reverse_updates, actor: actor)
      end)

    assert :ok = Task.await(task_fwd, 120_000)
    assert :ok = Task.await(task_rev, 120_000)

    for p <- pairs do
      {:ok, a} = Device.get_by_uid(p.a_uid, false, actor: actor)
      {:ok, b} = Device.get_by_uid(p.b_uid, false, actor: actor)

      # Both writers applied the same final swap; no dual holders on either IP.
      assert a.ip == p.ip_b
      assert b.ip == p.ip_a

      assert owner_uids_for_ip(p.ip_a, actor) == [p.b_uid]
      assert owner_uids_for_ip(p.ip_b, actor) == [p.a_uid]
    end
  end

  defp integration_update(integration_id, ip, hostname) do
    %{
      "ip" => ip,
      "hostname" => hostname,
      "source" => "integration-test",
      "metadata" => %{
        "integration_type" => "test-integration",
        "integration_id" => integration_id
      }
    }
  end

  defp device_uid_for_integration!(integration_id, actor) do
    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        identifier_type == :integration_id and identifier_value == ^integration_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{device_id: uid}] = List.wrap(identifiers)
    uid
  end

  defp owner_uids_for_ip(ip, actor) do
    {:ok, devices} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)
      |> ServiceRadar.Ash.Page.unwrap()

    devices |> Enum.map(& &1.uid) |> Enum.sort()
  end

  defp cleanup_devices!(uids) do
    uids
    |> Enum.uniq()
    |> Enum.each(fn uid ->
      Repo.query!("DELETE FROM platform.device_identifiers WHERE device_id = $1", [uid])
      Repo.query!("DELETE FROM platform.ocsf_devices WHERE uid = $1", [uid])
    end)
  end

  # Actually unique, which the hash-of-a-UUID version only claimed to be: it was a random
  # draw from 250x250 addresses, and this test takes 96 of them. That is a ~7% birthday
  # collision per run, and a collision is indistinguishable from the bug under test --
  # device_writes drops a contested IP from BOTH claimants by design, so the swap this
  # asserts never completes and `b.ip` comes back nil.
  #
  # A monotonic counter cannot repeat within the VM, and 254x254 is far more than any shard
  # allocates.
  defp unique_test_ip do
    n = System.unique_integer([:positive, :monotonic])
    "100.125.#{rem(div(n, 254), 254) + 1}.#{rem(n, 254) + 1}"
  end
end
