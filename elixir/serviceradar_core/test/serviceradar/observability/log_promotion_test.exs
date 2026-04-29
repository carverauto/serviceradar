defmodule ServiceRadar.Observability.LogPromotionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL, as: SQL
  alias Postgrex.Result
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    :ok
  end

  test "promotes log to event and creates alert" do
    actor = %{id: "system", role: :admin}

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "syslog-errors",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => "logs.syslog", "severity_text" => "ERROR"},
          event: %{"log_name" => "syslog.promoted"}
        },
        actor: actor
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "ERROR",
      severity_number: 17,
      body: "Disk failure detected",
      service_name: "syslog",
      attributes: %{"serviceradar" => %{"ingest" => %{"subject" => "logs.syslog.processed"}}},
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }

    assert {:ok, 1} = LogPromotion.promote([log])

    assert %Result{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM ocsf_events WHERE log_name = $1",
               ["syslog.promoted"]
             )

    assert %Result{rows: [[alert_count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM alerts WHERE event_id IS NOT NULL",
               []
             )

    assert alert_count > 0
  end

  test "matches event_type filter before promoting logs" do
    actor = %{id: "system", role: :admin}
    message = "event_type-match-#{Ash.UUID.generate()}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "event-type-match-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => "logs.test", "event_type" => "sweep.missed"},
          event: %{"message" => message, "log_name" => "test.event_type"}
        },
        actor: actor
      )
      |> Ash.create()

    baseline =
      Repo
      |> SQL.query!("SELECT COUNT(*) FROM ocsf_events WHERE message = $1", [message])
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    matching_log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "INFO",
      severity_number: 11,
      body: "Sweep missed",
      service_name: "test",
      attributes: %{
        "event_type" => "sweep.missed",
        "serviceradar" => %{"ingest" => %{"subject" => "logs.test.processed"}}
      },
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }

    non_matching_log = %{
      matching_log
      | id: Ash.UUID.generate(),
        attributes: %{
          "event_type" => "sweep.ok",
          "serviceradar" => %{"ingest" => %{"subject" => "logs.test.processed"}}
        }
    }

    assert {:ok, 1} = LogPromotion.promote([matching_log])
    assert {:ok, 0} = LogPromotion.promote([non_matching_log])

    assert %Result{rows: [[count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM ocsf_events WHERE message = $1",
               [message]
             )

    assert count == baseline + 1
  end

  test "promotes WAF finding logs with structured security signal context" do
    actor = %{id: "system", role: :admin}
    message = "WAF critical rule 941100: XSS Attack Detected via libinjection /"
    rule_name = "waf-finding-test-#{Ash.UUID.generate()}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: rule_name,
          source_type: :log,
          source: %{},
          match: %{
            "subject_prefix" => "logs.syslog",
            "event_type" => "waf.finding"
          },
          event: %{
            "log_name" => "security.waf.finding",
            "log_provider" => "coraza-proxy-wasm",
            "alert" => false
          }
        },
        actor: actor
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "CRITICAL",
      severity_number: nil,
      body: message,
      service_name: "envoy-coraza-waf",
      attributes: %{
        "event_type" => "waf.finding",
        "security.signal.source" => "coraza-proxy-wasm",
        "waf" => %{
          "client_ip" => "198.51.100.10",
          "request_id" => "req-1",
          "request_path" => "/",
          "rule_id" => "941100",
          "rule_message" => "XSS Attack Detected via libinjection",
          "rule_severity" => "critical",
          "source" => "coraza-proxy-wasm"
        },
        "serviceradar" => %{"ingest" => %{"subject" => "logs.syslog.processed"}}
      },
      resource_attributes: %{"service.name" => "envoy-coraza-waf"},
      created_at: DateTime.utc_now()
    }

    assert {:ok, 1} = LogPromotion.promote([log])

    assert %Result{rows: [[severity, metadata, observables, src_endpoint, unmapped]]} =
             SQL.query!(
               Repo,
               """
               SELECT severity, metadata, observables, src_endpoint, unmapped
               FROM ocsf_events
               WHERE log_name = $1 AND message = $2
               ORDER BY time DESC
               LIMIT 1
               """,
               ["security.waf.finding", message]
             )

    assert severity == "Critical"
    assert metadata["security_signal"]["kind"] == "waf"
    assert metadata["security_signal"]["source"] == "coraza-proxy-wasm"
    assert metadata["security_signal"]["request_id"] == "req-1"
    assert src_endpoint["ip"] == "198.51.100.10"
    assert %{"name" => "198.51.100.10", "type" => "IP Address", "type_id" => 2} in observables
    assert %{"name" => "941100", "type" => "WAF Rule ID", "type_id" => 99} in observables
    assert unmapped["waf"]["rule_id"] == "941100"
  end
end
