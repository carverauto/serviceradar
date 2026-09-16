defmodule ServiceRadar.Inventory.SyncIngestorDeferredEffectsDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @actor SystemActor.system(:sync_deferred_effects_test)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    if is_nil(Process.whereis(IdentityCache)), do: start_supervised!(IdentityCache)
    :ok
  end

  test "rolling back real device ingestion leaves its cache and device state unchanged" do
    {device, update, cached} = fixture("192.0.2.31")

    assert {:error, :synthetic_membership_failure} =
             Repo.transaction(fn ->
               assert {:ok, [effect]} =
                        SyncIngestor.ingest_updates([update],
                          actor: @actor,
                          batch_concurrency: 1,
                          defer_state_events?: true
                        )

               assert hd(effect.device_records).uid == device.uid
               assert IdentityCache.get(device.ip) == cached
               Repo.rollback(:synthetic_membership_failure)
             end)

    assert IdentityCache.get(device.ip) == cached
    assert Device.get_by_uid!(device.uid, false, actor: @actor).hostname == device.hostname
  end

  test "committed device ingestion invalidates cache only when its collected effects are emitted" do
    {device, update, cached} = fixture("192.0.2.32")

    assert {:ok, effects} =
             Repo.transaction(fn ->
               assert {:ok, effects} =
                        SyncIngestor.ingest_updates([update],
                          actor: @actor,
                          batch_concurrency: 1,
                          defer_state_events?: true
                        )

               assert IdentityCache.get(device.ip) == cached
               effects
             end)

    assert IdentityCache.get(device.ip) == cached
    assert Device.get_by_uid!(device.uid, false, actor: @actor).hostname == update["hostname"]
    assert :ok = SyncIngestor.emit_committed_state_events(effects)
    assert IdentityCache.get(device.ip) == nil
  end

  test "ordinary ingestion retains its immediate cache invalidation contract" do
    {device, update, _cached} = fixture("192.0.2.33")

    assert :ok = SyncIngestor.ingest_updates([update], actor: @actor)
    assert IdentityCache.get(device.ip) == nil
    assert Device.get_by_uid!(device.uid, false, actor: @actor).hostname == update["hostname"]
  end

  defp fixture(ip) do
    device =
      Seed.seed!(Device, %{
        uid: "sr:" <> Ash.UUID.generate(),
        ip: ip,
        hostname: "original.example.com",
        is_available: false
      })

    cached = %{
      canonical_device_id: device.uid,
      partition: "default",
      metadata_hash: nil,
      attributes: %{},
      updated_at: DateTime.utc_now()
    }

    :ok = IdentityCache.put(ip, cached)
    assert IdentityCache.get(ip) == cached
    on_exit(fn -> IdentityCache.delete(ip) end)

    update = %{
      "device_id" => device.uid,
      "ip" => ip,
      "hostname" => "updated.example.com",
      "is_available" => true,
      "source" => "awx"
    }

    {device, update, cached}
  end
end
