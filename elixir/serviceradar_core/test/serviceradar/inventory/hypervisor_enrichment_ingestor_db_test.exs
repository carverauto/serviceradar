defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestorDbTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Repo

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:hypervisor_enrichment_ingestor_db_test)}
  end

  test "creates placeholder inventory devices for hypervisor assets without network identity", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_ref = "#{provider}:node:pve-placeholder-#{suffix}"
    guest_ref = "#{provider}:guest:pve-placeholder-#{suffix}:vm:132"

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "hosts" => [
          %{
            "provider_ref" => host_ref,
            "name" => "pve-placeholder-#{suffix}",
            "status" => "online",
            "metadata" => %{"ip" => "10.10.#{rem(suffix, 200)}.11/24"}
          }
        ],
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => host_ref,
            "name" => "vm-placeholder-#{suffix}",
            "guest_type" => "vm",
            "vmid" => 132,
            "status" => "unknown"
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    [[host_uid]] =
      Repo.query!(
        """
        SELECT device_uid
        FROM platform.virtualization_hosts
        WHERE provider = $1 AND provider_ref = $2
        """,
        [provider, host_ref]
      ).rows

    [[guest_uid]] =
      Repo.query!(
        """
        SELECT device_uid
        FROM platform.virtualization_guests
        WHERE provider = $1 AND provider_ref = $2
        """,
        [provider, guest_ref]
      ).rows

    assert String.starts_with?(host_uid, "sr:")
    assert String.starts_with?(guest_uid, "sr:")
    assert host_uid != guest_uid

    assert [[host_uid, "Hypervisor", 99, "10.10.#{rem(suffix, 200)}.11", host_ref]] ==
             Repo.query!(
               """
               SELECT d.uid, d.type, d.type_id, d.ip, di.identifier_value
               FROM platform.ocsf_devices d
               JOIN platform.device_identifiers di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.uid = $1
               """,
               [host_uid]
             ).rows

    assert [[guest_uid, "Virtual", 6, guest_ref]] ==
             Repo.query!(
               """
               SELECT d.uid, d.type, d.type_id, di.identifier_value
               FROM platform.ocsf_devices d
               JOIN platform.device_identifiers di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.uid = $1
               """,
               [guest_uid]
             ).rows
  end

  test "does not let virtual guests claim an agent-managed host UID", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_uid = "sr:agent-managed-hv-parent-#{suffix}"
    guest_ref = "#{provider}:guest:pve-parent-#{suffix}:vm:133"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: host_uid,
          type: "Server",
          type_id: 1,
          name: "agent-managed-parent-#{suffix}",
          hostname: "agent-managed-parent-#{suffix}",
          agent_id: "agent-hv-parent-#{suffix}",
          discovery_sources: ["agent", "sysmon"],
          is_managed: true
        },
        actor: actor
      )
      |> Ash.create()

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "device_uid" => host_uid,
            "name" => "vm-parent-#{suffix}",
            "guest_type" => "vm",
            "vmid" => 133,
            "status" => "running"
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    [[guest_uid]] =
      Repo.query!(
        """
        SELECT device_uid
        FROM platform.virtualization_guests
        WHERE provider = $1 AND provider_ref = $2
        """,
        [provider, guest_ref]
      ).rows

    assert String.starts_with?(guest_uid, "sr:")
    assert guest_uid != host_uid

    assert [[guest_uid, "Virtual", 6, guest_ref]] ==
             Repo.query!(
               """
               SELECT d.uid, d.type, d.type_id, di.identifier_value
               FROM platform.ocsf_devices d
               JOIN platform.device_identifiers di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.uid = $1
               """,
               [guest_uid]
             ).rows
  end
end
