defmodule ServiceRadarWebNG.Observability.SignalDisplayTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.FalcoEvents
  alias ServiceRadar.Plugins.DisplayContract
  alias ServiceRadarWebNG.Observability.SignalDisplay

  @moduletag :db_free

  @event %{
    "message" => "RPZ blocked suspicious.example",
    "severity" => "High",
    "time" => "2027-06-08T12:00:00Z",
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

    timeline = Enum.find(widgets, &(&1.type == :timeline))
    assert timeline.contract_index == 3

    assert %{format: "timestamp"} = Enum.find(timeline.fields, &(&1.label == "Event Time"))

    assert %{format: "unix_nano"} = Enum.find(timeline.fields, &(&1.label == "Observed"))
  end

  test "renders legacy and current exact PowerDNS producer versions" do
    for producer_version <- ["0.1.0", "0.1.1", "0.1.7"] do
      event =
        put_in(
          @event,
          ["metadata", "service_radar", "signal_schema", "producer_version"],
          producer_version
        )

      assert {:ok, contract, :built_in} = SignalDisplay.resolve_contract_with_source(event)
      assert contract["version"] == "1.1.0"
      assert {:ok, [%{type: :summary} = summary | _]} = SignalDisplay.render_record(event)
      assert summary.title == "suspicious.example"
    end
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

  test "infers the baked Trivy contract revision" do
    event = %{
      "log_provider" => "trivy",
      "log_name" => "trivy.report.vulnerability",
      "metadata" => %{"report_kind" => "VulnerabilityReport"}
    }

    assert {:ok, contract, :built_in} = SignalDisplay.resolve_contract_with_source(event)
    assert contract["id"] == "com.carverauto.trivy.vulnerability_report.display"
    assert contract["version"] == "1.1.0"
  end

  test "infers the baked Falco contract revision" do
    event = %{
      "log_provider" => "falco",
      "log_name" => "falco.runtime",
      "metadata" => %{"security_signal" => %{"source" => "falco"}}
    }

    assert {:ok, contract, :built_in} = SignalDisplay.resolve_contract_with_source(event)
    assert contract["id"] == "com.carverauto.falco.runtime_event.display"
    assert contract["version"] == "1.1.0"
  end

  test "classifies Falco's producer fallback event time separately from its stored UTC time" do
    payload = %{
      "output" => "Unexpected connection to K8s API Server from container",
      "priority" => "Warning",
      "rule" => "Contact K8S API Server From Container",
      "time" => "2026-03-03T05:56:44.079252771Z",
      "output_fields" => %{"evt.type" => "connect"}
    }

    row =
      FalcoEvents.parse_message(%{
        data: Jason.encode!(payload),
        metadata: %{subject: "falco.warning.contact_k8s"}
      })

    event = %{
      "log_provider" => row.log_provider,
      "log_name" => row.log_name,
      "time" => DateTime.to_iso8601(row.time),
      "metadata" => row.metadata
    }

    assert {:ok, widgets} = SignalDisplay.render_record(event)
    timeline = Enum.find(widgets, &(&1.type == :timeline))

    assert %{format: "unix_nano", value: "2026-03-03T05:56:44.079252771Z"} =
             Enum.find(timeline.fields, &(&1.label == "Event Time"))

    assert %{format: "timestamp", value: "2026-03-03T05:56:44.079252Z"} =
             Enum.find(timeline.fields, &(&1.label == "Observed"))
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

  describe "degradation (tasks 3.5.3)" do
    # The validator decides what a package may DECLARE; this list decides what
    # this release can DRAW. They are allowed to diverge across a rollout, but a
    # silent divergence would mean a contract that imports and renders nothing.
    test "every widget type the validator accepts is one this release renders" do
      assert Enum.sort(SignalDisplay.renderable_widget_types()) ==
               Enum.sort(DisplayContract.widget_types())
    end

    test "an unknown widget type is dropped with a diagnostic, not raised on" do
      contract = %{
        "widgets" => [
          %{"type" => "producer_html", "html" => "<script></script>"},
          %{"type" => "facts", "fields" => [%{"label" => "Domain", "path" => "query.hostname"}]}
        ]
      }

      assert {[%{type: :facts}], diagnostics} =
               SignalDisplay.render_with_diagnostics(@event, contract)

      assert [%{kind: :unknown_widget, detail: detail}] = diagnostics
      assert detail =~ "producer_html"
    end

    test "a widget whose paths match nothing reports why it is absent" do
      contract = %{
        "widgets" => [%{"type" => "facts", "fields" => [%{"label" => "X", "path" => "nope"}]}]
      }

      assert {[], [%{kind: :empty_widget, detail: detail}]} =
               SignalDisplay.render_with_diagnostics(@event, contract)

      assert detail =~ "facts"
    end

    test "a contract that renders nothing degrades to the generic view" do
      contract = %{"widgets" => [%{"type" => "unknown"}]}

      assert {widgets, diagnostics} = SignalDisplay.render_or_generic(@event, contract)
      assert Enum.any?(widgets, &(&1.type == :facts))
      assert Enum.any?(diagnostics, &(&1.kind == :degraded))
    end

    test "no contract at all still renders the generic view" do
      assert {widgets, []} = SignalDisplay.render_or_generic(%{"a" => "1", "b" => 2}, nil)

      assert [%{type: :facts, fields: fields}] = widgets
      assert Enum.map(fields, & &1.label) == ["A", "B"]
      assert Enum.map(fields, & &1.value) == ["1", "2"]
    end

    test "the generic view separates scalars from containers and bounds both" do
      record =
        1..40
        |> Map.new(fn index -> {"key_#{index}", "value"} end)
        |> Map.put("nested", %{"a" => 1})

      assert [%{type: :facts, fields: fields}, %{type: :json_section, sections: sections}] =
               SignalDisplay.generic_widgets(record, title: "Detail")

      assert length(fields) == 24
      assert [%{path: "nested"}] = sections
    end

    test "the generic view carries no package-supplied labels" do
      # Labels are derived from the record's own keys, so a rejected contract
      # cannot smuggle text into the page through the fallback path.
      assert [%{type: :facts, fields: [%{label: "Alarm Zone"}]}] =
               SignalDisplay.generic_widgets(%{"alarm_zone" => "4"})
    end

    test "a non-map record and a non-map contract are both survivable" do
      assert {[], [%{kind: :invalid_contract}]} = SignalDisplay.render_with_diagnostics(@event, nil)
      assert {[], []} = SignalDisplay.render_or_generic(nil, nil)
    end
  end

  describe "resolution source" do
    test "a first-party signal reports the built-in map as its source" do
      assert {:ok, _contract, :built_in} = SignalDisplay.resolve_contract_with_source(@event)
    end

    test "an explicit contracts map wins over both other sources" do
      contract = %{"widgets" => [%{"type" => "summary", "title" => "message"}]}

      key = {"powerdns", "0.1.0", "com.carverauto.powerdns.dns_activity", "1.0.0"}

      assert {:ok, ^contract, :override} =
               SignalDisplay.resolve_contract_with_source(@event, contracts: %{key => contract})
    end
  end
end
