defmodule ServiceRadarWebNG.Observability.SignalDisplayTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Observability.SignalDisplay

  @event %{
    "message" => "RPZ blocked suspicious.example",
    "severity" => "High",
    "log_provider" => "ns03",
    "query" => %{"hostname" => "suspicious.example", "type" => "A"},
    "metadata" => %{
      "service_radar" => %{
        "observed_time_unix_nano" => 1_812_456_000_000_000_000,
        "signal_schema" => %{
          "producer_id" => "powerdns",
          "producer_version" => "0.1.0",
          "schema_id" => "com.carverauto.powerdns.dns_activity",
          "schema_version" => "1.0.0"
        }
      }
    }
  }

  test "resolves and renders built-in PowerDNS contract" do
    assert {:ok, widgets} = SignalDisplay.render_record(@event)
    assert Enum.any?(widgets, &(&1.type == :summary))
    assert Enum.any?(widgets, &(&1.type == :facts))
    assert [%{type: :summary} = summary | _] = widgets
    assert summary.title == "suspicious.example"
  end

  test "renders current PowerDNS producer version" do
    event =
      put_in(
        @event,
        ["metadata", "service_radar", "signal_schema", "producer_version"],
        "0.1.1"
      )

    assert {:ok, [%{type: :summary} = summary | _]} = SignalDisplay.render_record(event)
    assert summary.title == "suspicious.example"
  end

  test "infers PowerDNS contract for legacy OCSF rows without signal schema" do
    event = %{
      "class_uid" => 4003,
      "log_name" => "pdns.ocsf",
      "log_provider" => "ns03",
      "message" => "PowerDNS RPZ NXDOMAIN match for srtest-1780956565.log.felo.ai via hagezi-pro",
      "severity" => "Medium",
      "query" => %{
        "hostname" => "srtest-1780956565.log.felo.ai",
        "type" => 1
      },
      "connection_info" => %{"protocol_name" => "UDP"},
      "src_endpoint" => %{"ip" => "127.0.0.1", "port" => 40_859},
      "dst_endpoint" => %{"ip" => "127.0.0.1", "port" => 53},
      "firewall_rule" => %{
        "category" => "QNAME",
        "condition" => "*.log.felo.ai.",
        "match_details" => [%{"value" => "srtest-1780956565.log.felo.ai"}],
        "name" => "hagezi-pro",
        "type" => "NXDOMAIN"
      },
      "metadata" => %{
        "service_radar" => %{
          "addon_id" => "powerdns",
          "agent_id" => "ns03-pdns",
          "source_instance" => "ns03",
          "source_type" => "powerdns"
        }
      },
      "rcode" => "NXDOMAIN",
      "unmapped" => %{"server_identity" => "ns03"}
    }

    assert {:ok, widgets} = SignalDisplay.render_record(event)
    assert [%{type: :summary} = summary | _] = widgets
    assert summary.title == "srtest-1780956565.log.felo.ai"

    fact_fields =
      widgets
      |> Enum.find(&(&1.type == :facts))
      |> Map.fetch!(:fields)

    assert %{value: "hagezi-pro"} = Enum.find(fact_fields, &(&1.label == "Policy Name"))
    assert %{value: "NXDOMAIN"} = Enum.find(fact_fields, &(&1.label == "Policy Kind"))

    assert %{value: "srtest-1780956565.log.felo.ai"} =
             Enum.find(fact_fields, &(&1.label == "Policy Match"))

    assert %{value: "ns03"} = Enum.find(fact_fields, &(&1.label == "Server Identity"))
  end

  test "resolves and renders built-in Wasm plugin contract" do
    event = %{
      "message" => "AXIS event: tns1:Device/IO/VirtualInput",
      "severity" => "Informational",
      "log_provider" => "serviceradar-plugin",
      "unmapped" => %{
        "axis_ws_payload" => %{
          "params" => %{
            "notification" => %{
              "topic" => "tns1:Device/IO/VirtualInput",
              "source" => "camera.local"
            }
          }
        }
      },
      "metadata" => %{
        "service_radar" => %{
          "signal_schema" => %{
            "producer_id" => "axis-camera",
            "producer_version" => "0.1.0",
            "schema_id" => "com.carverauto.axis_camera.event_log",
            "schema_version" => "1.0.0"
          }
        }
      }
    }

    assert {:ok, widgets} = SignalDisplay.render_record(event)
    assert [%{type: :summary} = summary | _] = widgets
    assert summary.title == "AXIS event: tns1:Device/IO/VirtualInput"
    assert summary.message == "tns1:Device/IO/VirtualInput"
  end

  test "resolves schema refs from parsed log attributes" do
    log = %{
      "body" => "RPZ blocked suspicious.example",
      "message" => "RPZ blocked suspicious.example",
      "severity_text" => "High",
      "attributes" => %{
        "service_radar" => %{
          "signal_schema" => %{
            "producer_id" => "powerdns",
            "producer_version" => "0.1.0",
            "schema_id" => "com.carverauto.powerdns.dns_activity",
            "schema_version" => "1.0.0"
          }
        }
      },
      "query" => %{"hostname" => "suspicious.example", "type" => "A"}
    }

    assert {:ok, [%{type: :summary} = summary | _]} = SignalDisplay.render_record(log)
    assert summary.title == "suspicious.example"
  end

  test "resolves schema refs from flattened OTEL log attributes" do
    log = %{
      "body" => "AXIS event: tns1:Device/IO/VirtualInput",
      "message" => "AXIS event: tns1:Device/IO/VirtualInput",
      "severity_text" => "Informational",
      "attributes" => %{
        "service_radar.signal_schema.producer_id" => "axis-camera",
        "service_radar.signal_schema.producer_version" => "0.1.0",
        "service_radar.signal_schema.schema_id" => "com.carverauto.axis_camera.event_log",
        "service_radar.signal_schema.schema_version" => "1.0.0"
      },
      "unmapped" => %{
        "axis_ws_payload" => %{
          "params" => %{
            "notification" => %{
              "topic" => "tns1:Device/IO/VirtualInput"
            }
          }
        }
      }
    }

    assert {:ok, [%{type: :summary} = summary | _]} = SignalDisplay.render_record(log)
    assert summary.message == "tns1:Device/IO/VirtualInput"
  end

  test "falls back when contract is missing" do
    event = put_in(@event, ["metadata", "service_radar", "signal_schema", "schema_id"], "missing")
    assert :error = SignalDisplay.render_record(event)
  end

  test "skips unsupported widgets and malformed field paths" do
    contract = %{
      "widgets" => [
        %{"type" => "producer_html", "html" => "<script></script>"},
        %{"type" => "facts", "fields" => [%{"label" => "Domain", "path" => "query.hostname"}]},
        %{"type" => "facts", "fields" => [%{"label" => "Missing", "path" => "query..bad"}]}
      ]
    }

    assert {:ok, [%{type: :facts, fields: [%{label: "Domain", value: "suspicious.example"}]}]} =
             SignalDisplay.render(@event, contract)
  end

  test "truncates long values" do
    long = String.duplicate("a", 300)
    event = put_in(@event, ["query", "hostname"], long)
    contract = %{"widgets" => [%{"type" => "summary", "title" => "query.hostname"}]}

    assert {:ok, [%{title: title}]} = SignalDisplay.render(event, contract)
    assert String.length(title) == 243
    assert String.ends_with?(title, "...")
  end
end
