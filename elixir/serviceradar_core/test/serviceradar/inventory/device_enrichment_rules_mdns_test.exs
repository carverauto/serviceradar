defmodule ServiceRadar.Inventory.DeviceEnrichmentRulesMdnsTest do
  @moduledoc """
  Device classification from netprobe's passive mDNS stream.

  All of these run against the BUILT-IN ruleset -- `reload/0` in setup drops any
  filesystem override a sibling test may have left in the VM-wide
  `:persistent_term` cache -- so a rule that fails to load fails here rather
  than degrading to "nothing matched", which is indistinguishable from a device
  that announced nothing.

  Every fixture is synthesized. This repository is public and a captured mDNS
  payload carries instance names people chose for their own devices.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.DeviceEnrichmentRules

  setup do
    DeviceEnrichmentRules.reload()
    :ok
  end

  defp mdns_update(metadata) do
    %{source: "netprobe-mdns", hostname: nil, metadata: metadata}
  end

  describe "hardware the device named for itself" do
    test "an Apple TV model is classified as Apple media hardware" do
      classification =
        %{
          "mdns.service_types" => "_airplay._tcp,_raop._tcp",
          "mdns.model" => "AppleTV6,2",
          "mdns.ambiguous_model" => "false"
        }
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.vendor_name == "Apple"
      assert classification.type == "Media Device"
      assert classification.os_family == "tvOS"
      assert classification.rule_id == "mdns-model-apple-tv"
    end

    test "an iPhone model is classified as a mobile device" do
      classification =
        %{"mdns.model" => "iPhone14,2", "mdns.service_types" => "_companion-link._tcp"}
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.vendor_name == "Apple"
      assert classification.type == "Mobile"
      assert classification.type_id == 5
    end

    test "a desktop Mac is not classified as a laptop" do
      classification =
        %{"mdns.model" => "Macmini9,1"} |> mdns_update() |> DeviceEnrichmentRules.classify()

      assert classification.type == "Desktop"
      assert classification.type_id == 2
    end
  end

  describe "a MAC that spoke for two products" do
    test "falls back to the service type instead of guessing a model" do
      # THE case this whole design is built around. The agent-side translator
      # withholds `mdns.model` when a MAC advertised more than one product, so
      # no model rule can fire and the device keeps the coarse-but-correct
      # answer the protocol supports. Asserting a vendor here would mean core
      # typed a device from whichever product sorted first.
      classification =
        %{
          "mdns.service_types" => "_airplay._tcp,_raop._tcp",
          "mdns.models" => "AppleTV6,2,AudioAccessory5,1",
          "mdns.ambiguous_model" => "true"
        }
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.type == "Media Device"
      assert classification.rule_id == "mdns-service-media-streaming"

      refute classification.vendor_name,
             "an ambiguous MAC was given a vendor from a model it never uniquely claimed"
    end

    test "mdns.models alone never types a device" do
      # `mdns.models` is evidence for an operator reading the record, not a
      # selector. If it were matchable, the ambiguity guard above would be
      # bypassed by writing a rule against the plural key.
      classification =
        %{"mdns.models" => "AppleTV6,2,AudioAccessory5,1"}
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.rule_id == nil
      assert classification.type == nil
    end
  end

  describe "printers" do
    test "an IPP service type is enough for the type" do
      classification =
        %{"mdns.service_types" => "_ipp._tcp,_http._tcp"}
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.type == "Printer"
      assert classification.rule_id == "mdns-service-printer"
      refute classification.vendor_name, "a printing protocol does not name a manufacturer"
    end

    test "the manufacturer the printer declared outranks the bare service type" do
      classification =
        %{
          "mdns.service_types" => "_ipp._tcp",
          "mdns.txt.usb_MFG" => "Brother",
          "mdns.txt.usb_MDL" => "HL-L2340D series"
        }
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.vendor_name == "Brother"
      assert classification.type == "Printer"
      assert classification.rule_id == "mdns-printer-manufacturer-brother"
    end
  end

  describe "protocols third parties implement" do
    test "Chromecast gives a type and no vendor" do
      # A TV with Chromecast built in is made by Sony or TCL. Setting vendor
      # "Google" here would be wrong on most of the devices that match.
      classification =
        %{"mdns.service_types" => "_googlecast._tcp"}
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.type == "Media Device"
      refute classification.vendor_name
    end

    test "AirPlay audio on a third-party speaker gives a type and no vendor" do
      classification =
        %{"mdns.service_types" => "_raop._tcp"}
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.type == "Media Device"
      refute classification.vendor_name
    end

    test "Sonos names itself, so it does get a vendor" do
      classification =
        %{"mdns.service_types" => "_sonos._tcp,_raop._tcp"}
        |> mdns_update()
        |> DeviceEnrichmentRules.classify()

      assert classification.vendor_name == "Sonos"
      assert classification.type == "Speaker"
    end
  end

  describe "selector plumbing" do
    test "a nested mdns map resolves the same as the flat keys the agent writes" do
      flat = mdns_update(%{"mdns.service_types" => "_ipp._tcp", "mdns.txt.usb_MFG" => "Epson"})

      nested =
        mdns_update(%{
          "mdns" => %{"service_types" => "_ipp._tcp", "txt" => %{"usb_MFG" => "Epson"}}
        })

      assert DeviceEnrichmentRules.classify(nested).rule_id ==
               DeviceEnrichmentRules.classify(flat).rule_id

      assert DeviceEnrichmentRules.classify(nested).vendor_name == "Epson"
    end

    test "a device with no mDNS evidence is left alone" do
      assert DeviceEnrichmentRules.classify(mdns_update(%{})).rule_id == nil
    end

    test "an unrelated source with SNMP evidence still classifies from SNMP" do
      # The mDNS selectors must not shadow the existing ruleset. This is the
      # same UDM fixture the built-in test uses.
      classification =
        DeviceEnrichmentRules.classify(%{
          hostname: "farm01",
          source: "mapper",
          metadata: %{
            "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
            "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
            "sys_name" => "farm01",
            "ip_forwarding" => "1"
          }
        })

      assert classification.rule_id == "ubiquiti-router-udm"
    end
  end

  describe "the shipped ruleset loads" do
    test "every built-in mDNS rule validates" do
      # A rule naming a selector outside @allowed_match_keys is REJECTED at
      # load. Nothing at runtime says so -- classification just quietly stops
      # matching -- so the shipped file is validated here.
      path =
        Path.join([
          Application.app_dir(:serviceradar_core, "priv"),
          "device_enrichment",
          "rules",
          "mdns_enrichment_rules.yaml"
        ])

      assert {:ok, rules} =
               path |> File.read!() |> DeviceEnrichmentRules.parse_and_validate_yaml(file: path)

      assert length(rules) >= 10
      assert Enum.all?(rules, & &1.enabled)
    end
  end
end
