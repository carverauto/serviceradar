defmodule ServiceRadar.Inventory.StreamedDeviceReadsTest do
  @moduledoc """
  One page of `Device.read` is 250 rows. Each caller that treats that page as
  the whole set drops the rest, so this fixture is 260 devices.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.BatchResolver
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.InterfaceClassifier
  alias ServiceRadar.Observability.NetflowExporterCacheRefreshWorker
  alias ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker
  alias ServiceRadar.SweepJobs.MapperPromotion
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @batch 260
  @gateway_id "gw-page-fixture"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:streamed_device_reads)}
  end

  @tag timeout: 300_000
  test "every streamed device read returns the whole batch", %{actor: actor} do
    devices = Enum.map(0..(@batch - 1), &create_device!(actor, &1))
    uids = MapSet.new(devices, & &1.uid)
    ips = Enum.map(devices, & &1.ip)

    compiled =
      SNMPCompiler.execute_target_query(~s|in:devices gateway_id:"#{@gateway_id}"|, actor)

    assert MapSet.equal?(MapSet.new(compiled, & &1.uid), uids)

    assert ips
           |> exporter_ips(actor)
           |> Map.keys()
           |> MapSet.new()
           |> MapSet.equal?(MapSet.new(ips))

    assert ips
           |> NetflowInterfaceCacheRefreshWorker.load_devices_by_ip(actor)
           |> Map.keys()
           |> MapSet.new()
           |> MapSet.equal?(MapSet.new(ips))

    candidates = Enum.map(devices, &%{device_uid: &1.uid, ip: &1.ip})

    assert devices
           |> MapSet.new(& &1.uid)
           |> MapSet.equal?(
             candidates
             |> MapperPromotion.load_devices(actor)
             |> Map.keys()
             |> MapSet.new()
           )

    records = Enum.map(devices, &%{device_id: &1.uid})
    contexts = InterfaceClassifier.load_device_contexts(records, actor)
    assert map_size(contexts) == @batch

    assert Enum.all?(devices, fn device ->
             contexts[device.uid].vendor_name == "Page Fixture" and
               contexts[device.uid].hostname == device.hostname
           end)

    trust =
      BatchResolver.preload_agent_trust(agent_updates(devices), agent_lookups(devices), actor)

    assert Enum.all?(devices, fn device ->
             trust[device.uid] == %{agent_id: device.agent_id, deleted?: false}
           end)

    macs =
      BatchResolver.preload_canonical_macs(
        mac_updates(devices),
        mac_lookups(devices),
        actor
      )

    assert Enum.all?(devices, fn device ->
             MapSet.equal?(macs[device.uid].primary, Mac.universal_macs(device.mac))
           end)

    alias_ips = confirm_aliases!(actor, devices)
    by_alias = exporter_ips(alias_ips, actor)
    assert map_size(by_alias) == @batch

    assert Enum.all?(Enum.with_index(devices), fn {device, index} ->
             by_alias[alias_ip(index)].uid == device.uid
           end)

    Enum.each(devices, fn device ->
      assert {:ok, _} =
               Device.soft_delete(device, "page-fixture", "streamed-device-reads", actor: actor)
    end)

    assert uids
           |> MapSet.to_list()
           |> BatchResolver.tombstoned_ids(actor)
           |> MapSet.new()
           |> MapSet.equal?(uids)

    assert {:ok, deleted} = SweepResultsIngestor.load_deleted_devices(MapSet.to_list(uids), actor)
    assert MapSet.equal?(MapSet.new(deleted, & &1.uid), uids)
  end

  describe "historical MAC veto" do
    test "a live canonical vetoes an Armis update that only shares a historical MAC", %{
      actor: actor
    } do
      result = resolve_armis_update(actor, :live, "a1", ["a2", "a3"])

      assert result.vetoed?
      assert result.resolved == Ids.generate_deterministic_device_id(result.ids)
      refute result.resolved == result.canonical.uid
    end

    test "a soft-deleted canonical vetoes the same update the same way", %{actor: actor} do
      result = resolve_armis_update(actor, :deleted, "b1", ["b2", "b3"])

      assert result.vetoed?
      assert result.resolved == Ids.generate_deterministic_device_id(result.ids)
      refute result.resolved == result.canonical.uid
      assert %DateTime{} = result.canonical_after.deleted_at
    end

    test "an incoming primary MAC still attaches to a live canonical", %{actor: actor} do
      result = resolve_armis_update(actor, :live, "c1", ["c1", "c3"], ["c2"])

      refute result.vetoed?
      assert result.resolved == result.canonical.uid
    end
  end

  defp resolve_armis_update(actor, state, primary, incoming, historical \\ nil) do
    historical = historical || [hd(incoming)]

    canonical = create_mac_device!(actor, state, primary)

    Enum.each([primary | historical], &register_mac!(actor, canonical, &1))

    canonical =
      if state == :deleted do
        {:ok, deleted} =
          Device.soft_delete(canonical, "veto-fixture", "streamed-device-reads", actor: actor)

        deleted
      else
        canonical
      end

    macs = Enum.map(incoming, &normalized_mac/1)

    ids = %{
      armis_id: "armis-veto-#{state}-#{primary}",
      ip: nil,
      mac: hd(macs),
      macs: macs,
      partition: "default"
    }

    registered = Enum.map([primary | historical], &normalized_mac/1)

    lookups = %{
      identifiers:
        macs
        |> Enum.filter(&(&1 in registered))
        |> Map.new(fn mac -> {{:mac, mac, "default"}, canonical.uid} end),
      ip: %{}
    }

    handler = "veto-#{state}-#{primary}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:serviceradar, :identity_reconciler, :resolve, :distinct_mac_veto],
      fn _event, _measurements, metadata, pid -> send(pid, {:veto, metadata}) end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {[{_update, resolved}], _strong} =
      BatchResolver.resolve_batch([{%{device_id: nil}, ids}], lookups, actor)

    canonical_uid = canonical.uid

    vetoed? =
      receive do
        {:veto, %{canonical_device_id: ^canonical_uid}} -> true
      after
        0 -> false
      end

    canonical_after =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^canonical_uid)
      |> Ash.read_one!(actor: actor)

    %{
      canonical: canonical,
      canonical_after: canonical_after,
      resolved: resolved,
      ids: ids,
      vetoed?: vetoed?
    }
  end

  defp create_mac_device!(actor, state, octet) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "veto-#{state}-#{octet}.example.com",
        ip: "198.51.100.#{String.to_integer(octet, 16)}",
        mac: "00:00:5e:00:53:" <> octet,
        gateway_id: @gateway_id,
        partition: "default"
      })
      |> Ash.create(actor: actor)

    device
  end

  defp register_mac!(actor, device, octet) do
    {:ok, _identifier} =
      DeviceIdentifier.register(
        %{
          device_id: device.uid,
          identifier_type: :mac,
          identifier_value: normalized_mac(octet),
          partition: "default",
          confidence: :strong,
          source: "veto-fixture"
        },
        actor: actor
      )

    :ok
  end

  defp normalized_mac(octet), do: "00005E0053" <> String.upcase(octet)

  defp exporter_ips(ips, actor) do
    NetflowExporterCacheRefreshWorker.load_devices_by_ip(ips, actor)
  end

  defp create_device!(actor, index) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "page-#{index}.example.com",
        ip: doc_ip(index),
        mac: doc_mac(index),
        gateway_id: @gateway_id,
        agent_id: "agent-page-#{index}",
        vendor_name: "Page Fixture",
        partition: "default"
      })
      |> Ash.create(actor: actor)

    device
  end

  defp confirm_aliases!(actor, devices) do
    devices
    |> Enum.with_index()
    |> Enum.map(fn {device, index} ->
      ip = alias_ip(index)

      {:ok, alias_state} =
        DeviceAliasState.create_detected(
          %{
            device_id: device.uid,
            partition: "default",
            alias_type: :ip,
            alias_value: ip,
            metadata: %{}
          },
          actor: actor
        )

      assert {:ok, _} = DeviceAliasState.confirm(alias_state, actor: actor)
      ip
    end)
  end

  defp agent_updates(devices) do
    Enum.map(devices, fn device ->
      {%{device_id: nil}, %{agent_id: device.agent_id, partition: "default"}}
    end)
  end

  defp agent_lookups(devices) do
    identifiers =
      Map.new(devices, fn device ->
        {{:agent_id, device.agent_id, "default"}, device.uid}
      end)

    %{identifiers: identifiers, ip: %{}}
  end

  defp mac_updates(devices) do
    Enum.with_index(devices, fn _device, index ->
      {%{device_id: nil},
       %{integration_id: "int-page-#{index}", partition: "default", armis_id: nil}}
    end)
  end

  defp mac_lookups(devices) do
    identifiers =
      Map.new(Enum.with_index(devices), fn {device, index} ->
        {{:integration_id, "int-page-#{index}", "default"}, device.uid}
      end)

    %{identifiers: identifiers, ip: %{}}
  end

  defp doc_ip(index) when index < 254, do: "192.0.2.#{index + 1}"
  defp doc_ip(index), do: "198.51.100.#{index - 253}"

  defp alias_ip(index) when index < 254, do: "203.0.113.#{index + 1}"
  defp alias_ip(index), do: "198.51.100.#{index - 247}"

  defp doc_mac(index) when index < 256 do
    "00:00:5e:00:53:" <> hex_octet(index)
  end

  defp doc_mac(index) do
    "00:00:5e:00:54:" <> hex_octet(index - 256)
  end

  defp hex_octet(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end
end
