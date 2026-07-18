defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandRecoveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher, as: Dispatcher
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandRecovery, as: Recovery
  alias ServiceRadar.Edge.AgentCommand

  defmodule FakeCoordinator do
    @moduledoc false

    def process_persisted(command_id, agent_id, command_type, _opts) do
      send(Process.get(:test_pid), {:process_persisted, command_id, agent_id, command_type})
      {:ok, :processed}
    end

    def reconcile_transport_ambiguity(attempt, _opts) do
      send(Process.get(:test_pid), {:reconcile_transport, attempt.command_id})
      {:ok, :reconciling}
    end

    def expire_attempt(attempt, _opts) do
      send(Process.get(:test_pid), {:expire_attempt, attempt.command_id})
      {:ok, :expired}
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "missed terminal notifications replay the persisted command result even after deadline" do
    now = now()
    attempt = attempt(:fetch_job, DateTime.add(now, -1, :second))
    command = command(attempt, :completed, DateTime.add(now, -30, :second))

    assert %{attempts: 1} =
             recover(attempt, command,
               now: now,
               dispatcher: fn _ -> send(self(), :unsafe_dispatch) end
             )

    assert_receive {:process_persisted, command_id, "edge-agent-1", "awx.fetch_job"}
    assert command_id == attempt.command_id
    refute_receive :unsafe_dispatch
    refute_receive {:expire_attempt, _}
  end

  test "an expired persisted launch is reconciled and never blindly relaunched" do
    now = now()
    attempt = attempt(:launch_job, DateTime.add(now, -1, :second))
    command = command(attempt, :sent, DateTime.add(now, -10, :second))
    test_pid = self()

    assert %{attempts: 1} =
             recover(attempt, command,
               now: now,
               dispatcher: fn _ ->
                 send(test_pid, :unsafe_relaunch)
                 {:error, :unsafe}
               end
             )

    assert_receive {:reconcile_transport, command_id}
    assert command_id == attempt.command_id
    refute_receive :unsafe_relaunch
  end

  test "a missing preallocated command may dispatch only its durable planned attempt" do
    attempt = attempt(:launch_job, DateTime.add(now(), 60, :second))
    test_pid = self()

    assert %{attempts: 1} =
             recover(attempt, nil,
               dispatcher: fn recovered ->
                 send(test_pid, {:dispatch, recovered.command_id})
                 {:ok, :dispatched}
               end
             )

    assert_receive {:dispatch, command_id}
    assert command_id == attempt.command_id
    refute_receive {:reconcile_transport, _}
  end

  test "recovery reauthorizes a missing launch command and terminalizes contraction" do
    {attempt, resources} = recoverable_launch_attempt()
    test_pid = self()

    assert %{attempts: 1} =
             recover(attempt, nil,
               dispatcher: fn recovered ->
                 Dispatcher.dispatch(recovered,
                   resource_loader: fn ^recovered -> {:ok, resources} end,
                   preflight_evidence_reader: preflight_evidence_reader(resources),
                   current_authorizer: fn _current_resources, _now, _context ->
                     send(test_pid, :recovery_reauthorized)
                     {:error, :principal_disabled}
                   end,
                   authority_denial_handler: fn denied, _resources, reason, _now ->
                     send(test_pid, {:recovery_terminalized, denied.id, reason})
                     {:ok, :terminalized}
                   end,
                   claim: fn _, _, _, _ ->
                     flunk("contracted recovery must not acquire a dispatch lease")
                   end,
                   awx_dispatcher: fn _, _, _, _, _ ->
                     flunk("contracted recovery must not reach AWX")
                   end
                 )
               end
             )

    assert_receive :recovery_reauthorized
    assert_receive {:recovery_terminalized, attempt_id, :principal_disabled}
    assert attempt_id == attempt.id
  end

  test "recovery watchdog reauthorizes an in-flight continuation and durably contracts it" do
    current = now()

    attempt =
      :fetch_job
      |> attempt(DateTime.add(current, 60, :second))
      |> Map.put(:state, :dispatched)

    command = command(attempt, :running, DateTime.add(current, 30, :second))
    resources = continuation_resources(attempt, :running, :running)
    test_pid = self()

    assert %{attempts: 1} =
             recover(attempt, command,
               now: current,
               continuation_authorizer: fn recovered ->
                 Dispatcher.reauthorize_continuation(recovered,
                   resource_loader: fn ^recovered -> {:ok, resources} end,
                   current_authorizer: fn current_attempt, _resources, _now, _context ->
                     assert current_attempt.purpose == :terminal_poll
                     send(test_pid, :watchdog_reauthorized)
                     {:error, :principal_disabled}
                   end,
                   authority_denial_handler: fn denied, _resources, reason, _now ->
                     send(test_pid, {:watchdog_contracted, denied.id, reason})
                     {:ok, :cancellation_planned}
                   end
                 )
               end
             )

    assert_receive :watchdog_reauthorized
    assert_receive {:watchdog_contracted, attempt_id, :principal_disabled}
    assert attempt_id == attempt.id
    refute_receive {:process_persisted, _, _, _}
    refute_receive {:expire_attempt, _}
  end

  test "a non-launch command whose bounded deadline elapsed fails through expiration" do
    now = now()
    attempt = attempt(:fetch_job, DateTime.add(now, -1, :second))
    command = command(attempt, :running, DateTime.add(now, 30, :second))

    assert %{attempts: 1} = recover(attempt, command, now: now)
    assert_receive {:expire_attempt, command_id}
    assert command_id == attempt.command_id
    refute_receive {:reconcile_transport, _}
  end

  defp recover(attempt, command, opts) do
    Recovery.recover_once(
      Keyword.merge(
        [
          attempt_lister: fn _now -> {:ok, [attempt]} end,
          command_fetcher: fn _command_id -> {:ok, command} end,
          coordinator: FakeCoordinator
        ],
        opts
      )
    )
  end

  defp command(attempt, status, expires_at) do
    struct!(AgentCommand,
      id: attempt.command_id,
      command_type: attempt.command_type,
      agent_id: attempt.dispatch_agent_id,
      partition_id: attempt.dispatch_partition_id,
      status: status,
      expires_at: expires_at
    )
  end

  defp attempt(stage, deadline_at) do
    {command_type, purpose, expected_job_id} =
      case stage do
        :launch_job -> {"awx.launch_job", :accepted_job_proof, nil}
        :fetch_job -> {"awx.fetch_job", :terminal_poll, 77}
      end

    struct!(Attempt,
      id: Ash.UUID.generate(),
      operation_id: Ash.UUID.generate(),
      execution_id: Ash.UUID.generate(),
      controller_id: Ash.UUID.generate(),
      dispatch_agent_id: "edge-agent-1",
      dispatch_partition_id: "farm01",
      stage: stage,
      purpose: purpose,
      attempt: 1,
      command_id: Ash.UUID.generate(),
      command_type: command_type,
      request_schema_version: "serviceradar.automation_execution_command/v1",
      request_digest: String.duplicate("a", 64),
      context_digest: String.duplicate("b", 64),
      expected_job_id: expected_job_id,
      candidate_job_ids: [],
      state: :planned,
      deadline_at: deadline_at,
      inserted_at: now()
    )
  end

  defp recoverable_launch_attempt do
    operation_id = "018f3f56-1111-7222-8333-123456789abc"
    execution_id = "018f3f56-1111-7222-8333-123456789abd"
    controller_id = "018f3f56-1111-7222-8333-123456789abe"
    current = now()

    controller = controller(controller_id, "edge-agent-1")
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    operation = %{
      id: operation_id,
      state: :dispatching,
      callback_actions: [],
      declared_inputs: %{},
      mutating: true
    }

    execution = %{
      id: execution_id,
      operation_id: operation_id,
      controller_id: controller_id,
      state: :dispatching,
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      execution_environment_id: 4,
      credential_snapshot: %{"credential_ids" => [5]},
      check_mode: false,
      host_limit: "farm01-node01",
      dispatch_id: "018f3f56-1111-7222-8333-123456789abf",
      snapshot_digest: String.duplicate("b", 64),
      metadata: %{
        "dispatch_partition_id" => "farm01",
        "controller_security_snapshot" => controller_snapshot
      }
    }

    {operation, execution, evidence} =
      attach_live_preflight(operation, execution, controller, current)

    {:ok, request} = Contract.launch_request(operation, execution)

    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: operation_id,
          execution_id: execution_id,
          controller_id: controller_id,
          dispatch_agent_id: "edge-agent-1",
          dispatch_partition_id: "farm01"
        },
        execution,
        request,
        stage: :launch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.launch_job",
        deadline_at: DateTime.add(current, 60, :second)
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned, inserted_at: current})
      )

    resources = %{
      operation: operation,
      execution: execution,
      controller: controller,
      targets: [],
      preflight_evidence: evidence
    }

    {attempt, resources}
  end

  defp continuation_resources(attempt, operation_state, execution_state) do
    controller = controller(attempt.controller_id, attempt.dispatch_agent_id)
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    %{
      operation: %{
        id: attempt.operation_id,
        state: operation_state,
        callback_actions: [],
        mutating: true
      },
      execution: %{
        id: attempt.execution_id,
        operation_id: attempt.operation_id,
        controller_id: attempt.controller_id,
        state: execution_state,
        metadata: %{
          "dispatch_partition_id" => attempt.dispatch_partition_id,
          "controller_security_snapshot" => controller_snapshot
        }
      },
      controller: controller,
      targets: [%{id: Ash.UUID.generate()}]
    }
  end

  defp controller(id, agent_id) do
    secret_id = Ash.UUID.generate()

    %{
      id: id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: agent_id,
      enabled: true,
      credential_secret_id: secret_id,
      sync_credential_secret_id: secret_id,
      execution_credential_secret_id: secret_id,
      callback_credential_secret_id: nil,
      metadata: %{}
    }
  end

  defp attach_live_preflight(operation, execution, controller, verified_at) do
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    {:ok, controller_security_snapshot_digest} =
      ControllerSecuritySnapshot.digest(controller_snapshot)

    attestation = %{
      schema: AwxLaunchPreflightAttestation.schema(),
      evidence_id: Ash.UUID.generate(),
      command_id: Ash.UUID.generate(),
      controller_id: controller.id,
      dispatch_agent_id: controller.agent_id,
      dispatch_partition_id: "farm01",
      binding_id: Ash.UUID.generate(),
      binding_version: 1,
      approval_id: Ash.UUID.generate(),
      reviewed_launch_snapshot_digest: String.duplicate("a", 64),
      preflight_request_digest: String.duplicate("b", 64),
      target_snapshot_digest: String.duplicate("c", 64),
      controller_security_snapshot_digest: controller_security_snapshot_digest,
      live_launch_snapshot_digest: String.duplicate("d", 64),
      command_result_digest: String.duplicate("e", 64),
      verified_at: verified_at,
      expires_at: DateTime.add(verified_at, 60, :second)
    }

    {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation)

    {Map.merge(operation, attrs), Map.merge(execution, attrs), preflight_evidence(attestation)}
  end

  defp preflight_evidence(attestation) do
    %{
      id: attestation.evidence_id,
      command_id: attestation.command_id,
      controller_id: attestation.controller_id,
      dispatch_agent_id: attestation.dispatch_agent_id,
      dispatch_partition_id: attestation.dispatch_partition_id,
      binding_id: attestation.binding_id,
      binding_version: attestation.binding_version,
      approval_id: attestation.approval_id,
      reviewed_launch_snapshot_digest: attestation.reviewed_launch_snapshot_digest,
      preflight_request_digest: attestation.preflight_request_digest,
      target_snapshot_digest: attestation.target_snapshot_digest,
      controller_security_snapshot_digest: attestation.controller_security_snapshot_digest,
      live_launch_snapshot_digest: attestation.live_launch_snapshot_digest,
      command_result_digest: attestation.command_result_digest,
      verified_at: attestation.verified_at,
      expires_at: attestation.expires_at
    }
  end

  defp preflight_evidence_reader(%{preflight_evidence: evidence}) do
    fn evidence_id ->
      if evidence_id == evidence.id, do: {:ok, evidence}, else: {:error, :not_found}
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :microsecond)
end
