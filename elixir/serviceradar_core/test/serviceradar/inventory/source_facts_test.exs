defmodule ServiceRadar.Inventory.SourceFactsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.SourceFacts

  test "parses Armis hostname:port on the last colon" do
    [fact] =
      SourceFacts.parse_armis_metadata(%{
        "armis_access_switch" => "niadcs-bldd03-asw001:gi1/3"
      })

    assert fact.fact_key == "switch_port_attachment"
    assert fact.value["switch_hostname"] == "niadcs-bldd03-asw001"
    assert fact.value["port"] == "gi1/3"
    assert fact.value["raw"] == "niadcs-bldd03-asw001:gi1/3"
  end

  test "parses Armis stacked hostname:port with extra colons in the host" do
    [fact] =
      SourceFacts.parse_armis_metadata(%{"armis_access_switch" => "nordcs-idfltc-asw001:1/1/41"})

    assert fact.value["switch_hostname"] == "nordcs-idfltc-asw001"
    assert fact.value["port"] == "1/1/41"
  end

  test "parses Armis VLAN arrays without dropping the metadata shape" do
    [fact] = SourceFacts.parse_armis_metadata(%{"armis_vlans" => "[561]"})
    assert fact.fact_key == "vlan_uid"
    assert fact.value["vlan_uid"] == "561"
  end

  test "ignores named VLANs that are not identifiers" do
    assert SourceFacts.parse_explicit_facts(%{
             "vlan_uid" => "DMZnonPCI-BE_FW_10.176.3.64/28"
           }) == []
  end

  test "ignores unknown fact keys" do
    assert SourceFacts.parse_explicit_facts(%{"owner" => "noc"}) == []
  end

  test "explicit plugin facts win over Armis metadata for the same key" do
    facts =
      SourceFacts.extract(%{
        facts: %{
          "switch_port_attachment" => %{
            "switch_hostname" => "SITE01-IDFC08-ASW002",
            "port" => "3/1/28"
          }
        },
        metadata: %{"armis_access_switch" => "niadcs-bldd03-asw001:gi1/3"}
      })

    assert length(facts) == 1
    assert hd(facts).value["switch_hostname"] == "SITE01-IDFC08-ASW002"
    assert hd(facts).value["port"] == "3/1/28"
  end

  test "does not treat network_interfaces as attachment" do
    assert SourceFacts.extract(%{
             metadata: %{},
             network_interfaces: [%{"name" => "eth0"}]
           }) == []
  end

  test "agreement promotes without a disagreement" do
    left = attachment_fact("armis", "gi1/3")
    right = attachment_fact("opentext-nom", "Gi1/3")

    assert {:promote, winner, nil} = SourceFacts.decide([left, right], [], nil)
    assert winner.compare_hash == left.compare_hash
  end

  test "disagreement without authority holds canonical" do
    left = attachment_fact("armis", "gi1/3")
    right = attachment_fact("opentext-nom", "3/1/28")

    assert {:hold, disagreement} = SourceFacts.decide([left, right], [], %{})
    assert disagreement.compare_signature
    refute disagreement.configuration_conflict
  end

  test "one authority promotes that source and keeps the disagreement" do
    left = attachment_fact("armis", "gi1/3")
    right = attachment_fact("opentext-nom", "3/1/28")

    authorities = [
      %{source: "opentext-nom", source_instance: nil, fact_key: "switch_port_attachment", rank: 1}
    ]

    assert {:promote, winner, disagreement} = SourceFacts.decide([left, right], authorities, %{})
    assert winner.source == "opentext-nom"
    assert disagreement
  end

  test "two authorities are a configuration conflict" do
    left = attachment_fact("armis", "gi1/3")
    right = attachment_fact("opentext-nom", "3/1/28")

    authorities = [
      %{source: "armis", source_instance: nil, fact_key: "switch_port_attachment", rank: 1},
      %{source: "opentext-nom", source_instance: nil, fact_key: "switch_port_attachment", rank: 1}
    ]

    assert {:config_conflict, disagreement} = SourceFacts.decide([left, right], authorities, %{})
    assert disagreement.configuration_conflict
  end

  test "case-insensitive port comparison treats gi1/3 as Gi1/3" do
    left = attachment_fact("armis", "gi1/3")
    right = attachment_fact("opentext-nom", "Gi1/3")
    assert left.compare_hash == right.compare_hash
  end

  defp attachment_fact(source, port) do
    [fact] =
      SourceFacts.parse_explicit_facts(%{
        "switch_port_attachment" => %{
          "switch_hostname" => "niadcs-bldd03-asw001",
          "port" => port
        }
      })

    Map.merge(fact, %{source: source, source_instance: "default", present: true})
  end
end
