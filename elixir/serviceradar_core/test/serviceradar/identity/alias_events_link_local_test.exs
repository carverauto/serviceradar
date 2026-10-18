defmodule ServiceRadar.Identity.AliasEventsLinkLocalTest do
  @moduledoc """
  The AliasEvents producer must not persist link-local addresses as identity
  aliases, independently of MapperResultsIngestor.

  This is the netprobe NDP census path: census writes `ip_alias:fe80::...`
  into device metadata, and AliasEvents.process_and_persist/2 is what turns
  that into a `device_alias_states` row. A shared-helper test of
  AliasPolicy.valid_alias_ip?/1 does not prove this caller still uses it.
  GitHub #4022.
  """

  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:alias_events_link_local_test)}
  end

  test "process_and_persist does not create an :ip alias for fe80::/10", %{actor: actor} do
    {:ok, device} = create_device(actor)
    routable = unique_ip("persist-ok")
    link_local = "fe80::#{unique_hextet()}"

    assert {:ok, _events} =
             AliasEvents.process_and_persist(
               [
                 %{
                   device_id: device.uid,
                   partition: "default",
                   timestamp: DateTime.utc_now(),
                   metadata: %{
                     "_alias_last_seen_at" => "2026-08-25T00:00:00Z",
                     "_alias_last_seen_ip" => routable,
                     "ip_alias:#{routable}" => "2026-08-25T00:00:00Z",
                     "ip_alias:#{link_local}" => "2026-08-25T00:00:00Z"
                   }
                 }
               ],
               actor: actor,
               confirm_threshold: 1
             )

    values = alias_values(device.uid, actor)

    assert routable in values
    refute link_local in values, "fe80:: became identity alias evidence via AliasEvents"
  end

  test "process_and_persist does not create an :ip alias for 169.254/16", %{actor: actor} do
    {:ok, device} = create_device(actor)
    routable = unique_ip("persist-apipa")
    apipa = "169.254.#{rem(System.unique_integer([:positive]), 200) + 1}.1"

    assert {:ok, _events} =
             AliasEvents.process_and_persist(
               [
                 %{
                   device_id: device.uid,
                   partition: "default",
                   timestamp: DateTime.utc_now(),
                   metadata: %{
                     "_alias_last_seen_at" => "2026-08-25T00:00:00Z",
                     "_alias_last_seen_ip" => routable,
                     "ip_alias:#{routable}" => "2026-08-25T00:00:00Z",
                     "ip_alias:#{apipa}" => "2026-08-25T00:00:00Z"
                   }
                 }
               ],
               actor: actor,
               confirm_threshold: 1
             )

    values = alias_values(device.uid, actor)

    assert routable in values
    refute apipa in values, "169.254/16 became identity alias evidence via AliasEvents"
  end

  test "create_detected refuses an :ip alias that is link-local", %{actor: actor} do
    {:ok, device} = create_device(actor)
    link_local = "fe80::#{unique_hextet()}"

    assert {:error, %Invalid{}} =
             DeviceAliasState.create_detected(
               %{
                 device_id: device.uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: link_local,
                 metadata: %{}
               },
               actor: actor
             )

    assert alias_values(device.uid, actor) == []
  end

  test "create_detected still accepts a routable :ip alias", %{actor: actor} do
    {:ok, device} = create_device(actor)
    routable = unique_ip("create-ok")

    assert {:ok, %DeviceAliasState{alias_value: ^routable, alias_type: :ip}} =
             DeviceAliasState.create_detected(
               %{
                 device_id: device.uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: routable,
                 metadata: %{}
               },
               actor: actor
             )
  end

  test "process_and_persist and create_detected reject IPv4 limited and directed broadcast addresses",
       %{actor: actor} do
    {:ok, device} = create_device(actor)
    octet = rem(System.unique_integer([:positive]), 200) + 10
    unicast = "192.0.2.#{octet}"
    directed_bcast = "192.0.2.255"

    insert_vnic(device.uid, "#{unicast}/24", unicast)

    assert {:ok, _events} =
             AliasEvents.process_and_persist(
               [
                 %{
                   device_id: device.uid,
                   partition: "default",
                   timestamp: DateTime.utc_now(),
                   metadata: %{
                     "_alias_last_seen_at" => "2026-08-25T00:00:00Z",
                     "_alias_last_seen_ip" => unicast,
                     "ip_alias:#{unicast}" => "2026-08-25T00:00:00Z",
                     "ip_alias:#{directed_bcast}" => "2026-08-25T00:00:00Z",
                     "ip_alias:255.255.255.255" => "2026-08-25T00:00:00Z"
                   }
                 }
               ],
               actor: actor,
               confirm_threshold: 1
             )

    values = alias_values(device.uid, actor)
    assert unicast in values
    refute directed_bcast in values
    refute "255.255.255.255" in values

    assert {:error, %Invalid{}} =
             DeviceAliasState.create_detected(
               %{
                 device_id: device.uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: directed_bcast,
                 metadata: %{}
               },
               actor: actor
             )
  end

  test "an alias detected before its subnet was known cannot be confirmed once it is",
       %{actor: actor} do
    {:ok, device} = create_device(actor)
    directed_bcast = "192.0.2.127"

    assert {:ok, detected} =
             DeviceAliasState.create_detected(
               %{
                 device_id: device.uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: directed_bcast,
                 metadata: %{}
               },
               actor: actor
             )

    insert_vnic(device.uid, "192.0.2.1/25", "192.0.2.1")

    assert {:error, %Invalid{}} =
             DeviceAliasState.confirm_from_sweep(detected, %{metadata: %{}}, actor: actor)

    assert {:error, %Invalid{}} =
             DeviceAliasState.record_sighting(detected, %{confirm_threshold: 1}, actor: actor)

    assert {:error, %Invalid{}} =
             detected
             |> Ash.Changeset.for_update(:confirm, %{})
             |> Ash.update(actor: actor)

    assert {:ok, stale} = DeviceAliasState.mark_stale(detected, actor: actor)

    assert {:error, %Invalid{}} =
             stale
             |> Ash.Changeset.for_update(:reactivate, %{})
             |> Ash.update(actor: actor)
  end

  defp insert_vnic(device_uid, cidr, address) do
    ServiceRadar.Repo.query!(
      """
      WITH host AS (
        INSERT INTO platform.virtualization_hosts
          (id, provider, provider_ref, device_uid, name)
        VALUES (gen_random_uuid(), 'synthetic', 'synthetic:host:' || $1, $1, 'virt-node01')
        RETURNING id
      )
      INSERT INTO platform.virtualization_network_interfaces
        (id, provider, provider_ref, host_id, device_uid, name, cidr, address, ip_addresses)
      SELECT gen_random_uuid(), 'synthetic', 'synthetic:vnic:' || $1, host.id, $1, 'vmbr0', $2, $3, ARRAY[$3]
      FROM host
      """,
      [device_uid, cidr, address]
    )
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "link-local-alias-host",
      ip: unique_ip("device")
    })
    |> Ash.create(actor: actor)
  end

  defp alias_values(device_id, actor) do
    DeviceAliasState
    |> Ash.Query.filter(device_id == ^device_id and alias_type == :ip)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.alias_value)
  end

  defp unique_ip(seed) do
    n = System.unique_integer([:positive])
    "100.80.#{rem(n, 200) + 1}.#{:erlang.phash2(seed, 200) + 1}"
  end

  defp unique_hextet do
    Integer.to_string(rem(System.unique_integer([:positive, :monotonic]), 0xFFFF), 16)
  end
end
