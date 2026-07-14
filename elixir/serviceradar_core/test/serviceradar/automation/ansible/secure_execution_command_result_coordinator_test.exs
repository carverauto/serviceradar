defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  defmodule CaptureLifecycleActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureExecutionLifecycleActions

    @impl true
    def mark_running(_operation, _execution), do: {:error, :unexpected_mark_running}

    @impl true
    def complete_terminal(_operation, _execution, _outcomes, _state, _evidence),
      do: {:error, :unexpected_complete_terminal}

    @impl true
    def fail_closed(operation, execution, targets, state, diagnostics) do
      send(Process.get(:secure_execution_test_pid), {
        :failed_closed,
        operation,
        execution,
        targets,
        state,
        diagnostics
      })

      {:ok, %{state: state}}
    end
  end

  defmodule CaptureAttemptStore do
    @moduledoc false
    def mark_failed(attempt, attrs, _opts) do
      send(Process.get(:secure_execution_test_pid), {:attempt_failed, attempt, attrs})
      {:ok, %{attempt | state: :failed}}
    end
  end

  test "authenticated agent and reported type must match persisted command provenance" do
    bundle = bundle([])

    assert {:error, :secure_execution_authenticated_agent_mismatch} =
             Coordinator.process_persisted(
               bundle.command.id,
               "forged-agent",
               bundle.command.command_type,
               bundle_loader: fn _ -> {:ok, bundle} end
             )

    assert {:error, :secure_execution_reported_type_mismatch} =
             Coordinator.process_persisted(
               bundle.command.id,
               bundle.command.agent_id,
               "awx.cancel_job",
               bundle_loader: fn _ -> {:ok, bundle} end
             )
  end

  test "callback operations remain isolated from the secure non-callback coordinator" do
    bundle = bundle(["remote_access.ssh_ca.sign"])

    assert {:error, :callback_execution_isolated} =
             Coordinator.process_persisted(
               bundle.command.id,
               bundle.command.agent_id,
               bundle.command.command_type,
               bundle_loader: fn _ -> {:ok, bundle} end
             )
  end

  test "gateway-supplied correlation fields are ignored beyond command id, type, and authenticated agent" do
    bundle = bundle([])
    bundle = %{bundle | attempt: %{bundle.attempt | state: :succeeded}}
    test_pid = self()

    assert {:error, :secure_execution_command_correlation_mismatch} =
             Coordinator.handle_command_result(
               %{
                 command_id: bundle.command.id,
                 command_type: bundle.command.command_type,
                 agent_id: bundle.command.agent_id,
                 operation_id: "forged-operation",
                 execution_id: "forged-execution",
                 context: %{"schema" => "forged"}
               },
               bundle_loader: fn command_id ->
                 send(test_pid, {:loaded_by_command_id, command_id})
                 {:ok, bundle}
               end
             )

    assert_receive {:loaded_by_command_id, command_id}
    assert command_id == bundle.command.id
  end

  test "polling uses a bounded responsiveness backoff" do
    assert Enum.map(1..7, &Coordinator.poll_delay_seconds/1) == [2, 5, 10, 15, 15, 15, 15]
  end

  test "terminal processing fails closed with sanitized evidence for a tampered persisted command" do
    Process.put(:secure_execution_test_pid, self())
    secret = "Bearer command-payload-must-not-survive"
    bundle = exact_bundle()
    command = %{bundle.command | payload: Map.put(bundle.command.payload, "debug", secret)}
    bundle = %{bundle | command: command}

    assert {:ok, :failed_closed} =
             Coordinator.process_persisted(
               command.id,
               command.agent_id,
               command.command_type,
               bundle_loader: fn _ -> {:ok, bundle} end,
               processing_claimer: fn attempt, token, expires_at, _now ->
                 {:ok,
                  %{
                    attempt
                    | state: :processing,
                      lease_token: token,
                      lease_expires_at: expires_at
                  }}
               end,
               transaction: fn fun -> {:ok, fun.()} end,
               attempt_store: CaptureAttemptStore,
               secure_lifecycle_actions: CaptureLifecycleActions
             )

    assert_receive {:failed_closed, _operation, _execution, _targets, :failed, diagnostics}
    assert diagnostics["reason"] == "secure_execution_command_correlation_mismatch"
    assert diagnostics["evidence_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(diagnostics) =~ secret

    assert_receive {:attempt_failed, _attempt, attrs}
    assert attrs.last_error_code == "secure_execution_command_correlation_mismatch"
    refute inspect(attrs) =~ secret
  end

  defp bundle(callback_actions) do
    command_id = Ash.UUID.generate()
    operation_id = Ash.UUID.generate()
    execution_id = Ash.UUID.generate()
    controller_id = Ash.UUID.generate()

    attempt =
      struct!(Attempt,
        id: Ash.UUID.generate(),
        operation_id: operation_id,
        execution_id: execution_id,
        controller_id: controller_id,
        dispatch_agent_id: "edge-agent-1",
        dispatch_partition_id: "farm01",
        stage: :fetch_job,
        purpose: :terminal_poll,
        attempt: 1,
        command_id: command_id,
        command_type: "awx.fetch_job",
        request_schema_version: "serviceradar.automation_execution_command/v1",
        request_digest: String.duplicate("a", 64),
        context_digest: String.duplicate("b", 64),
        expected_job_id: 77,
        candidate_job_ids: [],
        state: :dispatched,
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    sync_secret = Ash.UUID.generate()
    execution_secret = Ash.UUID.generate()

    controller = %{
      id: controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: "edge-agent-1",
      enabled: true,
      credential_secret_id: sync_secret,
      sync_credential_secret_id: sync_secret,
      execution_credential_secret_id: execution_secret,
      callback_credential_secret_id: nil,
      metadata: %{}
    }

    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    command =
      struct!(AgentCommand,
        id: command_id,
        command_type: "awx.fetch_job",
        agent_id: "edge-agent-1",
        partition_id: "farm01",
        status: :completed,
        payload: %{},
        context: %{},
        result_payload: %{"ok" => true}
      )

    %{
      command: command,
      attempt: attempt,
      operation: %{id: operation_id, callback_actions: callback_actions, state: :running},
      execution: %{
        id: execution_id,
        operation_id: operation_id,
        controller_id: controller_id,
        state: :running,
        metadata: %{
          "dispatch_partition_id" => "farm01",
          "controller_security_snapshot" => controller_snapshot
        }
      },
      targets: [%{id: Ash.UUID.generate()}],
      controller: controller
    }
  end

  defp exact_bundle do
    bundle = bundle([])
    execution_secret = bundle.controller.execution_credential_secret_id

    execution =
      bundle.execution
      |> Map.put(:dispatch_id, Ash.UUID.generate())
      |> Map.put(:snapshot_digest, String.duplicate("d", 64))

    controller = bundle.controller

    request = %{job_id: bundle.attempt.expected_job_id}
    {:ok, request_digest} = CanonicalJSON.digest(request)
    attempt = %{bundle.attempt | request_digest: request_digest}
    context = Contract.context(attempt, execution)
    {:ok, context_digest} = CanonicalJSON.digest(context)
    attempt = %{attempt | context_digest: context_digest}
    args = %{"job_id" => attempt.expected_job_id}
    {:ok, scope} = AwxClient.broker_scope(controller.base_url, attempt.command_type, args)

    broker = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_id" => Ash.UUID.generate(),
      "grant_type" => "awx_oauth2_token",
      "credential_secret_ref" => SecretRefs.network_credential_ref(execution_secret),
      "consumer" => %{
        "kind" => "ansible",
        "id" => controller.id,
        "purpose" => attempt.command_type
      },
      "target" => %{
        "kind" => "awx_controller",
        "id" => controller.id,
        "agent_id" => controller.agent_id
      },
      "resolution_location" => "agent",
      "inject" => %{
        "type" => "http_header",
        "name" => "Authorization",
        "scheme" => "Bearer"
      },
      "allow" => scope.allow,
      "ttl_seconds" => 300,
      "expires_at" => DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
    }

    command = %{
      bundle.command
      | context: context,
        payload: %{
          "schema" => "serviceradar.awx_command.v1",
          "verb" => attempt.command_type,
          "args" => args,
          "base_url" => scope.base_url,
          "controller_id" => controller.id,
          "controller_name" => controller.name,
          "insecure_skip_verify" => false,
          "credential_broker" => broker
        },
        result_payload: %{
          "verb" => "awx.fetch_job",
          "ok" => true,
          "job_id" => attempt.expected_job_id,
          "job" => %{"id" => attempt.expected_job_id, "status" => "successful"}
        }
    }

    %{bundle | attempt: attempt, execution: execution, controller: controller, command: command}
  end
end
