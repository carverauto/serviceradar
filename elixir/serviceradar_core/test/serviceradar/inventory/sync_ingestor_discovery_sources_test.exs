defmodule ServiceRadar.Inventory.SyncIngestorDiscoverySourcesTest do
  @moduledoc """
  Tests for discovery_sources propagation through the sync ingestor.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Inventory.{Device, SyncIngestor}
  alias ServiceRadar.TestSupport

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    %{tenant_id: tenant_id, tenant_slug: tenant_slug} =
      TestSupport.create_tenant_schema!("discovery-sources")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant_slug)
    end)

    actor = %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }

    {:ok, tenant_id: tenant_id, tenant_slug: tenant_slug, actor: actor}
  end

  describe "discovery_sources propagation" do
    test "device discovered by armis has discovery_sources populated", %{
      tenant_id: tenant_id,
      actor: actor
    } do
      armis_id = "armis-#{System.unique_integer([:positive])}"
      ip = "10.0.2.#{unique_octet()}"
      mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

      update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "armis-device",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], tenant_id, actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

      assert device.discovery_sources == ["armis"]
    end

    test "device discovered by netbox has discovery_sources populated", %{
      tenant_id: tenant_id,
      actor: actor
    } do
      netbox_id = "netbox-#{System.unique_integer([:positive])}"
      ip = "10.0.3.#{unique_octet()}"
      mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

      update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "netbox-device",
        "source" => "netbox",
        "metadata" => %{"netbox_device_id" => netbox_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], tenant_id, actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

      assert device.discovery_sources == ["netbox"]
    end

    test "device discovered by multiple sources has merged discovery_sources", %{
      tenant_id: tenant_id,
      actor: actor
    } do
      armis_id = "armis-#{System.unique_integer([:positive])}"
      netbox_id = "netbox-#{System.unique_integer([:positive])}"
      ip = "10.0.4.#{unique_octet()}"
      mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

      # First discovery from armis
      armis_update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "multi-source-device",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      assert :ok = SyncIngestor.ingest_updates([armis_update], tenant_id, actor: actor)

      # Second discovery from netbox (same device by MAC)
      netbox_update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "multi-source-device",
        "source" => "netbox",
        "metadata" => %{"netbox_device_id" => netbox_id}
      }

      assert :ok = SyncIngestor.ingest_updates([netbox_update], tenant_id, actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

      # Should have both sources, order may vary
      assert Enum.sort(device.discovery_sources) == ["armis", "netbox"]
    end

    test "device without source field gets 'unknown' as discovery_source", %{
      tenant_id: tenant_id,
      actor: actor
    } do
      ip = "10.0.5.#{unique_octet()}"
      mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

      update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "unknown-source-device"
        # No "source" field
      }

      assert :ok = SyncIngestor.ingest_updates([update], tenant_id, actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

      assert device.discovery_sources == ["unknown"]
    end

    test "duplicate source updates do not create duplicate entries", %{
      tenant_id: tenant_id,
      actor: actor
    } do
      armis_id = "armis-#{System.unique_integer([:positive])}"
      ip = "10.0.6.#{unique_octet()}"
      mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

      update = %{
        "ip" => ip,
        "mac" => mac,
        "hostname" => "dup-source-device",
        "source" => "armis",
        "metadata" => %{"armis_device_id" => armis_id}
      }

      # Ingest the same update twice
      assert :ok = SyncIngestor.ingest_updates([update], tenant_id, actor: actor)
      assert :ok = SyncIngestor.ingest_updates([update], tenant_id, actor: actor)

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(tenant: tenant_id, actor: actor, authorize?: false)

      # Should only have one "armis" entry, not duplicated
      assert device.discovery_sources == ["armis"]
    end
  end

  defp unique_octet do
    rem(System.unique_integer([:positive]), 200) + 10
  end

  defp mac_suffix do
    System.unique_integer([:positive])
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
