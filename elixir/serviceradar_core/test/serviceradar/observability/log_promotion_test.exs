defmodule ServiceRadar.Observability.LogPromotionTest.AcknowledgingEngine do
  @moduledoc false
  use GenServer

  def start_link(test_pid) do
    GenServer.start_link(__MODULE__, test_pid,
      name: ServiceRadar.ProcessRegistry.via(:stateful_alert_engine)
    )
  end

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_call({:evaluate_events, events}, from, test_pid) do
    send(test_pid, {:evaluation_requested, from, events})
    {:noreply, test_pid}
  end
end

defmodule ServiceRadar.Observability.LogPromotionTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL, as: SQL
  alias Postgrex.Result
  alias ServiceRadar.EventWriter.Processors.K8sNodes
  alias ServiceRadar.EventWriter.Processors.Logs
  alias ServiceRadar.NATS.DurablePublishWorker
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Observability.LogPromotionTest.AcknowledgingEngine
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ScriptedStatefulAlertEngine

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    :ok
  end

  test "evaluates each promoted event once, however often its log is promoted" do
    configure_scripted_engine([])
    log = create_queue_probe("evaluate-once")

    assert {:ok, 1} = LogPromotion.promote([log])
    assert_receive {:evaluated, [%{id: event_id}]}

    # A redelivered log promotes to the same event id: nothing new is stored
    # and the event is not evaluated again.
    assert {:ok, 0} = LogPromotion.promote([log])
    refute_receive {:evaluated, _}
    assert event_id
  end

  test "an engine failure fails the promotion, and the retry evaluates the event" do
    configure_scripted_engine([{:error, :engine_restarting}])
    log = create_queue_probe("engine-failure")

    assert {:error, :engine_restarting} = LogPromotion.promote([log])
    assert_receive {:evaluated, [%{id: event_id}]}

    assert {:ok, 0} = LogPromotion.promote([log])
    assert_receive {:evaluated, [%{id: ^event_id}]}

    assert {:ok, 0} = LogPromotion.promote([log])
    refute_receive {:evaluated, _}
  end

  test "a failed evaluation defers the promotion alert to the retry, which raises it once" do
    configure_scripted_engine([{:error, :engine_restarting}])
    label = "deferred-alert-#{Ash.UUID.generate()}"
    log = create_queue_probe(label, nil, true)
    LogPromotion.invalidate_rules_cache()

    assert {:error, :engine_restarting} = LogPromotion.promote([log])
    assert alert_count("test.#{label}") == 0

    assert {:ok, 0} = LogPromotion.promote([log])
    assert alert_count("test.#{label}") == 1

    assert {:ok, 0} = LogPromotion.promote([log])
    assert alert_count("test.#{label}") == 1
  end

  test "node transitions commit with their publish queued, and evaluation is retried by redelivery" do
    use_single_engine_shard()
    subject = ServiceRadar.NATS.Channels.build("logs.internal.k8s")
    create_queue_probe("node-ack", subject)
    LogPromotion.invalidate_rules_cache()
    start_supervised!({AcknowledgingEngine, self()})

    cluster = "cluster-#{Ash.UUID.generate()}"
    initial_time = ~U[2026-09-05 12:00:00.000000Z]

    initial = %{
      data: %{
        "cluster_id" => cluster,
        "generated_at" => initial_time,
        "nodes" => [%{"name" => "node1.example.com", "ready" => true}]
      }
    }

    down = %{
      data: %{
        initial.data
        | "generated_at" => DateTime.add(initial_time, 1, :second),
          "nodes" => [%{"name" => "node1.example.com", "ready" => false}]
      }
    }

    assert {:ok, 1} = K8sNodes.process_batch([initial])

    # The transition is published from inside the snapshot transaction, so it
    # is queued with the snapshot and published only after both commit.
    assert {:ok, 1} = K8sNodes.process_batch([down])

    assert %{rows: [[false]]} =
             Repo.query!(
               "SELECT ready FROM platform.k8s_nodes_current WHERE cluster_id = $1",
               [cluster]
             )

    refute_receive {:evaluation_requested, _, _}
    publish = Task.async(fn -> publish_queued(subject) end)

    # The logs batch carrying the transition fails its evaluation...
    assert_receive {:evaluation_requested, from, [%{id: event_id}]}, 2_000
    GenServer.reply(from, {:error, :engine_restarting})

    # ...and its redelivery evaluates the same event again.
    assert_receive {:evaluation_requested, retry_from, [%{id: ^event_id}]}, 2_000
    GenServer.reply(retry_from, :ok)

    assert [:ok] = Task.await(publish, 5_000)
    refute_receive {:evaluation_requested, _, _}
  end

  test "log ingestion propagates promotion evaluation failures" do
    configure_scripted_engine([{:error, :evaluation_failed}])
    log = create_queue_probe("promotion-failure")
    subject = get_in(log, [:attributes, "serviceradar", "ingest", "subject"])

    message = %{
      data: Jason.encode!(Map.delete(log, :created_at)),
      metadata: %{subject: subject}
    }

    assert {:error, :evaluation_failed} = Logs.process_batch([message])
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

  test "logs processor promotes its generated UUID bytes as canonical text" do
    actor = %{id: "system", role: :admin}
    subject = "logs.processor-binary-id.#{System.unique_integer([:positive])}"
    log_name = "test.processor_binary_id.#{Ash.UUID.generate()}"
    body = "processor raw UUID log ID #{Ash.UUID.generate()}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "processor-binary-log-id-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => subject},
          event: %{"log_name" => log_name, "alert" => false}
        },
        actor: actor
      )
      |> Ash.create()

    message = %{
      data:
        Jason.encode!(%{
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "severity_text" => "INFO",
          "severity_number" => 11,
          "body" => body,
          "service_name" => "test"
        }),
      metadata: %{subject: subject, received_at: DateTime.utc_now()}
    }

    assert %{id: generated_id} = Logs.parse_message(message)
    assert is_binary(generated_id)
    assert byte_size(generated_id) == 16

    assert {:ok, 1} = Logs.process_batch([message])

    assert %Result{rows: [[canonical_log_id]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM logs WHERE body = $1 ORDER BY timestamp DESC LIMIT 1",
               [body]
             )

    metadata = promoted_metadata(log_name, body)

    assert {:ok, persisted_binary_id} = Ecto.UUID.dump(canonical_log_id)
    assert byte_size(persisted_binary_id) == byte_size(generated_id)
    assert metadata["correlation_uid"] == canonical_log_id
    assert metadata["serviceradar"]["source_log_id"] == canonical_log_id
    assert Jason.encode!(metadata)
  end

  test "preserves text IDs and injectively encodes invalid binary IDs" do
    actor = %{id: "system", role: :admin}
    subject = "logs.source-id.#{System.unique_integer([:positive])}"
    log_name = "test.source_id.#{Ash.UUID.generate()}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "source-log-id-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => subject},
          event: %{"log_name" => log_name, "alert" => false}
        },
        actor: actor
      )
      |> Ash.create()

    base_log = %{
      id: "source-log-id-01",
      timestamp: DateTime.utc_now(),
      severity_text: "INFO",
      severity_number: 11,
      body: "sixteen byte text log ID",
      service_name: "test",
      attributes: %{"serviceradar" => %{"ingest" => %{"subject" => subject}}},
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }

    assert byte_size(base_log.id) == 16
    assert {:ok, 1} = LogPromotion.promote([base_log])

    metadata = promoted_metadata(log_name, base_log.body)

    assert metadata["correlation_uid"] == base_log.id
    assert metadata["serviceradar"]["source_log_id"] == base_log.id

    canonical_uuid = Ecto.UUID.generate()
    canonical_uuid_log = %{base_log | id: canonical_uuid, body: "canonical UUID text log ID"}

    assert {:ok, 1} = LogPromotion.promote([canonical_uuid_log])
    metadata = promoted_metadata(log_name, canonical_uuid_log.body)
    assert metadata["correlation_uid"] == canonical_uuid
    assert metadata["serviceradar"]["source_log_id"] == canonical_uuid

    invalid_binary_log = %{base_log | id: <<0xFF, 0x00, 0x80>>, body: "invalid binary log ID"}

    assert {:ok, 1} = LogPromotion.promote([invalid_binary_log])

    metadata = promoted_metadata(log_name, invalid_binary_log.body)
    encoded_binary_id = "urn:serviceradar:log-id:binary:v1:ff0080"

    assert metadata["correlation_uid"] == encoded_binary_id
    assert metadata["serviceradar"]["source_log_id"] == encoded_binary_id
    assert Jason.encode!(metadata)

    fallback_looking_text_log = %{
      base_log
      | id: "binary:ff0080",
        body: "fallback-looking text log ID"
    }

    assert {:ok, 1} = LogPromotion.promote([fallback_looking_text_log])
    metadata = promoted_metadata(log_name, fallback_looking_text_log.body)
    assert metadata["correlation_uid"] == fallback_looking_text_log.id
    refute metadata["correlation_uid"] == encoded_binary_id

    reserved_text_log = %{
      base_log
      | id: encoded_binary_id,
        body: "reserved namespace text log ID"
    }

    assert {:ok, 1} = LogPromotion.promote([reserved_text_log])
    metadata = promoted_metadata(log_name, reserved_text_log.body)

    escaped_text_id =
      "urn:serviceradar:log-id:text:v1:" <>
        Base.url_encode64(reserved_text_log.id, padding: false)

    assert metadata["correlation_uid"] == escaped_text_id
    assert metadata["serviceradar"]["source_log_id"] == escaped_text_id
    refute metadata["correlation_uid"] == encoded_binary_id
    assert Jason.encode!(metadata)
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

  defp promoted_metadata(log_name, message) do
    assert %Result{rows: [[metadata]]} =
             SQL.query!(
               Repo,
               """
               SELECT metadata
               FROM ocsf_events
               WHERE log_name = $1 AND message = $2
               ORDER BY time DESC
               LIMIT 1
               """,
               [log_name, message]
             )

    metadata
  end

  defp configure_scripted_engine(replies), do: ScriptedStatefulAlertEngine.use_in_test(replies)

  # Runs this test's queued publishes on `subject` as the outbox worker would,
  # and nothing another test left in the queue.
  defp publish_queued(subject) do
    from(j in Oban.Job,
      where:
        j.queue == "events" and j.state == "available" and
          j.worker == ^Oban.Worker.to_string(DurablePublishWorker) and
          fragment("?->>'subject' = ?", j.args, ^subject)
    )
    |> Repo.all(prefix: "platform")
    |> Enum.map(&DurablePublishWorker.perform/1)
  end

  # The acknowledging stub registers as the single engine shard, so every
  # evaluation reaches it.
  defp use_single_engine_shard do
    previous_shards = Application.get_env(:serviceradar_core, :stateful_alert_engine_shards)
    TestSupport.drain_stateful_alert_engines()
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 1)

    on_exit(fn ->
      TestSupport.drain_stateful_alert_engines()
      restore_env(:stateful_alert_engine_shards, previous_shards)
    end)
  end

  defp alert_count(log_name) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM alerts a JOIN ocsf_events e ON a.event_id = e.id WHERE e.log_name = $1",
        [log_name]
      )

    count
  end

  defp create_queue_probe(label, subject \\ nil, alert? \\ false) do
    actor = %{id: "system", role: :admin}
    subject = subject || "logs.#{label}.#{System.unique_integer([:positive])}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{label}-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => subject},
          event: %{"log_name" => "test.#{label}", "alert" => alert?}
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
