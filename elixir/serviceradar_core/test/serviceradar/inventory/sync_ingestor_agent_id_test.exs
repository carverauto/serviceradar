defmodule ServiceRadar.Inventory.SyncIngestorAgentIdTest do
  @moduledoc """
  Tests that sync ingestion registers agent_id as a strong identifier
  in device_identifiers so DIRE can deduplicate agent-reported devices.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_agent_id_test)
    {:ok, actor: actor}
  end

  describe "agent_id identifier registration" do
    test "sync ingestion with agent_id registers it in device_identifiers", %{actor: actor} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      ip = "10.50.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      update = %{
        "ip" => ip,
        "hostname" => "k8s-pod-test",
        "source" => "agent",
        "metadata" => %{"agent_id" => agent_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      # Verify agent_id was registered as a strong identifier
      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: agent_id,
          partition: "default"
        })

      assert {:ok, [identifier]} = Ash.read(query, actor: actor)
      assert identifier.confidence == :strong
    end

    test "SNMP source treats agent_id as reporting agent, not device identity", %{actor: actor} do
      agent_id = "snmp-poller-#{System.unique_integer([:positive])}"
      ip = "10.51.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      update = %{
        "ip" => ip,
        "hostname" => "snmp-router-test",
        "source" => "snmp",
        "agent_id" => agent_id,
        "metadata" => %{
          "device_role" => "router",
          "sys_name" => "snmp-router-test"
        }
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: agent_id,
          partition: "default"
        })

      assert {:ok, []} = Ash.read(query, actor: actor)
    end

    test "Armis source registers target identity but not the polling agent", %{actor: actor} do
      agent_id = "armis-poller-#{System.unique_integer([:positive])}"
      armis_id = "armis-target-#{System.unique_integer([:positive])}"
      ip = "10.52.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      update = %{
        "ip" => ip,
        "hostname" => "armis-target-test",
        "source" => "armis",
        "agent_id" => agent_id,
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => armis_id,
          "integration_id" => armis_id
        }
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      agent_query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: agent_id,
          partition: "default"
        })

      armis_query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :armis_device_id,
          identifier_value: armis_id,
          partition: "default"
        })

      assert {:ok, []} = Ash.read(agent_query, actor: actor)
      assert {:ok, [_identifier]} = Ash.read(armis_query, actor: actor)
    end
  end

  describe "failed identity lookups" do
    test "a failed identifier lookup does not ingest the batch", %{actor: actor} do
      agent_id = "lookup-fail-agent-#{System.unique_integer([:positive])}"
      partition = "lookup-fail-#{System.unique_integer([:positive])}"

      update = %{
        "ip" => documentation_ip(),
        "hostname" => "host01.example.com",
        "source" => "agent",
        "partition" => partition,
        "metadata" => %{"agent_id" => agent_id}
      }

      parent = self()

      spawn(fn ->
        send(parent, {:ingested, SyncIngestor.ingest_updates([update], actor: actor)})
      end)

      assert_receive {:ingested, {:error, {:identifier_lookup_failed, _reason}}}, 30_000

      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: agent_id,
          partition: partition
        })

      assert {:ok, []} = Ash.read(query, actor: actor)
    end

    test "a failed address lookup does not ingest the batch", %{actor: actor} do
      partition = "lookup-fail-ip-#{System.unique_integer([:positive])}"
      ip = documentation_ip()

      update = %{
        "ip" => ip,
        "hostname" => "host02.example.com",
        "source" => "scan",
        "partition" => partition
      }

      parent = self()

      spawn(fn ->
        send(parent, {:ingested, SyncIngestor.ingest_updates([update], actor: actor)})
      end)

      assert_receive {:ingested, {:error, {:ip_lookup_failed, _reason}}}, 30_000
    end
  end

  defp documentation_ip do
    octet = rem(System.unique_integer([:positive]), 250) + 1
    "192.0.2.#{octet}"
  end
end
