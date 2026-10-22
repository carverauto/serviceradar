defmodule ServiceRadar.Inventory.SourceFactsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.SourceFacts

  test "parses Armis hostname:port on the last colon" do
    [fact] =
      SourceFacts.parse_armis_metadata(%{
        "armis_access_switch" => "switch01.example.com:gi1/0/7"
      })

    assert fact.fact_key == "switch_port_attachment"
    assert fact.value["switch_hostname"] == "switch01.example.com"
    assert fact.value["port"] == "gi1/0/7"
    assert fact.value["raw"] == "switch01.example.com:gi1/0/7"
  end

  test "parses Armis stacked hostname:port with extra colons in the host" do
    [fact] =
      SourceFacts.parse_armis_metadata(%{"armis_access_switch" => "switch02.example.com:1/1/41"})

    assert fact.value["switch_hostname"] == "switch02.example.com"
    assert fact.value["port"] == "1/1/41"
  end

  test "parses Armis VLAN arrays without dropping the metadata shape" do
    [fact] = SourceFacts.parse_armis_metadata(%{"armis_vlans" => "[200]"})
    assert fact.fact_key == "vlan_uid"
    assert fact.value["vlan_uid"] == "200"
  end

  test "ignores named VLANs that are not identifiers" do
    assert SourceFacts.parse_explicit_facts(%{
             "vlan_uid" => "lab-printers"
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
            "switch_hostname" => "SWITCH03.EXAMPLE.COM",
            "port" => "1/1/7"
          }
        },
        metadata: %{"armis_access_switch" => "switch01.example.com:gi1/0/7"}
      })

    assert length(facts) == 1
    assert hd(facts).value["switch_hostname"] == "SWITCH03.EXAMPLE.COM"
    assert hd(facts).value["port"] == "1/1/7"
  end

  test "a plugin attachment's absent fields stay absent" do
    assert SourceFacts.extract(%{
             facts: %{"switch_port_attachment" => %{"switch_hostname" => "switch03.example.com"}}
           }) == []

    [fact] =
      SourceFacts.extract(%{
        facts: %{
          "switch_port_attachment" => %{
            "switch_hostname" => "switch03.example.com",
            "port" => "1/1/7"
          }
        }
      })

    assert fact.value == %{
             "switch_hostname" => "switch03.example.com",
             "port" => "1/1/7",
             "raw" => "switch03.example.com:1/1/7"
           }
  end

  test "does not treat network_interfaces as attachment" do
    assert SourceFacts.extract(%{
             metadata: %{},
             network_interfaces: [%{"name" => "eth0"}]
           }) == []
  end

  test "agreement promotes without a disagreement" do
    left = attachment_fact("armis", "gi1/0/7")
    right = attachment_fact("opentext-nom", "Gi1/0/7")

    assert {:promote, winner, nil} = SourceFacts.decide([left, right], [], nil)
    assert winner.compare_hash == left.compare_hash
  end

  test "disagreement without authority holds canonical" do
    left = attachment_fact("armis", "gi1/0/7")
    right = attachment_fact("opentext-nom", "1/1/7")

    assert {:hold, disagreement} = SourceFacts.decide([left, right], [], %{})
    assert disagreement.compare_signature
    refute disagreement.configuration_conflict
  end

  test "one authority promotes that source and keeps the disagreement" do
    left = attachment_fact("armis", "gi1/0/7")
    right = attachment_fact("opentext-nom", "1/1/7")

    authorities = [
      %{source: "opentext-nom", source_instance: nil, fact_key: "switch_port_attachment", rank: 1}
    ]

    assert {:promote, winner, disagreement} = SourceFacts.decide([left, right], authorities, %{})
    assert winner.source == "opentext-nom"
    assert disagreement
  end

  test "two authorities are a configuration conflict" do
    left = attachment_fact("armis", "gi1/0/7")
    right = attachment_fact("opentext-nom", "1/1/7")

    authorities = [
      %{source: "armis", source_instance: nil, fact_key: "switch_port_attachment", rank: 1},
      %{source: "opentext-nom", source_instance: nil, fact_key: "switch_port_attachment", rank: 1}
    ]

    assert {:config_conflict, disagreement} = SourceFacts.decide([left, right], authorities, %{})
    assert disagreement.configuration_conflict
  end

  test "case-insensitive port comparison treats gi1/0/7 as Gi1/0/7" do
    left = attachment_fact("armis", "gi1/0/7")
    right = attachment_fact("opentext-nom", "Gi1/0/7")
    assert left.compare_hash == right.compare_hash
  end

  describe "externally reported facts" do
    test "a valid label is recorded under the api: prefix" do
      assert SourceFacts.api_source("example-nms") == {:ok, "api:example-nms"}
      assert SourceFacts.api_source("nms_2") == {:ok, "api:nms_2"}
    end

    test "a label that could pass for another source is refused" do
      for label <- ["Example", "1nms", "api:armis", "", " nms", String.duplicate("a", 64), nil, 7] do
        assert {:error, _reason} = SourceFacts.api_source(label), "accepted #{inspect(label)}"
      end
    end

    test "only platform fact keys can be reported" do
      assert SourceFacts.reported_key("switch_port_attachment") == :ok
      assert SourceFacts.reported_key("vlan_uid") == :ok
      assert {:error, reason} = SourceFacts.reported_key("owner")
      assert reason =~ "switch_port_attachment, vlan_uid"
    end

    test "a reported attachment compares equal to the same port from an integration" do
      assert {:ok, reported} =
               SourceFacts.parse_reported("switch_port_attachment", %{
                 "switch_hostname" => "ACCESS01.example.com",
                 "port" => "Gi1/0/7"
               })

      [integration] =
        SourceFacts.parse_armis_metadata(%{
          "armis_access_switch" => "access01.example.com:gi1/0/7"
        })

      assert reported.compare_hash == integration.compare_hash
      assert reported.value["raw"] == "ACCESS01.example.com:Gi1/0/7"
    end

    test "an attachment may be reported as hostname:port" do
      assert {:ok, fact} =
               SourceFacts.parse_reported(
                 "switch_port_attachment",
                 "access01.example.com:Gi1/0/7"
               )

      assert fact.value["switch_hostname"] == "access01.example.com"
      assert fact.value["port"] == "Gi1/0/7"
    end

    test "an attachment without a port is refused with the reason" do
      assert {:error, reason} =
               SourceFacts.parse_reported("switch_port_attachment", %{
                 "switch_hostname" => "access01.example.com"
               })

      assert reason =~ "switch_hostname and port"
    end

    test "a VLAN id the caller supplied must be readable" do
      base = %{"switch_hostname" => "access01.example.com", "port" => "Gi1/0/7"}

      assert {:ok, fact} =
               SourceFacts.parse_reported("switch_port_attachment", Map.put(base, "vlan_id", 120))

      assert fact.value["vlan_id"] == "120"

      assert {:ok, fact} =
               SourceFacts.parse_reported("switch_port_attachment", Map.put(base, "vlan_id", ""))

      refute Map.has_key?(fact.value, "vlan_id")

      for vlan_id <- [0, 4095, "office", "-1"] do
        assert {:error, reason} =
                 SourceFacts.parse_reported(
                   "switch_port_attachment",
                   Map.put(base, "vlan_id", vlan_id)
                 )

        assert reason =~ "vlan_id"
      end
    end

    test "a vlan_uid is a VLAN id from 1 to 4094" do
      assert {:ok, %{value: %{"vlan_uid" => "120"}}} = SourceFacts.parse_reported("vlan_uid", 120)

      assert {:ok, %{value: %{"vlan_uid" => "4094"}}} =
               SourceFacts.parse_reported("vlan_uid", "4094")

      for vlan_id <- [0, 4095, 5000, "office", nil] do
        assert {:error, _reason} = SourceFacts.parse_reported("vlan_uid", vlan_id),
               "accepted #{inspect(vlan_id)}"
      end
    end

    test "oversized fields are refused" do
      long_host = String.duplicate("a", 256) <> ".example.com"

      assert {:error, reason} =
               SourceFacts.parse_reported("switch_port_attachment", %{
                 "switch_hostname" => long_host,
                 "port" => "1"
               })

      assert reason =~ "switch_hostname"

      assert {:error, reason} =
               SourceFacts.parse_reported("switch_port_attachment", %{
                 "switch_hostname" => "access01.example.com",
                 "port" => "1",
                 "raw" => String.duplicate("r", 513)
               })

      assert reason =~ "raw"
    end
  end

  defp attachment_fact(source, port) do
    [fact] =
      SourceFacts.parse_explicit_facts(%{
        "switch_port_attachment" => %{
          "switch_hostname" => "switch01.example.com",
          "port" => port
        }
      })

    Map.merge(fact, %{source: source, source_instance: "default", present: true})
  end
end
