defmodule ServiceRadar.EventWriter.Processors.FalcoEventsIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.EventWriter.LifecycleAdmissionDrainWorker
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.FalcoEvents
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ScriptedStatefulAlertEngine

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

  test "replayed Falco events keep one active detection finding with normalized diagnostics" do
    event_uuid = Ash.UUID.generate()
    event_uuid_bin = Ecto.UUID.dump!(event_uuid)

    message =
      falco_message(%{
        "uuid" => event_uuid,
        "output" => "Drop and execute new binary in container",
        "priority" => "Warning",
        "rule" => "Drop and execute new binary in container",
        "time" => "2026-06-11T01:10:00Z",
        "hostname" => "k8s-cp2-worker2",
        "source" => "syscall",
        "tags" => ["container", "process"],
        "output_fields" => %{
          "container.id" => "d2d34c8e90ab",
          "container.image.repository" => "code.forgejo.org/forgejo/runner",
          "container.image.tag" => "latest",
          "container.name" => "forgejo-runner",
          "evt.type" => "execve",
          "k8s.ns.name" => "ci",
          "k8s.pod.name" => "runner-0",
          "proc.cmdline" => "/tmp/.build/tool --lint",
          "proc.cwd" => "/workspace/carverauto/serviceradar",
          "proc.name" => "tool",
          "proc.pname" => "bash",
          "user.name" => "root"
        }
      })

    with_stubbed_alert_engine(fn ->
      assert {:ok, 1} = FalcoEvents.process_batch([message])
      assert {:ok, 0} = FalcoEvents.process_batch([message])
    end)

    assert %{rows: [[event_count]]} =
             SQL.query!(
               Repo,
               """
               SELECT COUNT(*)
               FROM platform.ocsf_events
               WHERE id = $1::uuid
                 AND COALESCE(metadata->'service_radar'->>'source_type', log_provider) = 'falco'
               """,
               [event_uuid_bin]
             )

    assert event_count == 1

    assert %{rows: [[metadata]]} =
             SQL.query!(
               Repo,
               """
               SELECT metadata
               FROM platform.ocsf_events
               WHERE id = $1::uuid
               """,
               [event_uuid_bin]
             )

    diagnostics = metadata["security_signal"]["diagnostics"]
    assert diagnostics["rule"]["name"] == "Drop and execute new binary in container"
    assert diagnostics["rule"]["priority"] == "Warning"
    assert diagnostics["process"]["command"] == "/tmp/.build/tool --lint"
    assert diagnostics["process"]["cwd"] == "/workspace/carverauto/serviceradar"
    assert diagnostics["container"]["name"] == "forgejo-runner"
    assert diagnostics["container"]["image_repository"] == "code.forgejo.org/forgejo/runner"
    assert diagnostics["container"]["image_tag"] == "latest"
    assert diagnostics["kubernetes"]["namespace"] == "ci"
    assert diagnostics["kubernetes"]["pod"] == "runner-0"
    assert diagnostics["attribution"]["status"] == "resolved"
  end

  test "a failed evaluation fails the batch, and redelivery evaluates each event once" do
    ScriptedStatefulAlertEngine.use_in_test([{:error, :engine_restarting}])
    event_uuid = Ash.UUID.generate()

    message =
      falco_message(%{
        "uuid" => event_uuid,
        "output" => "Synthetic ledger probe",
        "priority" => "Critical",
        "rule" => "Synthetic ledger probe #{event_uuid}",
        "time" => DateTime.to_iso8601(DateTime.utc_now()),
        "hostname" => "host01.example.com",
        "source" => "syscall"
      })

    # The event is stored, but its evaluation failed: the batch fails so
    # JetStream redelivers it.
    assert {:error, :engine_restarting} = FalcoEvents.process_batch([message])
    assert_receive {:evaluated, [%{id: ^event_uuid}]}

    # The redelivery stores nothing new, yet finishes the evaluation.
    assert {:ok, 0} = FalcoEvents.process_batch([message])
    assert_receive {:evaluated, [%{id: ^event_uuid}]}

    # Once evaluated, a further redelivery does not count the event again.
    assert {:ok, 0} = FalcoEvents.process_batch([message])
    refute_receive {:evaluated, _}
  end

  test "an overloaded evaluation is acknowledged past max_deliver and admitted later in order" do
    overloaded = {:error, {:overloaded, :rule_bytes}}
    ScriptedStatefulAlertEngine.use_in_test([overloaded, overloaded])
    parent = self()
    event_uuid = Ash.UUID.generate()

    raw =
      falco_message(%{
        "uuid" => event_uuid,
        "output" => "Synthetic overload probe",
        "priority" => "Critical",
        "rule" => "Synthetic overload probe #{event_uuid}",
        "time" => DateTime.to_iso8601(DateTime.utc_now()),
        "hostname" => "host01.example.com",
        "source" => "syscall"
      })

    # Every delivery up to and past the consumer's max_deliver is acknowledged:
    # the refused evaluation waits in the durable backlog, never in JetStream.
    for delivery_count <- 1..6 do
      message = %Broadway.Message{
        data: raw.data,
        metadata:
          Map.merge(raw.metadata, %{
            jetstream_ack: %{
              stream: "falco",
              consumer: "consumer",
              delivery_count: delivery_count
            },
            max_deliver: 5
          }),
        acknowledger:
          {Pipeline, :ack_ref,
           %{
             ack_fun: fn action ->
               send(parent, {:ack_action, delivery_count, action})
               :ok
             end
           }}
      }

      assert [%Broadway.Message{status: :ok} = acked] =
               Pipeline.handle_batch(:falco, [message], %{batch_key: :default}, %{})

      assert :ok = Pipeline.ack(:ack_ref, [acked], [])
      assert_receive {:ack_action, ^delivery_count, :ack}
    end

    refute_receive {:ack_action, _delivery, :term}, 50
    refute_receive {:ack_action, _delivery, {:nack, _delay}}, 50

    # Only the first delivery reached the engine; the rest found the events
    # already queued.
    assert_receive {:evaluated, [%{id: ^event_uuid} = refused]}
    refute_receive {:evaluated, _events}, 50
    assert stored_event_count(event_uuid) == 1
    assert pending_admission_count(event_uuid) == 1

    # The drain retries the backlog; a still-refused admission keeps its row.
    assert :ok = LifecycleAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    assert_receive {:evaluated, [%{id: ^event_uuid}]}
    assert pending_admission_count(event_uuid) == 1

    assert :ok = LifecycleAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    assert_receive {:evaluated, [%{id: ^event_uuid} = admitted]}

    assert Map.take(admitted, [:class_uid, :severity_id, :message]) ==
             Map.take(refused, [:class_uid, :severity_id, :message])

    assert pending_admission_count(event_uuid) == 0
    assert stored_event_count(event_uuid) == 1

    assert :ok = LifecycleAdmissionDrainWorker.perform(%Oban.Job{args: %{}})
    refute_receive {:evaluated, _events}, 50
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
    TestSupport.complete_alert_effects!()

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

  defp stored_event_count(event_uuid) do
    %{rows: [[count]]} =
      SQL.query!(Repo, "SELECT count(*) FROM platform.ocsf_events WHERE id = $1::uuid", [
        Ecto.UUID.dump!(event_uuid)
      ])

    count
  end

  defp pending_admission_count(event_uuid) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM platform.lifecycle_pending_admissions WHERE event_id = $1::uuid",
        [Ecto.UUID.dump!(event_uuid)]
      )

    count
  end

  defp falco_message(payload) do
    %{
      data: Jason.encode!(payload),
      metadata: %{subject: "falco.logs", received_at: DateTime.utc_now()}
    }
  end

  # These tests are about persistence, so the stateful alert engine is stubbed:
  # evaluation succeeds without loading or firing real rules.
  defp with_stubbed_alert_engine(fun) do
    ScriptedStatefulAlertEngine.use_in_test()
    fun.()
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
