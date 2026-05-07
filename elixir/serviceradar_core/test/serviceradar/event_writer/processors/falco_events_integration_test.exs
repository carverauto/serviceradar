defmodule ServiceRadar.EventWriter.Processors.FalcoEventsIntegrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.EventWriter.Processors.FalcoEvents
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    reset_engine()
    on_exit(&reset_engine/0)
    :ok
  end

  test "stateful alert evaluation receives textual UUIDs for promoted Falco events" do
    actor = %{id: "system", role: :admin}
    unique = Ash.UUID.generate()
    subject = "falco.codex.#{unique}"
    falco_rule = "Codex Falco UUID Regression #{unique}"
    hostname = "k8s-worker-#{System.unique_integer([:positive])}"
    alert_title = "Falco UUID Regression #{unique}"
    event_uuid = Ash.UUID.generate()

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "falco-uuid-regression-#{unique}",
          enabled: true,
          signal: :event,
          match: %{"subject_prefix" => subject, "severity_number_min" => 5},
          group_by: ["rule", "hostname"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 300,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.security.falco.incident",
            "message" => "Falco security incident detected"
          },
          alert: %{"title" => alert_title, "severity" => "critical"}
        },
        actor: actor
      )
      |> Ash.create()

    payload = %{
      "uuid" => event_uuid,
      "output" => "Critical test event",
      "priority" => "Critical",
      "rule" => falco_rule,
      "time" => DateTime.to_iso8601(DateTime.utc_now()),
      "hostname" => hostname,
      "source" => "syscall",
      "tags" => ["container"],
      "output_fields" => %{
        "proc.name" => "test",
        "user.name" => "root",
        "container.id" => "abc123"
      }
    }

    message = %{
      data: Jason.encode!(payload),
      metadata: %{subject: subject, received_at: DateTime.utc_now()}
    }

    assert {:ok, 1} = FalcoEvents.process_batch([message])

    rule_id = to_string(rule.id)

    assert %{rows: [[alert_count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM alerts WHERE metadata->>'incident_rule_id' = $1",
               [rule_id]
             )

    assert alert_count == 1

    assert %{rows: [[source_event_id]]} =
             SQL.query!(
               Repo,
               """
               SELECT metadata #>> '{serviceradar,diagnostics,representative_event_ids,0}'
               FROM ocsf_events
               WHERE log_name = 'alert.security.falco.incident'
                 AND metadata #>> '{serviceradar,rule_id}' = $1
               ORDER BY time DESC
               LIMIT 1
               """,
               [rule_id]
             )

    assert source_event_id == event_uuid
  end

  defp reset_engine do
    case ProcessRegistry.lookup(:stateful_alert_engine) do
      [{pid, _}] ->
        _ = ProcessRegistry.terminate_child(pid)
        Process.sleep(25)
        :ok

      _ ->
        :ok
    end
  end
end
