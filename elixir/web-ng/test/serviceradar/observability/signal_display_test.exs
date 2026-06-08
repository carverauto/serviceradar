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
