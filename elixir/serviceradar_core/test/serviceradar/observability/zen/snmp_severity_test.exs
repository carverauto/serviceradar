defmodule ServiceRadar.Observability.Zen.SnmpSeverityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.Zen.Native

  @rule_path Path.join(:code.priv_dir(:serviceradar_core), "zen/rules/snmp_severity.json")

  setup_all do
    rule_json = File.read!(@rule_path)
    {:ok, rule_json: rule_json}
  end

  test "builds trap body, sender IP, and snmp attributes from SNMPv2 varbinds", %{
    rule_json: rule_json
  } do
    payload = %{
      "source" => "192.168.1.10:4161",
      "version" => "V2C",
      "community" => "public",
      "body" => "38611538",
      "varbinds" => [
        %{"oid" => "1.3.6.1.2.1.1.3.0", "value" => "TIMETICKS: 38611538"},
        %{
          "oid" => "1.3.6.1.6.3.1.1.4.1.0",
          "value" => "OBJECT IDENTIFIER: 1.3.6.1.4.1.9.9.41.2.0.1"
        },
        %{
          "oid" => "1.3.6.1.4.1.9.9.41.1.2.3.1.5.1",
          "value" =>
            "OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
        }
      ]
    }

    normalized = evaluate!(payload, rule_json)

    assert normalized["body"] ==
             "SNMP trap 1.3.6.1.4.1.9.9.41.2.0.1 from 192.168.1.10: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."

    assert normalized["source"] == "snmp"
    assert normalized["service_name"] == "snmp"
    assert normalized["source_ip"] == "192.168.1.10"
    assert normalized["attributes"]["snmp"]["trap_oid"] == "1.3.6.1.4.1.9.9.41.2.0.1"
    assert normalized["attributes"]["snmp"]["community"] == "public"
    assert normalized["attributes"]["snmp"]["source"] == "192.168.1.10:4161"
  end

  test "uses the trap OID when the only other varbind is sysUpTime", %{rule_json: rule_json} do
    payload = %{
      "source" => "10.0.0.8:162",
      "source_ip" => "10.0.0.8",
      "body" => "38611538",
      "varbinds" => [
        %{"oid" => "1.3.6.1.2.1.1.3.0", "value" => "TIMETICKS: 38611538"},
        %{
          "oid" => "1.3.6.1.6.3.1.1.4.1.0",
          "value" => "OBJECT IDENTIFIER: 1.3.6.1.6.3.1.1.5.3"
        }
      ]
    }

    normalized = evaluate!(payload, rule_json)

    assert normalized["body"] == "SNMP trap 1.3.6.1.6.3.1.1.5.3 from 10.0.0.8"
    assert normalized["source_ip"] == "10.0.0.8"
  end

  test "keeps a non-trap payload body unchanged", %{rule_json: rule_json} do
    normalized = evaluate!(%{"body" => "already useful", "severity" => "INFO"}, rule_json)

    assert normalized["body"] == "already useful"
    assert normalized["source"] == "snmp"
  end

  defp evaluate!(payload, rule_json) do
    assert {:ok, json} =
             Native.evaluate_rules(Jason.encode!(payload), [{"snmp_severity", rule_json}])

    Jason.decode!(json)
  end
end
