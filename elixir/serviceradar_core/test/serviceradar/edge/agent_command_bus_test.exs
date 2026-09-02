defmodule ServiceRadar.Edge.AgentCommandBusTest do
  @moduledoc """
  Integration tests for command bus dispatch, status updates, and push-config delivery.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.AgentCommands.ResultCoordinationTaskSupervisor
  alias ServiceRadar.AgentCommands.StatusHandler
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  defmodule TestControlSession do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: opts[:test_pid],
         agent_id: opts[:agent_id],
         partition_id: opts[:partition_id],
         ack_before_reply?: Keyword.get(opts, :ack_before_reply?, false),
         auto_result?: Keyword.get(opts, :auto_result?, false),
         marker: Keyword.get(opts, :marker)
       }}
    end

    @impl true
    def handle_call({:send_command, command, context}, _from, state) do
      if state.marker do
        send(state.test_pid, {:send_command, state.marker, command, context})
      else
        send(state.test_pid, {:send_command, command, context})
      end

      maybe_ack_before_reply(command, state)
      maybe_broadcast_result(command, context, state)
      {:reply, {:ok, command.command_id}, state}
    end

    @impl true
    def handle_call({:push_config, response}, _from, state) do
      send(state.test_pid, {:push_config, response})
      {:reply, :ok, state}
    end

    @impl true
    def handle_call({:send_console_frame, frame}, _from, state) do
      send(state.test_pid, {:send_console_frame, state.marker, frame, nil})
      {:reply, :ok, state}
    end

    @impl true
    def handle_call({:send_console_frame, frame, evidence}, _from, state) do
      send(state.test_pid, {:send_console_frame, state.marker, frame, evidence})
      {:reply, :ok, state}
    end

    defp maybe_ack_before_reply(command, %{ack_before_reply?: true} = state) do
      send(
        StatusHandler,
        {:command_ack,
         %{
           command_id: command.command_id,
           command_type: command.command_type,
           agent_id: state.agent_id,
           partition_id: state.partition_id,
           message: "ack"
         }}
      )

      Process.sleep(25)
    end

    defp maybe_ack_before_reply(_command, _state), do: :ok

    defp maybe_broadcast_result(command, context, %{auto_result?: true} = state) do
      Task.start(fn ->
        Process.sleep(25)

        result = %{
          command_id: command.command_id,
          command_type: command.command_type,
          agent_id: state.agent_id,
          partition_id: state.partition_id,
          response_subject: Map.get(context, :response_subject),
          success: true,
          message: "done",
          payload: %{
            "agent_id" => state.agent_id,
            "matched" => true,
            "match_count" => 1,
            "freshness" => %{
              "verdict" => "fresh",
              "age_seconds" => 1,
              "stale_threshold_seconds" => 3600
            }
          }
        }

        # Ingress is what a real agent publishes. Command-scoped fan-out is what
        # collect_endpoint_inventory_cohort_results/2 actually waits on, and in
        # production that happens only after StatusHandler persists. The test
        # helper publishes both so aggregation does not stall behind a named
        # GenServer that integration shards share, or behind an ExUnit timeout
        # equal to the collect ceiling.
        AgentCommandPubSub.broadcast_result(result)
        AgentCommandPubSub.broadcast_persisted_result(result)
      end)
    end

    defp maybe_broadcast_result(_command, _context, _state), do: :ok
  end

  defmodule CrashingControlSession do
    @moduledoc false
    use GenServer

    def start(opts) do
      GenServer.start(__MODULE__, opts, name: opts[:name])
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:push_config, _response}, _from, state) do
      {:stop, :shutdown, state}
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    if :ets.whereis(RateLimiter.__table__()) != :undefined do
      :ets.delete_all_objects(RateLimiter.__table__())
    end

    agent_id = "agent-#{System.unique_integer([:positive])}"
    actor = SystemActor.system(:agent_command_bus_test)
    {:ok, agent_id: agent_id, actor: actor}
  end

  describe "offline dispatch" do
    test "rejects hidden transmit payloads containing credential material", %{
      agent_id: agent_id,
      actor: actor
    } do
      command_type = "test.secret_transmit"

      assert {:error, :sensitive_transmit_payload_denied} =
               AgentCommandBus.dispatch(agent_id, command_type, %{"credential_ref" => "safe"},
                 transmit_payload: %{"api_token" => "PVEAPIToken=root@pam!sr=secret"}
               )

      commands =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == ^command_type)
        |> Ash.read!(actor: actor)

      assert commands == []
    end

    test "fails fast and marks command offline", %{agent_id: agent_id, actor: actor} do
      command_type = "test.offline"

      assert {:error, {:agent_offline, ^agent_id}} =
               AgentCommandBus.dispatch(agent_id, command_type, %{reason: "offline"})

      command =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == ^command_type)
        |> Ash.read!(actor: actor)
        |> List.first()

      assert command
      assert command.status == :offline
      assert command.failure_reason == "agent_offline"
    end
  end

  describe "online command agents" do
    test "lists only active control-stream sessions", %{agent_id: agent_id} do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      agents = AgentCommandBus.list_online_agents()

      assert Enum.any?(agents, fn agent ->
               agent.agent_id == agent_id and
                 agent.partition_id == "default" and
                 "mtr" in agent.capabilities
             end)
    end

    test "returns gateway-observed control capability and config evidence", %{agent_id: agent_id} do
      fingerprint = String.duplicate("a", 64)

      {_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{
            partition_id: "default",
            gateway_node: "gateway@policy",
            capabilities: [
              "plugin-host-authority:v1",
              "proxmox-console-policy-binding:v1"
            ],
            config_version: "config-policy-7",
            applied_plugin_assignments: [
              %{
                assignment_id: "assignment-1",
                plugin_id: "proxmox-console",
                assignment_policy_version: 7,
                assignment_policy_fingerprint: fingerprint
              }
            ]
          },
          registry_key: {:agent_control, agent_id, :policy_gateway}
        )

      assert {:ok, evidence} =
               AgentCommandBus.resolve_control_session_evidence(agent_id, "gateway@policy")

      assert evidence.gateway_node == "gateway@policy"
      assert is_pid(evidence.control_session_pid)
      assert evidence.agent_id == agent_id
      assert evidence.config_version == "config-policy-7"
      assert evidence.pending_config_version == nil
      assert "proxmox-console-policy-binding:v1" in evidence.capabilities

      assert [
               %{
                 assignment_id: "assignment-1",
                 assignment_policy_version: 7,
                 assignment_policy_fingerprint: ^fingerprint
               }
             ] = evidence.applied_plugin_assignments
    end

    test "same agent and gateway coexist across partitions and exact dispatch selects the requested principal",
         %{agent_id: agent_id} do
      {farm_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{partition_id: "farm01", gateway_node: "gateway@shared"},
          registry_key: {:agent_control, agent_id, :shared_gateway},
          marker: :farm
        )

      {tonka_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{partition_id: "tonka01", gateway_node: "gateway@shared"},
          registry_key: {:agent_control, agent_id, :shared_gateway},
          marker: :tonka
        )

      assert {:ok, %{control_session_pid: ^farm_pid, partition_id: "farm01"}} =
               AgentCommandBus.resolve_control_session_evidence(
                 "farm01",
                 agent_id,
                 "gateway@shared"
               )

      assert {:ok, %{control_session_pid: ^tonka_pid, partition_id: "tonka01"}} =
               AgentCommandBus.resolve_control_session_evidence(
                 "tonka01",
                 agent_id,
                 "gateway@shared"
               )

      assert {:error, {:agent_partition_ambiguous, ^agent_id}} =
               AgentCommandBus.resolve_control_session_evidence(agent_id)

      assert {:ok, _command_id} =
               AgentCommandBus.dispatch(
                 agent_id,
                 "test.partition_bound",
                 %{"partition_id" => "farm01"},
                 required_partition: "tonka01",
                 required_gateway_node: "gateway@shared"
               )

      assert_receive {:send_command, :tonka, %Monitoring.CommandRequest{}, _context}, 1_000
      refute_received {:send_command, :farm, _, _}
    end

    test "an evidence-bound console dispatch never repins to a replacement session", %{
      agent_id: agent_id
    } do
      {original_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{
            partition_id: "default",
            gateway_node: "gateway@policy",
            capabilities: ["proxmox-console-policy-binding:v1"],
            config_version: "config-policy-7",
            pending_config_version: nil,
            applied_plugin_assignments: []
          },
          registry_key: {:agent_control, agent_id, :original},
          marker: :original
        )

      assert {:ok, evidence} =
               AgentCommandBus.resolve_control_session_evidence(agent_id, "gateway@policy")

      assert evidence.control_session_pid == original_pid
      :ok = GenServer.stop(original_pid, :normal)

      {_replacement_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{
            partition_id: "default",
            gateway_node: "gateway@policy",
            capabilities: ["proxmox-console-policy-binding:v1"],
            config_version: "config-policy-7",
            pending_config_version: nil,
            applied_plugin_assignments: []
          },
          registry_key: {:agent_control, agent_id, :replacement},
          marker: :replacement
        )

      assert {:error, :control_session_unavailable} =
               AgentCommandBus.send_console_frame(
                 agent_id,
                 %{session_id: "session-1", frame_type: "open"},
                 required_gateway_node: "gateway@policy",
                 required_control_session_pid: evidence.control_session_pid,
                 required_control_evidence: evidence
               )

      refute_receive {:send_console_frame, :replacement, _frame, _evidence}, 50
    end
  end

  describe "command status updates" do
    test "endpoint inventory cache query dispatch uses typed payload and command-scoped response subject",
         %{agent_id: agent_id, actor: actor} do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["endpoint-inventory"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch_endpoint_inventory_cache_query(agent_id, %{
                 mode: "count",
                 predicate: %{name: "nginx"},
                 stale_threshold_seconds: 3600
               })

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "endpoint_inventory.cache_query"

      payload = Jason.decode!(command.payload_json)
      response_subject = "agent:commands:#{command.command_id}"

      assert command.command_id == uuid_text(command_id)
      assert payload["schema"] == "serviceradar.endpoint_inventory.query_request.v1"
      assert payload["mode"] == "count"
      assert payload["predicate"] == %{"name" => "nginx"}
      assert payload["stale_threshold_seconds"] == 3600
      assert payload["metadata"]["response_subject"] == response_subject
      assert context.response_subject == response_subject
      assert context.required_capability == "endpoint-inventory"

      command_record = wait_for_status(command_id, :sent, actor)
      assert command_record.command_type == "endpoint_inventory.cache_query"
    end

    test "endpoint inventory dispatch rejects SBOM bytes on command payload", %{
      agent_id: agent_id,
      actor: actor
    } do
      assert {:error, :endpoint_inventory_command_blob_payload_denied} =
               AgentCommandBus.dispatch(agent_id, "endpoint_inventory.cache_query", %{
                 "mode" => "exists",
                 "predicate" => %{"name" => "nginx"},
                 "sbom" => %{"components" => []}
               })

      assert {:error, :endpoint_inventory_command_blob_payload_denied} =
               AgentCommandBus.dispatch(agent_id, "endpoint_inventory.cache_query", %{
                 "mode" => "exists",
                 "metadata" => %{"artifact_json" => %{"components" => []}}
               })

      commands =
        AgentCommand
        |> Ash.Query.filter(
          agent_id == ^agent_id and command_type == "endpoint_inventory.cache_query"
        )
        |> Ash.read!(actor: actor)

      assert commands == []
    end

    test "endpoint inventory cohort cache query rejects target sets over the cap", %{
      agent_id: agent_id
    } do
      assert {:error,
              {:cohort_too_large,
               %{
                 targeted: 2,
                 cap: 1,
                 fallback: fallback
               }}} =
               AgentCommandBus.dispatch_endpoint_inventory_cohort_cache_query(
                 %{predicate: %{name: "nginx"}},
                 agent_ids: [agent_id, "agent-other"],
                 cohort_cap: 1
               )

      assert fallback =~ "SRQL"
    end

    @tag timeout: 120_000
    test "endpoint inventory cohort cache query aggregates command-scoped results", %{
      agent_id: agent_id
    } do
      ensure_status_handler_started()

      second_agent_id = "#{agent_id}-second"
      offline_agent_id = "#{agent_id}-offline"
      query_id = Ecto.UUID.generate()

      {_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{partition_id: "default", capabilities: ["endpoint-inventory"]},
          auto_result?: true
        )

      {_pid, _metadata} =
        start_control_session(
          second_agent_id,
          self(),
          %{partition_id: "default", capabilities: ["endpoint-inventory"]},
          auto_result?: true
        )

      assert {:ok, cohort} =
               AgentCommandBus.dispatch_endpoint_inventory_cohort_cache_query(
                 %{predicate: %{name: "nginx"}},
                 agent_ids: [agent_id, second_agent_id, offline_agent_id],
                 query_id: query_id,
                 # A CEILING, NOT A LATENCY ASSERTION, and deliberately far above what the
                 # round trip needs. What this test checks is coverage aggregation --
                 # answered vs offline vs expired -- and a result that arrives one
                 # millisecond late does not aggregate differently, it is counted as
                 # `expired` and the assertion reports a coverage bug that is not there.
                 #
                 # This is the second time the value has been raised. 5_000 was already a
                 # bump for "the round trip against remote CNPG", and it still failed with
                 # answered: 0, expired: 2 on a shard that had just ingested 50k devices
                 # into the same CNPG server: results fan out only after provenance
                 # validation AND durable persistence, so the deadline is really a bound on
                 # someone else's write throughput.
                 #
                 # Keep this below the ExUnit timeout. collect returns as soon as
                 # every expected command_id has answered, so a fast run never
                 # waits for this number. 60_000 equalled the default ExUnit
                 # budget and turned a missed fan-out into TimeoutError.
                 timeout_ms: 45_000,
                 cohort_concurrency: 2
               )

      assert cohort.query_id == query_id
      assert cohort.response_subject == AgentCommandPubSub.topic(query_id)
      assert cohort.command_type == "endpoint_inventory.cohort_cache_query"

      assert cohort.coverage == %{
               targeted: 3,
               answered: 2,
               offline: 1,
               expired: 0,
               pending: 0,
               complete?: true
             }

      assert Enum.count(cohort.dispatches, &(&1.status == :dispatched)) == 2
      assert Enum.count(cohort.results) == 2

      assert Enum.all?(
               cohort.results,
               &(&1.response_subject == AgentCommandPubSub.topic(query_id))
             )

      assert Enum.all?(cohort.results, &(&1.payload["match_count"] == 1))
    end

    test "endpoint inventory cache query persists command result lifecycle", %{
      agent_id: agent_id,
      actor: actor
    } do
      ensure_status_handler_started()

      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["endpoint-inventory"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch_endpoint_inventory_cache_query(agent_id, %{
                 mode: "exists",
                 predicate: %{name: "nginx"}
               })

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, _context}, 1_000

      AgentCommandPubSub.broadcast_result(%{
        command_id: command.command_id,
        command_type: command.command_type,
        agent_id: agent_id,
        partition_id: "default",
        success: true,
        message: "done",
        payload: %{
          "matched" => true,
          "match_count" => 1,
          "freshness" => %{"verdict" => "fresh"}
        }
      })

      command_record = wait_for_status(command_id, :completed, actor)
      assert command_record.result_payload["matched"] == true
      assert command_record.result_payload["match_count"] == 1
    end

    test "endpoint inventory force fresh requires permission before dispatch", %{
      agent_id: agent_id,
      actor: actor
    } do
      unauthorized_actor = %{id: "operator-no-force", role: :operator}

      assert {:error, :endpoint_inventory_force_fresh_unauthorized} =
               AgentCommandBus.dispatch_endpoint_inventory_force_fresh_scan(
                 agent_id,
                 %{sources: ["dpkg"]},
                 actor: unauthorized_actor
               )

      commands =
        AgentCommand
        |> Ash.Query.filter(
          agent_id == ^agent_id and command_type == "endpoint_inventory.force_fresh_scan"
        )
        |> Ash.read!(actor: actor)

      assert commands == []
    end

    test "endpoint inventory force fresh is rate limited before dispatch", %{
      agent_id: agent_id,
      actor: actor
    } do
      authorized_actor = %{id: "admin-force-rate", role: :admin}

      assert :ok =
               RateLimiter.check_and_record(
                 :endpoint_inventory_force_fresh_scan,
                 {agent_id, "admin-force-rate"},
                 limit: 1,
                 window_seconds: 60
               )

      assert {:error, {:rate_limited, :endpoint_inventory_force_fresh_scan, retry_after}} =
               AgentCommandBus.dispatch_endpoint_inventory_force_fresh_scan(
                 agent_id,
                 %{sources: ["dpkg"]},
                 actor: authorized_actor,
                 force_fresh_rate_limit: 1,
                 force_fresh_rate_window_seconds: 60
               )

      assert retry_after > 0

      commands =
        AgentCommand
        |> Ash.Query.filter(
          agent_id == ^agent_id and command_type == "endpoint_inventory.force_fresh_scan"
        )
        |> Ash.read!(actor: actor)

      assert commands == []
    end

    test "endpoint inventory force fresh dispatch is capacity limited", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["endpoint-inventory"]
        })

      authorized_actor = %{id: "admin-force", role: :admin}

      assert {:ok, first_command_id} =
               AgentCommandBus.dispatch_endpoint_inventory_force_fresh_scan(
                 agent_id,
                 %{sources: ["dpkg"]},
                 actor: authorized_actor
               )

      assert {:error, {:agent_busy, :endpoint_inventory_force_fresh_running}} =
               AgentCommandBus.dispatch_endpoint_inventory_force_fresh_scan(
                 agent_id,
                 %{sources: ["rpm"]},
                 actor: authorized_actor
               )

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      payload = Jason.decode!(command.payload_json)

      assert command.command_type == "endpoint_inventory.force_fresh_scan"
      assert payload["authorized"] == true
      assert payload["sources"] == ["dpkg"]
      assert payload["metadata"]["response_subject"] == "agent:commands:#{command.command_id}"
      assert context.required_capability == "endpoint-inventory"

      _command_record = wait_for_status(first_command_id, :sent, actor)
    end

    test "ack, progress, and result persist lifecycle", %{agent_id: agent_id, actor: actor} do
      ensure_status_handler_started()

      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mapper"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch(agent_id, "test.run", %{payload: "ok"})

      command = wait_for_status(command_id, :sent, actor)
      assert command.agent_id == agent_id

      send(
        StatusHandler,
        {:command_ack,
         %{
           command_id: command_id,
           command_type: "test.run",
           agent_id: agent_id,
           partition_id: "default",
           message: "ack"
         }}
      )

      command = wait_for_status(command_id, :acknowledged, actor)
      assert command.message == "ack"

      send(
        StatusHandler,
        {:command_progress,
         %{
           command_id: command_id,
           command_type: "test.run",
           agent_id: agent_id,
           partition_id: "default",
           message: "running",
           progress_percent: 42
         }}
      )

      command = wait_for_status(command_id, :running, actor)
      assert command.progress_percent == 42

      send(
        StatusHandler,
        {:command_result,
         %{
           command_id: command_id,
           command_type: "test.run",
           agent_id: agent_id,
           partition_id: "default",
           success: true,
           message: "done",
           payload: %{"ok" => true}
         }}
      )

      command = wait_for_status(command_id, :completed, actor)
      assert command.message == "done"
      assert command.result_payload == %{"ok" => true}
    end

    test "status handler normalizes JSON string payloads before persisting", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mapper"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch(agent_id, "test.run", %{payload: "ok"})

      _command = wait_for_status(command_id, :sent, actor)

      progress_payload = Jason.encode!(%{"completed_targets" => 2, "total_targets" => 4})
      result_payload = Jason.encode!(%{"completed_targets" => 4, "failed_targets" => 0})

      assert {:noreply, %{actor: ^actor}} =
               StatusHandler.handle_info(
                 {:command_progress,
                  %{
                    command_id: command_id,
                    command_type: "test.run",
                    agent_id: agent_id,
                    partition_id: "default",
                    message: "running",
                    progress_percent: 50,
                    payload: progress_payload
                  }},
                 %{actor: actor}
               )

      _command = wait_for_status(command_id, :running, actor)

      assert {:noreply, %{actor: ^actor}} =
               StatusHandler.handle_info(
                 {:command_result,
                  %{
                    command_id: command_id,
                    command_type: "test.run",
                    agent_id: agent_id,
                    partition_id: "default",
                    success: true,
                    message: "done",
                    payload: result_payload
                  }},
                 %{actor: actor}
               )

      command = wait_for_status(command_id, :completed, actor)
      assert command.progress_payload == %{"completed_targets" => 2, "total_targets" => 4}
      assert command.result_payload == %{"completed_targets" => 4, "failed_targets" => 0}

      assert {:ok, %{rows: [["object", "object", "4"]]}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT
                   jsonb_typeof(progress_payload),
                   jsonb_typeof(result_payload),
                   result_payload->>'completed_targets'
                 FROM platform.agent_commands
                 WHERE command_id::text = $1
                 """,
                 [uuid_text(command.id)]
               )
    end

    test "dispatch tolerates ack before sent status is persisted", %{
      agent_id: agent_id,
      actor: actor
    } do
      ensure_status_handler_started()

      {_pid, _metadata} =
        start_control_session(
          agent_id,
          self(),
          %{partition_id: "farm01", capabilities: ["mtr"]},
          ack_before_reply?: true
        )

      assert {:ok, command_id} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["1.1.1.1"],
                 context: %{"mtr_policy_id" => "policy-ack-race"}
               )

      command = wait_for_status(command_id, :acknowledged, actor)
      assert command.partition_id == "farm01"
      assert command.message == "ack"
    end

    test "blocks mtr dispatches beyond the agent concurrency limit", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      assert {:ok, first_command_id} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "1.1.1.1"})

      assert {:ok, second_command_id} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "8.8.8.8"})

      assert {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "9.9.9.9"})

      _ = wait_for_status(first_command_id, :sent, actor)
      _ = wait_for_status(second_command_id, :sent, actor)

      commands =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == "mtr.run")
        |> Ash.read!(actor: actor)

      assert length(commands) == 2
      assert Enum.all?(commands, &(&1.status == :sent))
    end

    test "expired active mtr commands do not count toward the concurrency limit", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      _stale_one =
        create_mtr_command(actor, agent_id, "1.1.1.1",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          status: :sent
        )

      _stale_two =
        create_mtr_command(actor, agent_id, "8.8.8.8",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          status: :acknowledged
        )

      assert {:ok, command_id} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "9.9.9.9"})

      command = wait_for_status(command_id, :sent, actor)
      assert command.agent_id == agent_id
    end

    test "bulk mtr dispatch normalizes targets and persists queued target rows", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch_bulk_mtr(
                 agent_id,
                 [" 1.1.1.1 ", "1.1.1.1", "", "router-a"],
                 protocol: "udp",
                 concurrency: 24,
                 context: %{"mtr_policy_id" => "policy-1"}
               )

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "mtr.bulk_run"

      payload = Jason.decode!(command.payload_json)

      assert payload["targets"] == ["1.1.1.1", "router-a"]
      assert payload["protocol"] == "udp"
      assert payload["concurrency"] == 24
      assert context["mtr_policy_id"] == "policy-1"

      command = wait_for_status(command_id, :sent, actor)
      command_id_text = uuid_text(command.id)

      assert {:ok, %{rows: [["object", "object"]]}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT jsonb_typeof(payload), jsonb_typeof(context)
                 FROM platform.agent_commands
                 WHERE command_id::text = $1
                 """,
                 [command_id_text]
               )

      assert {:ok, %{rows: rows}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT target, status
                 FROM platform.mtr_bulk_job_targets
                 WHERE command_id::text = $1
                 ORDER BY target
                 """,
                 [command_id_text]
               )

      assert rows == [["1.1.1.1", "queued"], ["router-a", "queued"]]
    end

    test "bulk mtr progress persists multiple target updates", %{
      agent_id: agent_id,
      actor: actor
    } do
      ensure_status_handler_started()

      command =
        create_bulk_mtr_command(actor, agent_id, ["1.1.1.1", "router-a"], status: :acknowledged)

      command_id = uuid_text(command.id)

      send(
        StatusHandler,
        {:command_progress,
         %{
           command_id: command_id,
           command_type: "mtr.bulk_run",
           agent_id: agent_id,
           partition_id: "default",
           message: "running",
           progress_percent: 50,
           payload: %{
             "target_updates" => [
               %{"target" => "1.1.1.1", "status" => "running", "attempt_count" => 1},
               %{
                 "target" => "router-a",
                 "status" => "completed",
                 "attempt_count" => 1,
                 "result_payload" => %{"summary" => "ok"}
               }
             ]
           }
         }}
      )

      # Status rows are written before bulk target upserts.
      _ = :sys.get_state(StatusHandler)
      _command = wait_for_status(command.id, :running, actor)

      assert {:ok, %{rows: [["object"]]}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT jsonb_typeof(progress_payload)
                 FROM platform.agent_commands
                 WHERE command_id::text = $1
                 """,
                 [command_id]
               )

      assert {:ok, %{rows: rows}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT target, status, result_payload
                 FROM platform.mtr_bulk_job_targets
                 WHERE command_id::text = $1
                 ORDER BY target
                 """,
                 [command_id]
               )

      assert rows == [
               ["1.1.1.1", "running", nil],
               ["router-a", "completed", %{"summary" => "ok"}]
             ]

      send(
        StatusHandler,
        {:command_result,
         %{
           command_id: command_id,
           command_type: "mtr.bulk_run",
           agent_id: agent_id,
           partition_id: "default",
           success: true,
           message: "bulk mtr job completed",
           payload: %{
             "target_updates" => [
               %{"target" => "1.1.1.1", "status" => "completed", "attempt_count" => 1},
               %{"target" => "router-a", "status" => "completed", "attempt_count" => 1}
             ]
           }
         }}
      )

      # Wait for the whole callback before the sandbox owner is released.
      _ = :sys.get_state(StatusHandler)
      _command = wait_for_status(command.id, :completed, actor)
    end

    test "blocks bulk mtr dispatches while another bulk job is active", %{
      agent_id: agent_id
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      assert {:ok, _command_id} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["1.1.1.1", "1.1.1.2"])

      assert {:error, {:agent_busy, :bulk_mtr_job_running}} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["8.8.8.8"])
    end

    test "expired active bulk mtr commands do not block dispatch", %{
      agent_id: agent_id
    } do
      actor = SystemActor.system(:agent_command_bus_test)

      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      create_bulk_mtr_command(actor, agent_id, ["1.1.1.1", "1.1.1.2"],
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        status: :sent
      )

      assert {:ok, _command_id} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["9.9.9.9"])
    end

    test "automation dispatches bypass the on-demand mtr concurrency limit", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      baseline_context = %{"trigger_mode" => "baseline", "target_key" => "device:uid-1"}

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "1.1.1.1"},
                 context: baseline_context,
                 source: :automation
               )

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "8.8.8.8"},
                 context: baseline_context,
                 source: :automation
               )

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "9.9.9.9"},
                 context: baseline_context,
                 source: :automation
               )

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "2.2.2.2"},
                 context: %{"device_uid" => "ui-request"}
               )

      commands =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == "mtr.run")
        |> Ash.read!(actor: actor)

      assert length(commands) == 4
    end
  end

  describe "push-config delivery" do
    test "pushes config over control stream", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert :ok = AgentCommandBus.push_config(agent_id)

      assert_receive {:push_config, %Monitoring.AgentConfigResponse{} = response}, 1_000
      assert is_binary(response.config_version)
    end

    test "returns an error when the control session exits during push", %{agent_id: agent_id} do
      metadata = %{agent_id: agent_id, partition_id: "default"}

      name =
        ProcessRegistry.via(
          {:agent_control, "default", agent_id, node()},
          metadata
        )

      {:ok, pid} = CrashingControlSession.start(name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      assert wait_for_control_session("default", agent_id, pid)
      assert {:error, {:control_session_exit, _reason}} = AgentCommandBus.push_config(agent_id)
      refute Process.alive?(pid)
    end
  end

  describe "camera relay dispatch" do
    test "sends a typed camera open relay command", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert {:ok, _command_id} =
               AgentCommandBus.start_camera_relay(agent_id, %{
                 relay_session_id: "relay-1",
                 camera_source_id: "camera-1",
                 stream_profile_id: "main",
                 lease_token: "lease-1",
                 source_url: "rtsp://camera.local/stream/main",
                 rtsp_transport: "tcp",
                 codec_hint: "h264"
               })

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "camera.open_relay"

      payload = Jason.decode!(command.payload_json)

      assert payload["relay_session_id"] == "relay-1"
      assert payload["camera_source_id"] == "camera-1"
      assert payload["stream_profile_id"] == "main"
      assert payload["lease_token"] == "lease-1"
      assert payload["source_url"] == "rtsp://camera.local/stream/main"
      assert payload["rtsp_transport"] == "tcp"
      assert payload["codec_hint"] == "h264"

      assert context.relay_session_id == "relay-1"
      assert context.camera_source_id == "camera-1"
      assert context.stream_profile_id == "main"
      assert context.source_url == "rtsp://camera.local/stream/main"
    end

    test "prefers the assigned gateway control stream", %{agent_id: agent_id} do
      start_control_session(
        agent_id,
        self(),
        %{partition_id: "default", gateway_node: "gateway-a"},
        registry_key: {:agent_control, agent_id, :gateway_a},
        marker: :gateway_a
      )

      start_control_session(
        agent_id,
        self(),
        %{partition_id: "default", gateway_node: "gateway-b"},
        registry_key: {:agent_control, agent_id, :gateway_b},
        marker: :gateway_b
      )

      assert {:ok, _command_id} =
               AgentCommandBus.start_camera_relay(
                 agent_id,
                 %{
                   relay_session_id: "relay-gateway",
                   camera_source_id: "camera-gateway",
                   stream_profile_id: "low",
                   lease_token: "lease-gateway",
                   source_url: "rtsp://camera.local/stream/low"
                 },
                 required_gateway_node: "gateway-b"
               )

      assert_receive {:send_command, :gateway_b, %Monitoring.CommandRequest{} = command,
                      _context},
                     1_000

      assert command.command_type == "camera.open_relay"
      refute_received {:send_command, :gateway_a, _, _}
    end

    test "does not fall back to another gateway when a route is required", %{agent_id: agent_id} do
      start_control_session(
        agent_id,
        self(),
        %{partition_id: "default", gateway_node: "gateway-a"},
        registry_key: {:agent_control, agent_id, :gateway_a},
        marker: :gateway_a
      )

      assert {:error, {:agent_offline, ^agent_id}} =
               AgentCommandBus.start_camera_relay(
                 agent_id,
                 %{
                   relay_session_id: "relay-required-gateway",
                   camera_source_id: "camera-required-gateway",
                   stream_profile_id: "low",
                   lease_token: "lease-required-gateway",
                   source_url: "rtsp://camera.local/stream/low"
                 },
                 required_gateway_node: "gateway-b"
               )

      refute_received {:send_command, :gateway_a, _, _}
    end

    test "resolves source_url from camera inventory before dispatch", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: nil,
           rtsp_transport: "tcp",
           codec_hint: "h264",
           container_hint: "annexb",
           camera_source: %{source_url: "rtsp://camera.local/inventory/main"}
         }}
      end

      assert {:ok, _command_id} =
               AgentCommandBus.start_camera_relay(
                 agent_id,
                 %{
                   relay_session_id: "relay-2",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id,
                   lease_token: "lease-2"
                 },
                 camera_profile_fetcher: fetcher
               )

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      payload = Jason.decode!(command.payload_json)

      assert payload["source_url"] == "rtsp://camera.local/inventory/main"
      assert payload["rtsp_transport"] == "tcp"
      assert payload["codec_hint"] == "h264"
      assert payload["container_hint"] == "annexb"
      assert context.source_url == "rtsp://camera.local/inventory/main"
    end

    test "marks UniFi Protect bootstrap rtsps relays as insecure TLS before dispatch", %{
      agent_id: agent_id
    } do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: "rtsps://192.168.1.1:7441/front-door?enableSrtp",
           rtsp_transport: "tcp",
           metadata: %{"source" => "protect-bootstrap"},
           camera_source: %{
             source_url: "rtsps://192.168.1.1:7441/front-door",
             metadata: %{"plugin_id" => "unifi-protect-camera"}
           }
         }}
      end

      assert {:ok, _command_id} =
               AgentCommandBus.start_camera_relay(
                 agent_id,
                 %{
                   relay_session_id: "relay-protect",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id,
                   lease_token: "lease-protect"
                 },
                 camera_profile_fetcher: fetcher
               )

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      payload = Jason.decode!(command.payload_json)

      assert payload["source_url"] == "rtsps://192.168.1.1:7441/front-door"
      assert payload["rtsp_transport"] == "tcp"
      assert payload["insecure_skip_verify"] == true
      assert context.source_url == "rtsps://192.168.1.1:7441/front-door"
    end

    test "sends a typed camera close relay command", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert {:ok, _command_id} =
               AgentCommandBus.stop_camera_relay(agent_id, %{
                 relay_session_id: "relay-1",
                 reason: "viewer disconnected"
               })

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "camera.close_relay"

      payload = Jason.decode!(command.payload_json)

      assert payload["relay_session_id"] == "relay-1"
      assert payload["reason"] == "viewer disconnected"
      assert context.relay_session_id == "relay-1"
    end
  end

  defp ensure_status_handler_started do
    case Process.whereis(ResultCoordinationTaskSupervisor) do
      nil ->
        {:ok, _pid} =
          Task.Supervisor.start_link(
            name: ResultCoordinationTaskSupervisor,
            max_children: 32
          )

      _pid ->
        :ok
    end

    case Process.whereis(StatusHandler) do
      nil -> StatusHandler.start_link([])
      _pid -> :ok
    end
  end

  defp start_control_session(agent_id, test_pid, metadata, opts \\ []) do
    metadata =
      metadata
      |> Map.put_new(:agent_id, agent_id)
      |> Map.put_new(:pending_config_version, nil)

    registry_key =
      opts
      |> Keyword.get(:registry_key)
      |> canonical_test_control_key(metadata.partition_id, agent_id)

    name = ProcessRegistry.via(registry_key, metadata)

    {:ok, pid} =
      TestControlSession.start_link(
        [
          name: name,
          test_pid: test_pid,
          agent_id: agent_id,
          partition_id: metadata.partition_id
        ] ++
          Keyword.take(opts, [:ack_before_reply?, :auto_result?, :marker])
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert wait_for_control_session(metadata.partition_id, agent_id, pid)

    {pid, metadata}
  end

  defp canonical_test_control_key(nil, partition_id, agent_id),
    do: {:agent_control, partition_id, agent_id, node()}

  defp canonical_test_control_key(
         {:agent_control, agent_id, registry_node},
         partition_id,
         agent_id
       ),
       do: {:agent_control, partition_id, agent_id, registry_node}

  defp canonical_test_control_key({:agent_control, agent_id}, partition_id, agent_id),
    do: {:agent_control, partition_id, agent_id, node()}

  defp canonical_test_control_key(key, _partition_id, _agent_id), do: key

  defp wait_for_control_session(partition_id, agent_id, pid, attempts \\ 40)

  defp wait_for_control_session(_partition_id, _agent_id, _pid, 0), do: false

  defp wait_for_control_session(partition_id, agent_id, pid, attempts) do
    if Enum.any?(AgentCommandBus.lookup_control_session_entries(partition_id, agent_id), fn
         {^pid, _metadata} -> true
         _entry -> false
       end) do
      true
    else
      Process.sleep(25)
      wait_for_control_session(partition_id, agent_id, pid, attempts - 1)
    end
  end

  defp create_mtr_command(actor, agent_id, target, opts) do
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
    status = Keyword.get(opts, :status, :queued)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"target" => target},
          ttl_seconds: 60,
          expires_at: expires_at
        },
        actor: actor
      )

    case status do
      :queued ->
        command

      :sent ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        command

      :acknowledged ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
        command
    end
  end

  defp create_bulk_mtr_command(actor, agent_id, targets, opts) do
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 300, :second))
    status = Keyword.get(opts, :status, :queued)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.bulk_run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"targets" => targets, "protocol" => "icmp"},
          ttl_seconds: 300,
          expires_at: expires_at
        },
        actor: actor
      )

    case status do
      :queued ->
        command

      :sent ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        command

      :acknowledged ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
        command
    end
  end

  defp wait_for_status(command_id, expected_status, actor) do
    Enum.reduce_while(1..20, nil, fn _, _ ->
      case AgentCommand.get_by_id(command_id, actor: actor) do
        {:ok, %{status: ^expected_status} = command} ->
          {:halt, command}

        _ ->
          Process.sleep(50)
          {:cont, nil}
      end
    end) || flunk("Expected command #{command_id} to reach status #{inspect(expected_status)}")
  end

  defp uuid_text(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        uuid

      :error ->
        Ecto.UUID.load!(id)
    end
  end
end
