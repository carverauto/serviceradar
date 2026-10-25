defmodule ServiceRadar.Inventory.AwxHostIdentityDbTest do
  @moduledoc """
  An AWX inventory host merges into the live device that holds its `ansible_host` address only
  when the evidence identifies that device as the host: the exact address plus host-name
  agreement on the first DNS label. The address alone does not identify a MAC-anchored device,
  the host name alone never identifies one, and a MAC contradiction refuses the match.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Repo

  @moduletag :integration

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

  test "a MAC contradiction refuses the match although address and host name agree",
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

    ingest_awx_host!(actor, integration_id, "host#{suffix}", ip, [mac(suffix, 2)])

    assert_not_merged(awx_uid, swept_uid)
  end

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

  defp ingest_awx_host!(actor, integration_id, host_name, ip, macs \\ []) do
    metadata = %{
      "integration_id" => integration_id,
      "awx" => %{"host_name" => host_name, "ansible_host" => ip}
    }

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

  defp mac(suffix, nic) do
    Enum.map_join(
      [0x02, 0x00, div(rem(suffix, 65_536), 256), rem(suffix, 256), 0x5E, nic],
      ":",
      &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0"))
    )
  end
end
