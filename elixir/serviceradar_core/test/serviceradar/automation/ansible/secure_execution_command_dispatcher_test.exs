defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher, as: Dispatcher
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  @operation_id "018f3f56-1111-7222-8333-123456789abc"
  @execution_id "018f3f56-1111-7222-8333-123456789abd"
  @controller_id "018f3f56-1111-7222-8333-123456789abe"
  @execution_secret "018f3f56-2222-7222-8333-123456789abe"
  @preflight_evidence_id "018f3f56-1111-7222-8333-123456789a01"
  @preflight_command_id "018f3f56-1111-7222-8333-123456789a02"
  @preflight_binding_id "018f3f56-1111-7222-8333-123456789a03"
  @preflight_approval_id "018f3f56-1111-7222-8333-123456789a04"

  test "dispatches an exact durable launch only from the persisted dispatching state" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)
    test_pid = self()

    assert {:ok, :dispatched} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               preflight_evidence_reader: preflight_evidence_reader(resources),
               current_authorizer: &authorize_current/3,
               claim: fn claimed, _token, _expires, _now ->
                 send(test_pid, :claimed)
                 {:ok, %{claimed | state: :dispatching}}
               end,
               awx_dispatcher: fn claimed, controller, request, context, _opts ->
                 send(test_pid, {:awx_dispatch, claimed, controller, request, context})
                 {:ok, %{id: claimed.command_id}}
               end,
               mark_dispatched: fn claimed, _token, _now ->
                 {:ok, %{claimed | state: :dispatched}}
               end
             )

    assert_receive :claimed
    assert_receive {:awx_dispatch, claimed, %{id: @controller_id}, request, context}
    assert claimed.id == attempt.id
    assert claimed.state == :dispatching
    assert request.launch_opts.host_limit == "farm01-node01"
    assert context["schema"] == Contract.context_schema()
    assert context["execution_id"] == @execution_id
  end

  test "launch rejects legacy metadata without immutable preflight evidence before claim" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)

    resources =
      resources
      |> Map.update!(:operation, &drop_preflight_snapshot/1)
      |> Map.update!(:execution, &drop_preflight_snapshot/1)

    assert {:error, :awx_preflight_attestation_required} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               claim: fn _, _, _, _ -> flunk("legacy launch must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("legacy launch must not reach AWX") end
             )
  end

  test "launch binds the immutable preflight to the exact dispatch partition" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)
    attempt = %{attempt | dispatch_partition_id: "tonka01"}

    assert {:error, :awx_preflight_partition_drift} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               preflight_evidence_reader: preflight_evidence_reader(resources),
               claim: fn _, _, _, _ -> flunk("partition drift must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("partition drift must not reach AWX") end
             )
  end

  test "launch binds the immutable preflight to the exact dispatch agent" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)
    attempt = %{attempt | dispatch_agent_id: "edge-agent-2"}

    assert {:error, :awx_preflight_agent_drift} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               preflight_evidence_reader: preflight_evidence_reader(resources),
               claim: fn _, _, _, _ -> flunk("agent drift must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("agent drift must not reach AWX") end
             )
  end

  test "launch rejects an immutable snapshot whose evidence cannot be loaded" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)

    assert {:error, :awx_preflight_evidence_unavailable} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               preflight_evidence_reader: fn _ -> {:error, :not_found} end,
               claim: fn _, _, _, _ -> flunk("unbacked preflight must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ ->
                 flunk("unbacked preflight must not reach AWX")
               end
             )
  end

  test "legacy reconciliation and cleanup remain bounded to non-launch commands" do
    test_pid = self()

    for {attempt, resources, expected_command_type} <- [
          legacy_nonlaunch_attempt(:list_recent_jobs),
          legacy_nonlaunch_attempt(:cancel_job)
        ] do
      assert {:ok, :dispatched} =
               Dispatcher.dispatch(attempt,
                 resource_loader: fn _ -> {:ok, resources} end,
                 claim: &claim/4,
                 awx_dispatcher: fn claimed, _controller, _request, _context, _opts ->
                   send(
                     test_pid,
                     {:legacy_nonlaunch_dispatch, claimed.stage, claimed.command_type}
                   )

                   {:ok, %{id: claimed.command_id}}
                 end,
                 mark_dispatched: fn claimed, _token, _now ->
                   {:ok, %{claimed | state: :dispatched}}
                 end
               )

      assert_receive {:legacy_nonlaunch_dispatch, stage, ^expected_command_type}
      refute stage == :launch_job
    end
  end

  test "recovery cannot dispatch a planned or partially transitioned launch" do
    for {operation_state, execution_state} <- [
          {:planned, :planned},
          {:dispatching, :planned},
          {:planned, :dispatching}
        ] do
      {attempt, resources} = launch_attempt(operation_state, execution_state)
      test_pid = self()

      assert {:error, :secure_execution_lifecycle_state_mismatch} =
               Dispatcher.dispatch(attempt,
                 resource_loader: fn _ -> {:ok, resources} end,
                 claim: fn _, _, _, _ ->
                   send(test_pid, :unsafe_claim)
                   {:error, :must_not_run}
                 end,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   send(test_pid, :unsafe_dispatch)
                   {:error, :must_not_run}
                 end
               )

      refute_receive :unsafe_claim
      refute_receive :unsafe_dispatch
    end
  end

  test "callback executions are never accepted by the non-callback dispatcher" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)
    resources = put_in(resources.operation.callback_actions, ["remote_access.ssh_ca.sign"])

    assert {:error, :callback_execution_isolated} =
             Dispatcher.dispatch(attempt, resource_loader: fn _ -> {:ok, resources} end)
  end

  test "current authority contraction terminalizes before claim or AWX dispatch" do
    now = ~U[2026-07-13 13:00:00.000000Z]
    {attempt, resources} = launch_attempt(:dispatching, :dispatching, now)
    test_pid = self()

    assert {:error, :current_permission_denied} =
             Dispatcher.dispatch(attempt,
               now: now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               preflight_evidence_reader: preflight_evidence_reader(resources),
               current_authorizer: fn current_resources, _now, _context ->
                 assert current_resources.operation.id == attempt.operation_id
                 {:error, :current_permission_denied}
               end,
               authority_denial_handler: fn denied_attempt, denied_resources, reason, now ->
                 send(
                   test_pid,
                   {:authority_denied, denied_attempt.id, denied_resources.execution.id, reason,
                    now}
                 )

                 {:ok, :terminalized}
               end,
               claim: fn _, _, _, _ -> flunk("contracted launch must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ ->
                 flunk("contracted launch must not reach AWX")
               end
             )

    assert_receive {:authority_denied, attempt_id, @execution_id, :current_permission_denied,
                    ^now}

    assert attempt_id == attempt.id
  end

  test "every known-child continuation reauthorizes before claim and routes contraction to cancel" do
    phases = [
      {:fetch_job, :accepted_job_proof, :dispatching, :dispatching},
      {:fetch_job, :scope_poll, :dispatching, :launching},
      {:fetch_host_summaries, :host_scope_proof, :dispatching, :launching},
      {:fetch_job, :terminal_poll, :running, :running},
      {:fetch_host_summaries, :terminal_confirmation, :running, :running}
    ]

    test_pid = self()

    for {stage, purpose, operation_state, execution_state} <- phases do
      {attempt, resources} =
        continuation_attempt(stage, purpose, operation_state, execution_state)

      assert {:error, :principal_disabled} =
               Dispatcher.dispatch(attempt,
                 resource_loader: fn ^attempt -> {:ok, resources} end,
                 current_authorizer: fn current_attempt, current_resources, _now, _context ->
                   assert current_attempt.stage == stage
                   assert current_attempt.purpose == purpose
                   assert current_resources.execution.id == @execution_id
                   {:error, :principal_disabled}
                 end,
                 authority_denial_handler: fn denied, _resources, reason, _now ->
                   send(test_pid, {:continuation_denied, denied.stage, denied.purpose, reason})
                   {:ok, :cancellation_planned}
                 end,
                 claim: fn _, _, _, _ ->
                   flunk("contracted continuation must not acquire a lease")
                 end,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   flunk("contracted continuation must not reach AWX")
                 end
               )

      assert_receive {:continuation_denied, ^stage, ^purpose, :principal_disabled}
    end
  end

  test "immutable request digest drift fails before claim or external dispatch" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)
    attempt = %{attempt | request_digest: String.duplicate("f", 64)}
    test_pid = self()

    assert {:error, :secure_execution_request_digest_mismatch} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               preflight_evidence_reader: preflight_evidence_reader(resources),
               claim: fn _, _, _, _ ->
                 send(test_pid, :unsafe_claim)
                 {:error, :must_not_run}
               end
             )

    refute_receive :unsafe_claim
  end

  test "dispatch crash-window reconciliation accepts only the full persisted command contract" do
    {attempt, resources} = launch_attempt(:dispatching, :dispatching)
    {:ok, request} = Contract.launch_request(resources.operation, resources.execution)
    context = Contract.context(attempt, resources.execution)
    command = persisted_command(attempt, resources.controller, request, context)
    test_pid = self()

    assert {:ok, :dispatched} =
             Dispatcher.dispatch(attempt,
               resource_loader: fn _ -> {:ok, resources} end,
               preflight_evidence_reader: preflight_evidence_reader(resources),
               current_authorizer: &authorize_current/3,
               claim: &claim/4,
               awx_dispatcher: fn _, _, _, _, _ -> {:error, :transport_interrupted} end,
               command_fetcher: fn command_id ->
                 assert command_id == attempt.command_id
                 {:ok, command}
               end,
               mark_dispatched: fn claimed, _token, _now ->
                 send(test_pid, {:marked_dispatched, claimed.id})
                 {:ok, %{claimed | state: :dispatched}}
               end
             )

    assert_receive {:marked_dispatched, id}
    assert id == attempt.id
  end

  test "dispatch crash-window reconciliation rejects tampered payload and context" do
    for tamper <- [:payload, :context] do
      {attempt, resources} = launch_attempt(:dispatching, :dispatching)
      {:ok, request} = Contract.launch_request(resources.operation, resources.execution)
      context = Contract.context(attempt, resources.execution)
      command = persisted_command(attempt, resources.controller, request, context)

      command =
        case tamper do
          :payload ->
            command.payload
            |> put_in(["credential_broker", "allow", "paths"], ["/api/v2/"])
            |> then(&%{command | payload: &1})

          :context ->
            %{command | context: Map.put(context, "snapshot_digest", String.duplicate("f", 64))}
        end

      assert {:error, :secure_execution_persisted_command_correlation_mismatch} =
               Dispatcher.dispatch(attempt,
                 resource_loader: fn _ -> {:ok, resources} end,
                 preflight_evidence_reader: preflight_evidence_reader(resources),
                 current_authorizer: &authorize_current/3,
                 claim: &claim/4,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   {:error, {:transport_interrupted, "Bearer must-not-escape"}}
                 end,
                 command_fetcher: fn _ -> {:ok, command} end,
                 mark_dispatched: fn _, _, _ -> flunk("tampered command must not be accepted") end
               )
    end
  end

  defp launch_attempt(
         operation_state,
         execution_state,
         now \\ DateTime.truncate(DateTime.utc_now(), :microsecond)
       ) do
    operation = operation(operation_state)
    controller = controller()
    execution = execution(execution_state, controller)

    {operation, execution, evidence} =
      attach_live_preflight(operation, execution, controller, now)

    {:ok, request} = Contract.launch_request(operation, execution)

    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: @operation_id,
          execution_id: @execution_id,
          controller_id: @controller_id,
          dispatch_agent_id: "edge-agent-1",
          dispatch_partition_id: "farm01"
        },
        execution,
        request,
        stage: :launch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.launch_job",
        deadline_at: DateTime.add(now, 60, :second)
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned, inserted_at: now})
      )

    {attempt,
     %{
       operation: operation,
       execution: execution,
       controller: controller,
       targets: [],
       preflight_evidence: evidence
     }}
  end

  defp continuation_attempt(stage, purpose, operation_state, execution_state) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    operation = operation(operation_state)
    controller = controller()
    execution = execution(execution_state, controller)

    targets = [%{id: Ash.UUID.generate(), awx_host_id: 77}]

    {:ok, request} =
      case stage do
        :fetch_job -> Contract.fetch_job_request(77)
        :fetch_host_summaries -> Contract.host_summaries_request(77, length(targets))
      end

    terminal_job_snapshot =
      if purpose == :terminal_confirmation,
        do: %{"id" => 77, "status" => "successful"}

    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: @operation_id,
          execution_id: @execution_id,
          controller_id: @controller_id,
          dispatch_agent_id: "edge-agent-1",
          dispatch_partition_id: "farm01"
        },
        execution,
        request,
        stage: stage,
        purpose: purpose,
        command_type:
          if(stage == :fetch_job, do: "awx.fetch_job", else: "awx.fetch_job_host_summaries"),
        expected_job_id: 77,
        terminal_job_snapshot: terminal_job_snapshot,
        deadline_at: DateTime.add(now, 60, :second)
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned, inserted_at: now})
      )

    {attempt,
     %{operation: operation, execution: execution, controller: controller, targets: targets}}
  end

  defp legacy_nonlaunch_attempt(:list_recent_jobs) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    operation = operation(:dispatching)
    controller = controller()

    execution =
      :dispatching
      |> execution(controller)
      |> put_in([:metadata, "awx_created_by_id"], 23)

    {:ok, request} = Contract.recent_jobs_request(execution, DateTime.add(now, -1, :second))

    {:ok, attrs} =
      Contract.build_attempt(
        attempt_base(),
        execution,
        request,
        stage: :list_recent_jobs,
        purpose: :launch_reconciliation,
        command_type: "awx.list_recent_jobs",
        reconcile_after: DateTime.add(now, -1, :second),
        deadline_at: DateTime.add(now, 60, :second)
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned, inserted_at: now})
      )

    {attempt, %{operation: operation, execution: execution, controller: controller, targets: []},
     "awx.list_recent_jobs"}
  end

  defp legacy_nonlaunch_attempt(:cancel_job) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    operation = operation(:failed)
    controller = controller()
    execution = execution(:failed, controller)
    {:ok, request} = Contract.cancel_job_request(77)

    {:ok, attrs} =
      Contract.build_attempt(
        attempt_base(),
        execution,
        request,
        stage: :cancel_job,
        purpose: :terminal_cleanup,
        command_type: "awx.cancel_job",
        expected_job_id: 77,
        deadline_at: DateTime.add(now, 60, :second)
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned, inserted_at: now})
      )

    {attempt, %{operation: operation, execution: execution, controller: controller, targets: []},
     "awx.cancel_job"}
  end

  defp attempt_base do
    %{
      operation_id: @operation_id,
      execution_id: @execution_id,
      controller_id: @controller_id,
      dispatch_agent_id: "edge-agent-1",
      dispatch_partition_id: "farm01"
    }
  end

  defp operation(state) do
    %{
      id: @operation_id,
      state: state,
      callback_actions: [],
      declared_inputs: %{},
      mutating: true
    }
  end

  defp controller do
    %{
      id: @controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: "edge-agent-1",
      enabled: true,
      credential_secret_id: Ash.UUID.generate(),
      sync_credential_secret_id: Ash.UUID.generate(),
      execution_credential_secret_id: @execution_secret,
      callback_credential_secret_id: nil,
      metadata: %{}
    }
  end

  defp execution(state, controller) do
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    %{
      id: @execution_id,
      operation_id: @operation_id,
      controller_id: @controller_id,
      state: state,
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
  end

  defp attach_live_preflight(operation, execution, controller, verified_at) do
    {:ok, security_snapshot} = ControllerSecuritySnapshot.capture(controller)
    {:ok, security_digest} = ControllerSecuritySnapshot.digest(security_snapshot)

    attestation = %{
      schema: AwxLaunchPreflightAttestation.schema(),
      evidence_id: @preflight_evidence_id,
      command_id: @preflight_command_id,
      controller_id: @controller_id,
      dispatch_agent_id: "edge-agent-1",
      dispatch_partition_id: "farm01",
      binding_id: @preflight_binding_id,
      binding_version: 1,
      approval_id: @preflight_approval_id,
      reviewed_launch_snapshot_digest: String.duplicate("a", 64),
      preflight_request_digest: String.duplicate("b", 64),
      target_snapshot_digest: String.duplicate("c", 64),
      controller_security_snapshot_digest: security_digest,
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

  defp drop_preflight_snapshot(resource) do
    Map.drop(resource, [
      :preflight_evidence_id,
      :immutable_launch_snapshot,
      :immutable_launch_snapshot_digest
    ])
  end

  defp claim(claimed, _token, _expires, _now), do: {:ok, %{claimed | state: :dispatching}}

  defp authorize_current(_resources, _now, _context), do: :ok

  defp persisted_command(attempt, controller, request, context) do
    args =
      request.launch_opts
      |> stringify()
      |> Map.put("template_id", request.template_id)

    {:ok, scope} = AwxClient.broker_scope(controller.base_url, attempt.command_type, args)

    broker = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v2",
      "grant_id" => Ash.UUID.generate(),
      "grant_type" => "awx_oauth2_token",
      "credential_secret_ref" => SecretRefs.network_credential_ref(@execution_secret),
      "consumer" => %{
        "kind" => "ansible",
        "id" => @controller_id,
        "purpose" => attempt.command_type
      },
      "target" => %{
        "kind" => "awx_controller",
        "id" => @controller_id,
        "agent_id" => "edge-agent-1"
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

    payload = %{
      "schema" => "serviceradar.awx_command.v1",
      "verb" => attempt.command_type,
      "args" => args,
      "base_url" => scope.base_url,
      "controller_id" => @controller_id,
      "controller_name" => controller.name,
      "insecure_skip_verify" => false,
      "credential_broker" => broker,
      "authorized_request_body_b64" => scope.authorized_request_body_b64
    }

    struct!(AgentCommand, %{
      id: attempt.command_id,
      command_type: attempt.command_type,
      agent_id: attempt.dispatch_agent_id,
      partition_id: attempt.dispatch_partition_id,
      context: context,
      payload: payload
    })
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
