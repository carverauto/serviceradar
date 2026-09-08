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

    assert {:error, %Ash.Error.Invalid{}} =
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
