defmodule ServiceRadar.Observability.LogPromotionTest.BlockingAlertQueue do
  @moduledoc false

  def enqueue_events(events) do
    test_pid = Application.fetch_env!(:serviceradar_core, :log_promotion_queue_test_pid)
    send(test_pid, {:stateful_alert_enqueue_started, self(), events})

    receive do
      :release_stateful_alert_enqueue -> :ok
    after
      5_000 -> {:error, :blocking_alert_queue_timeout}
    end
  end
end

defmodule ServiceRadar.Observability.LogPromotionTest.RejectingAlertQueue do
  @moduledoc false

  def enqueue_events(events) do
    test_pid = Application.fetch_env!(:serviceradar_core, :log_promotion_queue_test_pid)
    reason = Application.fetch_env!(:serviceradar_core, :log_promotion_queue_rejection)
    send(test_pid, {:stateful_alert_enqueue_rejected, reason, events})
    {:error, reason}
  end
end

defmodule ServiceRadar.Observability.LogPromotionTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL, as: SQL
  alias Postgrex.Result
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Observability.LogPromotionTest.BlockingAlertQueue
  alias ServiceRadar.Observability.LogPromotionTest.RejectingAlertQueue
  alias ServiceRadar.ProcessRegistry
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

  test "waits for the configured stateful alert queue admission" do
    actor = %{id: "system", role: :admin}
    previous_queue = Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)

    Application.put_env(:serviceradar_core, :stateful_alert_evaluation_queue, BlockingAlertQueue)
    Application.put_env(:serviceradar_core, :log_promotion_queue_test_pid, self())

    on_exit(fn ->
      case previous_queue do
        nil -> Application.delete_env(:serviceradar_core, :stateful_alert_evaluation_queue)
        value -> Application.put_env(:serviceradar_core, :stateful_alert_evaluation_queue, value)
      end

      Application.delete_env(:serviceradar_core, :log_promotion_queue_test_pid)
    end)

    subject = "logs.queue-test.#{System.unique_integer([:positive])}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "queue-admission-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => subject},
          event: %{"log_name" => "test.queue.admission", "alert" => false}
        },
        actor: actor
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "INFO",
      severity_number: 11,
      body: "queue admission probe",
      service_name: "test",
      attributes: %{"serviceradar" => %{"ingest" => %{"subject" => subject}}},
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }

    promotion_task = Task.async(fn -> LogPromotion.promote([log]) end)

    assert_receive {:stateful_alert_enqueue_started, queue_pid, [_event]}, 2_000
    assert Task.yield(promotion_task, 0) == nil

    send(queue_pid, :release_stateful_alert_enqueue)
    assert Task.await(promotion_task, 2_000) == {:ok, 1}
  end

  test "falls back to synchronous evaluation when the queue is full" do
    configure_rejecting_alert_queue(:stateful_alert_evaluation_queue_full)
    log = create_queue_probe("queue-full")

    assert {:ok, 1} = LogPromotion.promote([log])
    assert_receive {:stateful_alert_enqueue_rejected, :stateful_alert_evaluation_queue_full, [_]}
    assert [{pid, _metadata}] = ProcessRegistry.lookup(:stateful_alert_engine)
    assert Process.alive?(pid)
  end

  test "falls back to synchronous evaluation when the queue is unavailable" do
    configure_rejecting_alert_queue(:stateful_alert_evaluation_queue_unavailable)
    log = create_queue_probe("queue-unavailable")

    assert {:ok, 1} = LogPromotion.promote([log])

    assert_receive {:stateful_alert_enqueue_rejected,
                    :stateful_alert_evaluation_queue_unavailable, [_]}

    assert [{pid, _metadata}] = ProcessRegistry.lookup(:stateful_alert_engine)
    assert Process.alive?(pid)
  end

  test "does not duplicate evaluation after an ambiguous queue timeout" do
    configure_rejecting_alert_queue(:stateful_alert_evaluation_queue_timeout)
    log = create_queue_probe("queue-timeout")

    assert {:ok, 1} = LogPromotion.promote([log])

    assert_receive {:stateful_alert_enqueue_rejected, :stateful_alert_evaluation_queue_timeout,
                    [_]}

    assert ProcessRegistry.lookup(:stateful_alert_engine) == []
  end

  test "does not duplicate evaluation after an ambiguous queue exit" do
    reason = {:stateful_alert_evaluation_queue_unavailable, :shutdown}
    configure_rejecting_alert_queue(reason)
    log = create_queue_probe("queue-exit")

    assert {:ok, 1} = LogPromotion.promote([log])
    assert_receive {:stateful_alert_enqueue_rejected, ^reason, [_]}
    assert ProcessRegistry.lookup(:stateful_alert_engine) == []
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
            "subject_prefix" => "logs.",
            "event_type" => "waf.finding"
          },
          event: %{
            "log_name" => "security.waf.finding",
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

  test "promotes CopyFail Falco logs with incident grouping metadata" do
    actor = %{id: "system", role: :admin}
    message = "AF_ALG socket created in container proc=python k8s_pod_name=api-1"
    rule_name = "copyfail-falco-test-#{Ash.UUID.generate()}"
    falco_rule = "Copy Fail AF_ALG Socket Created In Container"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: rule_name,
          source_type: :log,
          source: %{},
          match: %{
            "subject_prefix" => "falco.",
            "service_name" => "falco",
            "attribute_equals" => %{
              "falco.rule" => falco_rule
            }
          },
          event: %{
            "log_name" => "falco.copyfail.af_alg",
            "severity" => "critical",
            "alert" => false
          }
        },
        actor: actor
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "Critical",
      severity_number: 21,
      body: message,
      service_name: "falco",
      service_instance: "k8s-worker-1",
      attributes: %{
        "falco" => %{
          "uuid" => "copyfail-test-1",
          "rule" => falco_rule,
          "priority" => "Critical",
          "output" => message,
          "output_fields" => %{
            "container.name" => "api",
            "k8s.ns.name" => "demo",
            "k8s.pod.name" => "api-1"
          }
        },
        "serviceradar" => %{"ingest" => %{"subject" => "falco.logs.processed"}}
      },
      resource_attributes: %{
        "host.name" => "k8s-worker-1",
        "k8s.namespace.name" => "demo",
        "k8s.pod.name" => "api-1",
        "container.name" => "api"
      },
      created_at: DateTime.utc_now()
    }

    assert {:ok, 1} = LogPromotion.promote([log])

    assert %Result{rows: [[severity, metadata, observables, unmapped]]} =
             SQL.query!(
               Repo,
               """
               SELECT severity, metadata, observables, unmapped
               FROM ocsf_events
               WHERE log_name = $1 AND message = $2
               ORDER BY time DESC
               LIMIT 1
               """,
               ["falco.copyfail.af_alg", message]
             )

    assert severity == "Critical"
    assert metadata["security_signal"]["kind"] == "runtime"
    assert metadata["security_signal"]["source"] == "falco"
    assert metadata["security_signal"]["rule"] == falco_rule
    assert metadata["rule"] == falco_rule
    assert metadata["hostname"] == "k8s-worker-1"
    assert %{"name" => falco_rule, "type" => "Falco Rule", "type_id" => 99} in observables
    assert %{"name" => "api-1", "type" => "Kubernetes Pod", "type_id" => 99} in observables
    assert unmapped["falco"]["rule"] == falco_rule
    assert unmapped["falco"]["hostname"] == "k8s-worker-1"
  end

  test "promotes Falco drop-and-execute logs with runtime diagnostics and partial attribution" do
    actor = %{id: "system", role: :admin}
    message = "File below a known binary directory opened for writing then executed"
    rule_name = "drop-execute-falco-test-#{Ash.UUID.generate()}"
    falco_rule = "Drop and execute new binary in container"
    container_id = "d2d34c8e90ab1234567890abcdef1234567890abcdef1234567890abcdef1234"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: rule_name,
          source_type: :log,
          source: %{},
          match: %{
            "subject_prefix" => "falco.",
            "service_name" => "falco",
            "attribute_equals" => %{
              "falco.rule" => falco_rule
            }
          },
          event: %{
            "log_name" => "falco.drop_execute",
            "severity" => "critical",
            "alert" => false
          }
        },
        actor: actor
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "Critical",
      severity_number: 21,
      body: message,
      service_name: "falco",
      service_instance: "k8s-cp2-worker2",
      attributes: %{
        "falco" => %{
          "uuid" => "drop-execute-test-1",
          "rule" => falco_rule,
          "priority" => "Critical",
          "output" => message,
          "output_fields" => %{
            "container.id" => container_id,
            "container.image.repository" => "code.forgejo.org/forgejo/runner",
            "container.image.tag" => "latest",
            "container.name" => "forgejo-runner",
            "evt.arg.flags" => "O_RDONLY|O_CLOEXEC",
            "evt.type" => "execve",
            "hostname" => "k8s-cp2-worker2",
            "proc.cmdline" => "/tmp/.build/tool --lint",
            "proc.cwd" => "/workspace/carverauto/serviceradar",
            "proc.exe" => "/tmp/.build/tool",
            "proc.is_exe_from_memfd" => false,
            "proc.is_exe_upper_layer" => true,
            "proc.name" => "tool",
            "proc.pname" => "bash",
            "user.name" => "root",
            "user.uid" => 0
          }
        },
        "serviceradar" => %{"ingest" => %{"subject" => "falco.logs.processed"}}
      },
      resource_attributes: %{
        "host.name" => "k8s-cp2-worker2",
        "container.id" => container_id,
        "container.name" => "forgejo-runner"
      },
      created_at: DateTime.utc_now()
    }

    assert {:ok, 1} = LogPromotion.promote([log])

    assert %Result{rows: [[metadata, observables, unmapped]]} =
             SQL.query!(
               Repo,
               """
               SELECT metadata, observables, unmapped
               FROM ocsf_events
               WHERE log_name = $1 AND message = $2
               ORDER BY time DESC
               LIMIT 1
               """,
               ["falco.drop_execute", message]
             )

    diagnostics = metadata["security_signal"]["diagnostics"]

    assert diagnostics["rule"]["name"] == falco_rule
    assert diagnostics["host"]["name"] == "k8s-cp2-worker2"
    assert diagnostics["process"]["name"] == "tool"
    assert diagnostics["process"]["command"] == "/tmp/.build/tool --lint"
    assert diagnostics["process"]["cwd"] == "/workspace/carverauto/serviceradar"
    assert diagnostics["process"]["executable_flags"]["upper_layer"] == true
    assert diagnostics["process"]["executable_flags"]["from_memfd"] == false
    assert diagnostics["parent_process"]["name"] == "bash"
    assert diagnostics["user"]["name"] == "root"
    assert diagnostics["container"]["id"] == container_id
    assert diagnostics["container"]["image_repository"] == "code.forgejo.org/forgejo/runner"
    assert diagnostics["container"]["image_tag"] == "latest"
    assert diagnostics["attribution"]["status"] == "partial"
    assert "kubernetes.namespace" in diagnostics["attribution"]["missing"]
    assert "kubernetes.pod" in diagnostics["attribution"]["missing"]

    assert %{"name" => container_id, "type" => "Container ID", "type_id" => 99} in observables
    assert unmapped["falco"]["diagnostics"] == diagnostics
    assert unmapped["falco"]["output_fields"]["proc.cmdline"] == "/tmp/.build/tool --lint"
  end

  defp configure_rejecting_alert_queue(reason) do
    previous_queue = Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)
    previous_reason = Application.get_env(:serviceradar_core, :log_promotion_queue_rejection)
    previous_test_pid = Application.get_env(:serviceradar_core, :log_promotion_queue_test_pid)
    previous_shards = Application.get_env(:serviceradar_core, :stateful_alert_engine_shards)

    TestSupport.drain_stateful_alert_engines()
    Application.put_env(:serviceradar_core, :stateful_alert_evaluation_queue, RejectingAlertQueue)
    Application.put_env(:serviceradar_core, :log_promotion_queue_rejection, reason)
    Application.put_env(:serviceradar_core, :log_promotion_queue_test_pid, self())
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 1)

    on_exit(fn ->
      TestSupport.drain_stateful_alert_engines()
      restore_env(:stateful_alert_evaluation_queue, previous_queue)
      restore_env(:log_promotion_queue_rejection, previous_reason)
      restore_env(:log_promotion_queue_test_pid, previous_test_pid)
      restore_env(:stateful_alert_engine_shards, previous_shards)
    end)
  end

  defp create_queue_probe(label) do
    actor = %{id: "system", role: :admin}
    subject = "logs.#{label}.#{System.unique_integer([:positive])}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{label}-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => subject},
          event: %{"log_name" => "test.#{label}", "alert" => false}
        },
        actor: actor
      )
      |> Ash.create()

    %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "INFO",
      severity_number: 11,
      body: "queue rejection probe",
      service_name: "test",
      attributes: %{"serviceradar" => %{"ingest" => %{"subject" => subject}}},
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
