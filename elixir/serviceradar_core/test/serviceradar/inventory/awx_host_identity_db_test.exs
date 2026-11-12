defmodule ServiceRadar.Inventory.AwxHostIdentityDbTest do
  @moduledoc """
  An AWX inventory host merges into the live device that holds its `ansible_host` address only
  when the evidence identifies that device as the host: the exact address plus host-name
  agreement on the first DNS label, or a MAC the device holds. The address alone does not
  identify a MAC-anchored device, the host name alone never identifies one, and a MAC
  contradiction refuses the match.

  An AWX host carrying a Proxmox node name and VMID binds to a guest only when the guest reports
  the host's address or shares a universally administered MAC with it. Proxmox clusters reuse
  node names and VMIDs, so the pair alone binds nothing, and a locally administered MAC neither
  binds a guest nor corroborates a holder.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Repo

  @moduletag :integration

  @proxmox_cluster "cluster01"
  @proxmox_node "pve01"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok,
     actor: SystemActor.system(:awx_host_identity_db_test),
     suffix: System.unique_integer([:positive])}
  end

  test "a short AWX host name merges into the agent-managed device holding its address under the FQDN",
       %{actor: actor, suffix: suffix} do
    ip = test_ip()

    agent_uid =
      create_device!(actor, %{
        ip: ip,
        hostname: "host#{suffix}.example.com",
        agent_id: "agent-#{suffix}",
        discovery_sources: ["agent", "sysmon"],
        is_managed: true
      })

    register_mac!(actor, agent_uid, mac(suffix, 1))
    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "HOST#{suffix}", ip)

    assert live?(agent_uid)
    refute live?(awx_uid)
    assert integration_owner(integration_id) == agent_uid
    assert agent_id(agent_uid) == "agent-#{suffix}"

    assert [["awx_host_network_match", "ip_host_name"]] = merge_audit(awx_uid, agent_uid)
  end

  test "an AWX host merges into the MAC-anchored swept device sharing its address and host name",
       %{actor: actor, suffix: suffix} do
    ip = test_ip()

    swept_uid =
      create_device!(actor, %{
        ip: ip,
        mac: mac(suffix, 1),
        hostname: "host#{suffix}",
        discovery_sources: ["sweep", "mapper"]
      })

    register_mac!(actor, swept_uid, mac(suffix, 1))
    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "host#{suffix}", ip)

    assert live?(swept_uid)
    refute live?(awx_uid)
    assert integration_owner(integration_id) == swept_uid
    assert [["awx_host_network_match", "ip_host_name"]] = merge_audit(awx_uid, swept_uid)
  end

  test "an AWX host does not claim an agent-managed device that holds its address under another name",
       %{actor: actor, suffix: suffix} do
    ip = test_ip()

    agent_uid =
      create_device!(actor, %{
        ip: ip,
        hostname: "other#{suffix}.example.com",
        agent_id: "agent-#{suffix}",
        discovery_sources: ["agent", "sysmon"],
        is_managed: true
      })

    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "host#{suffix}", ip)

    assert_not_merged(awx_uid, agent_uid)
  end

  test "an AWX host does not merge into a device that shares only its host name",
       %{actor: actor, suffix: suffix} do
    agent_uid =
      create_device!(actor, %{
        ip: test_ip(),
        hostname: "host#{suffix}.example.com",
        agent_id: "agent-#{suffix}",
        discovery_sources: ["agent", "sysmon"],
        is_managed: true
      })

    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "host#{suffix}", test_ip("198.51.100"))

    assert_not_merged(awx_uid, agent_uid)
  end

  test "an AWX MAC on a holder with no MAC is recorded as an unanchored address match",
       %{actor: actor, suffix: suffix} do
    ip = test_ip()

    holder_uid =
      create_device!(actor, %{
        ip: ip,
        hostname: "unrelated#{suffix}",
        discovery_sources: ["sweep"]
      })

    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "other#{suffix}", ip, [mac(suffix, 1)])

    assert live?(holder_uid)
    refute live?(awx_uid)
    assert integration_owner(integration_id) == holder_uid

    assert [["awx_host_network_match", "ip_unanchored_holder"]] =
             merge_audit(awx_uid, holder_uid)
  end

  test "an overlapping MAC stored only on the device row is recorded as a MAC match",
       %{actor: actor, suffix: suffix} do
    ip = test_ip()
    colon_mac = mac(suffix, 1)

    holder_uid =
      create_device!(actor, %{
        ip: ip,
        hostname: "unrelated#{suffix}",
        discovery_sources: ["sweep"]
      })

    Repo.query!(
      "UPDATE platform.ocsf_devices SET mac = $1 WHERE uid = $2",
      [colon_mac, holder_uid]
    )

    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "other#{suffix}", ip, [colon_mac])

    assert live?(holder_uid)
    refute live?(awx_uid)
    assert integration_owner(integration_id) == holder_uid
    assert [["awx_host_network_match", "mac"]] = merge_audit(awx_uid, holder_uid)
  end

  test "an AWX host whose MAC an agent-managed device holds merges into that device",
       %{actor: actor, suffix: suffix} do
    agent_uid =
      create_device!(actor, %{
        ip: test_ip(),
        hostname: "agentbox#{suffix}.example.com",
        agent_id: "agent-#{suffix}",
        discovery_sources: ["agent", "sysmon"],
        is_managed: true
      })

    register_mac!(actor, agent_uid, mac(suffix, 1))
    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "host#{suffix}", nil, [mac(suffix, 1)])

    assert live?(agent_uid)
    refute live?(awx_uid)
    assert integration_owner(integration_id) == agent_uid
    assert agent_id(agent_uid) == "agent-#{suffix}"
    assert [["awx_host_network_match", "mac"]] = merge_audit(awx_uid, agent_uid)
  end

  for agent_managed? <- [false, true] do
    holder = if agent_managed?, do: "an agent-managed", else: "a swept"

    test "a MAC contradiction refuses #{holder} holder although address and host name agree",
         %{actor: actor, suffix: suffix} do
      ip = test_ip()

      holder_attrs =
        if unquote(agent_managed?) do
          %{
            hostname: "host#{suffix}.example.com",
            agent_id: "agent-#{suffix}",
            discovery_sources: ["agent", "sysmon"],
            is_managed: true
          }
        else
          %{hostname: "host#{suffix}", discovery_sources: ["sweep", "mapper"]}
        end

      holder_uid = create_device!(actor, Map.merge(holder_attrs, %{ip: ip, mac: mac(suffix, 1)}))

      register_mac!(actor, holder_uid, mac(suffix, 1))
      {awx_uid, integration_id} = create_awx_record!(actor, suffix)

      ingest_awx_host!(actor, integration_id, "host#{suffix}", ip, [mac(suffix, 2)])

      assert_not_merged(awx_uid, holder_uid)
    end
  end

  test "a shared locally administered MAC does not corroborate an AWX host's match",
       %{actor: actor, suffix: suffix} do
    agent_uid =
      create_device!(actor, %{
        ip: test_ip(),
        hostname: "agentbox#{suffix}.example.com",
        agent_id: "agent-#{suffix}",
        discovery_sources: ["agent", "sysmon"],
        is_managed: true
      })

    # The fixed address a CNI gives every node's container veth.
    register_mac!(actor, agent_uid, "EE:EE:EE:EE:EE:EE")
    {awx_uid, integration_id} = create_awx_record!(actor, suffix)

    ingest_awx_host!(actor, integration_id, "host#{suffix}", nil, ["EE:EE:EE:EE:EE:EE"])

    assert_not_merged(awx_uid, agent_uid)
  end

  describe "Proxmox guest binding across clusters that reuse node names and VMIDs" do
    test "an AWX host is not bound to another cluster's lone guest with its node name and VMID",
         %{actor: actor, suffix: suffix} do
      vmid = vmid(suffix)

      other_guest_uid =
        ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 2), "198.51.100.20")])

      {awx_uid, integration_id} = create_awx_record!(actor, suffix)

      ingest_awx_host!(actor, integration_id, "host#{suffix}", "192.0.2.10", [], vmid)

      assert_not_merged(awx_uid, other_guest_uid)
      assert integration_owner(integration_id) == awx_uid
    end

    test "an AWX host is bound to no guest when guests of two clusters both report its address",
         %{actor: actor, suffix: suffix} do
      vmid = vmid(suffix)
      guest_a = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 1), "198.51.100.10")])
      guest_b = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 2), "198.51.100.10")])
      {awx_uid, integration_id} = create_awx_record!(actor, suffix)

      ingest_awx_host!(actor, integration_id, "host#{suffix}", "198.51.100.10", [], vmid)

      assert_not_merged(awx_uid, guest_a)
      assert_not_merged(awx_uid, guest_b)
    end

    test "a locally administered MAC a guest reports binds no guest",
         %{actor: actor, suffix: suffix} do
      vmid = vmid(suffix)
      guest_a = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 1), nil)])

      guest_b =
        ingest_proxmox_guest!(actor, vmid, [
          config_nic(mac(suffix, 2), nil),
          %{"name" => "ens19", "mac_address" => local_mac(suffix, 3), "source" => "agent"}
        ])

      {awx_uid, integration_id} = create_awx_record!(actor, suffix)

      ingest_awx_host!(
        actor,
        integration_id,
        "host#{suffix}",
        "192.0.2.10",
        [local_mac(suffix, 3)],
        vmid
      )

      assert_not_merged(awx_uid, guest_a)
      assert_not_merged(awx_uid, guest_b)
    end

    test "an AWX host binds the guest of its own cluster that reports its address",
         %{actor: actor, suffix: suffix} do
      vmid = vmid(suffix)
      guest_a = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 1), "198.51.100.10")])
      guest_b = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 2), "198.51.100.20")])
      {awx_uid, integration_id} = create_awx_record!(actor, suffix)

      ingest_awx_host!(actor, integration_id, "host#{suffix}", "198.51.100.10", [], vmid)

      refute live?(awx_uid)
      assert integration_owner(integration_id) == guest_a
      assert [["awx_proxmox_network_match", _corroboration]] = merge_audit(awx_uid, guest_a)
      assert_not_merged(awx_uid, guest_b)
      assert live?(guest_b)
    end

    test "an AWX host binds the guest that shares its universally administered MAC",
         %{actor: actor, suffix: suffix} do
      vmid = vmid(suffix)
      guest_a = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 1), nil)])
      guest_b = ingest_proxmox_guest!(actor, vmid, [config_nic(mac(suffix, 2), nil)])
      {awx_uid, integration_id} = create_awx_record!(actor, suffix)

      ingest_awx_host!(actor, integration_id, "host#{suffix}", nil, [mac(suffix, 1)], vmid)

      refute live?(awx_uid)
      assert integration_owner(integration_id) == guest_a
      assert [["awx_proxmox_network_match", _corroboration]] = merge_audit(awx_uid, guest_a)
      assert_not_merged(awx_uid, guest_b)
    end
  end

  # One Proxmox cluster, reported by its own integration, holding one node and one QEMU guest.
  # Every call reports the same cluster name, node name and the given VMID, as two clusters
  # built the same way do. Returns the guest's device.
  defp ingest_proxmox_guest!(actor, vmid, interfaces) do
    scope = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "default"
    }

    payload = %{
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "name" => @proxmox_cluster}],
            "nodes" => [%{"node" => @proxmox_node, "status" => "online"}],
            "guests" => [
              %{
                "node" => @proxmox_node,
                "type" => "qemu",
                "vmid" => vmid,
                "name" => "vm#{vmid}",
                "status" => "running",
                "interfaces" => interfaces
              }
            ]
          }
        ]
      }
    }

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload, %{}, actor: actor, source_scope: scope)

    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        scope.integration_id,
        scope.controller_id,
        @proxmox_cluster,
        "qemu",
        vmid
      )

    [[uid]] =
      Repo.query!(
        "SELECT device_uid FROM platform.virtualization_guests WHERE provider_ref = $1",
        [identity.provider_ref]
      ).rows

    uid
  end

  defp config_nic(mac, nil), do: %{"name" => "net0", "mac_address" => mac, "source" => "config"}

  defp config_nic(mac, ip) do
    %{
      "name" => "eth0",
      "mac_address" => mac,
      "ip_addresses" => ["#{ip}/24"],
      "source" => "config+agent"
    }
  end

  defp vmid(suffix), do: 100 + rem(suffix, 900_000)

  defp create_device!(actor, attrs) do
    uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{uid: uid, type: "Server", type_id: 1, name: attrs.hostname}, attrs),
        actor: actor
      )
      |> Ash.create()

    uid
  end

  # A pre-existing, address-less AWX record: what earlier syncs left when the address was held.
  defp create_awx_record!(actor, suffix) do
    integration_id = "awx:v2:ctrl-#{suffix}:host:#{suffix}"

    uid =
      create_device!(actor, %{
        hostname: "host#{suffix}",
        discovery_sources: ["awx"],
        metadata: %{"integration_id" => integration_id}
      })

    register_identifier!(actor, uid, :integration_id, integration_id, "awx")
    {uid, integration_id}
  end

  defp register_mac!(actor, uid, mac),
    do: register_identifier!(actor, uid, :mac, String.replace(mac, ":", ""), "sweep")

  defp register_identifier!(actor, uid, type, value, source) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(
        :register,
        %{
          device_id: uid,
          identifier_type: type,
          identifier_value: value,
          partition: "default",
          source: source
        },
        actor: actor
      )
      |> Ash.create()
  end

  defp ingest_awx_host!(actor, integration_id, host_name, ip, macs \\ [], vmid \\ nil) do
    awx = %{"host_name" => host_name, "ansible_host" => ip}

    awx =
      if vmid,
        do: Map.merge(awx, %{"proxmox_node" => @proxmox_node, "proxmox_vmid" => vmid}),
        else: awx

    metadata = %{"integration_id" => integration_id, "awx" => awx}

    metadata = if macs == [], do: metadata, else: Map.put(metadata, "mac_addresses", macs)

    payload = %{
      "status" => "OK",
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "devices" => [
            %{
              "device_id" => integration_id,
              "hostname" => host_name,
              "ip" => ip,
              "type" => "host",
              "metadata" => metadata
            }
          ]
        }
      ]
    }

    assert :ok = DeviceDiscoveryIngestor.ingest(payload, %{partition: "default"}, actor: actor)
  end

  defp assert_not_merged(awx_uid, holder_uid) do
    assert live?(awx_uid)
    assert live?(holder_uid)
    assert merge_audit(awx_uid, holder_uid) == []
    assert merge_audit(holder_uid, awx_uid) == []
  end

  defp live?(uid) do
    [[deleted_at]] =
      Repo.query!("SELECT deleted_at FROM platform.ocsf_devices WHERE uid = $1", [uid]).rows

    is_nil(deleted_at)
  end

  defp agent_id(uid) do
    [[agent_id]] =
      Repo.query!("SELECT agent_id FROM platform.ocsf_devices WHERE uid = $1", [uid]).rows

    agent_id
  end

  defp integration_owner(integration_id) do
    [[device_id]] =
      Repo.query!(
        """
        SELECT device_id FROM platform.device_identifiers
        WHERE identifier_type = 'integration_id' AND identifier_value = $1
        """,
        [integration_id]
      ).rows

    device_id
  end

  defp merge_audit(from_uid, to_uid) do
    Repo.query!(
      """
      SELECT reason, details->>'corroboration' FROM platform.merge_audit
      WHERE from_device_id = $1 AND to_device_id = $2
      """,
      [from_uid, to_uid]
    ).rows
  end

  defp test_ip(prefix \\ "203.0.113"), do: "#{prefix}.#{Enum.random(1..254)}"

  # A universally administered MAC: bit 1 of the first octet is clear.
  defp mac(suffix, nic), do: format_mac([0x00, 0x00 | mac_tail(suffix, nic)])

  # A locally administered MAC: bit 1 of the first octet is set.
  defp local_mac(suffix, nic), do: format_mac([0x02, 0x00 | mac_tail(suffix, nic)])

  defp mac_tail(suffix, nic), do: [div(rem(suffix, 65_536), 256), rem(suffix, 256), 0x5E, nic]

  defp format_mac(octets) do
    Enum.map_join(octets, ":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end
end
