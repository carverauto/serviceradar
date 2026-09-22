defmodule ServiceRadar.NetworkConfig.ProjectorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.Projector

  @device "sr:host01.example.com"
  @revision_id "00000000-0000-4000-8000-000000000001"

  @facts [
    %{
      if_name: "GigabitEthernet0/1",
      ipv4_prefix: "192.0.2.0/24",
      ipv6_prefix: "2001:db8:1::/64",
      vlan: 10,
      description: "Uplink to core",
      shutdown: false,
      vrf: nil
    },
    %{
      if_name: "GigabitEthernet0/2",
      ipv4_prefix: "198.51.100.0/24",
      ipv6_prefix: nil,
      vlan: nil,
      description: "Spare access port",
      shutdown: true,
      vrf: nil
    }
  ]

  test "payloads use config-declared evidence and do not mark backbone overwrite" do
    payloads = Projector.payloads(@device, %{id: @revision_id}, @facts)

    assert payloads.ingestor == "network_config_v1"
    assert payloads.evidence_class == "config-declared"
    assert payloads.protocol == "config"
    assert payloads.overwrite_backbone? == false
    assert payloads.revision_id == @revision_id
    assert length(payloads.interfaces) == 2
    assert length(payloads.prefixes) == 3

    cidrs = Enum.map(payloads.prefixes, & &1.cidr)
    assert "192.0.2.0/24" in cidrs
    assert "2001:db8:1::/64" in cidrs
    assert "198.51.100.0/24" in cidrs

    refute Enum.any?(payloads.interfaces, &Map.has_key?(&1, :neighbor_device_id))
    refute Enum.any?(payloads.prefixes, fn p -> p.evidence_class == "direct-physical" end)
  end

  test "project calls persist hooks and never upserts CONNECTS_TO" do
    test = self()

    assert :ok =
             Projector.project(@device, @revision_id, @facts,
               persist_age: fn device_uid, payloads ->
                 send(test, {:age, device_uid, payloads})
                 :ok
               end,
               persist_dgraph: fn payloads ->
                 send(test, {:dgraph, payloads})
                 :ok
               end
             )

    assert_receive {:age, @device, age_payloads}
    assert_receive {:dgraph, dgraph_payloads}
    assert age_payloads.overwrite_backbone? == false
    assert dgraph_payloads.ingestor == "network_config_v1"
    refute Map.has_key?(dgraph_payloads, :edges)
  end
end
