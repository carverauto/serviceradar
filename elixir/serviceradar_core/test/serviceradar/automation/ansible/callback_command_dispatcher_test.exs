defmodule ServiceRadar.Automation.Ansible.CallbackCommandDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  @now ~U[2026-07-13 12:00:00.000000Z]
  @preflight_evidence_id "018f3f56-1111-7222-8333-123456789a01"
  @preflight_command_id "018f3f56-1111-7222-8333-123456789a02"
  @controller_id "018f3f56-1111-7222-8333-123456789abe"
  @preflight_binding_id "018f3f56-1111-7222-8333-123456789a04"
  @preflight_approval_id "018f3f56-1111-7222-8333-123456789a05"
  @execution_secret "018f3f56-2222-7222-8333-123456789abe"

  test "a fast terminal result may take the processing lease before dispatch returns" do
    controller = controller(Ash.UUID.generate(), "agent-farm01")
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    execution = %{
      id: Ash.UUID.generate(),
      dispatch_id: Ash.UUID.generate(),
      snapshot_digest: String.duplicate("a", 64),
      metadata: security_metadata(controller_snapshot)
    }

    base = %{
      grant_id: Ash.UUID.generate(),
      operation_id: Ash.UUID.generate(),
      execution_id: execution.id,
      controller_id: controller.id,
      dispatch_agent_id: "agent-farm01",
      dispatch_partition_id: "farm01"
    }

    {:ok, request} = CallbackCommandContract.fetch_job_request(42)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, execution, request,
        stage: :fetch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.fetch_job",
        expected_job_id: 42,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    assert {:ok, :result_already_processing} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               callback_authorizer: &authorize_callback/3,
               resource_loader: fn ^attempt ->
                 {:ok,
                  %{
                    operation: %{},
                    execution: execution,
                    controller: controller,
                    grant: %{
                      dispatch_agent_id: base.dispatch_agent_id,
                      dispatch_partition_id: base.dispatch_partition_id
                    }
                  }}
               end,
               claim: fn ^attempt, lease_token, lease_expires_at, now ->
                 assert now == @now

                 {:ok,
                  %{
                    attempt
                    | state: :dispatching,
                      lease_token: lease_token,
                      lease_expires_at: lease_expires_at
                  }}
               end,
               awx_dispatcher: fn claimed, _controller, ^request, context, _opts ->
                 assert claimed.state == :dispatching
                 assert context["verb"] == "awx.fetch_job"
                 {:ok, %{id: claimed.command_id}}
               end,
               mark_dispatched: fn _claimed, _token, now ->
                 assert now == @now
                 {:error, :stale_lease}
               end,
               attempt_fetcher: fn id ->
                 assert id == attempt.id
                 {:ok, %{attempt | state: :processing}}
               end
             )
  end

  test "dispatch crash-window reconciliation requires the full persisted callback command" do
    {attempt, resources, request} = fetch_job_attempt()
    context = CallbackCommandContract.context(attempt, resources.execution)
    command = persisted_command(attempt, resources.controller, request, context)

    assert CallbackCommandContract.context_matches?(attempt, resources.execution, command.context)

    assert CallbackCommandContract.persisted_payload_matches?(
             attempt,
             resources.execution,
             resources.controller,
             request,
             command.payload
           )

    assert {:ok, :persisted_for_recovery} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               callback_authorizer: &authorize_callback/3,
               resource_loader: fn _ -> {:ok, resources} end,
               claim: &claim/4,
               awx_dispatcher: fn _, _, _, _, _ -> {:error, :transport_interrupted} end,
               command_fetcher: fn _ -> {:ok, command} end,
               mark_dispatched: fn claimed, _token, _now ->
                 {:ok, %{claimed | state: :dispatched}}
               end
             )
  end

  test "dispatch rejects a grant from the same agent in another partition before claiming" do
    {attempt, resources, _request} = fetch_job_attempt()
    resources = put_in(resources, [:grant, :dispatch_partition_id], "tonka01")

    assert {:error, :callback_command_resource_principal_mismatch} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               claim: fn _, _, _, _ -> flunk("cross-partition resources must not be claimed") end,
               awx_dispatcher: fn _, _, _, _, _ ->
                 flunk("cross-partition resources must not reach AWX")
               end
             )
  end

  test "dispatch crash-window reconciliation rejects tampered callback payload and context" do
    for tamper <- [:payload, :context] do
      {attempt, resources, request} = fetch_job_attempt()
      context = CallbackCommandContract.context(attempt, resources.execution)
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

      assert {:error, :callback_command_persisted_correlation_mismatch} =
               CallbackCommandDispatcher.dispatch(attempt,
                 now: @now,
                 callback_authorizer: &authorize_callback/3,
                 resource_loader: fn _ -> {:ok, resources} end,
                 claim: &claim/4,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   {:error, {:transport_interrupted, "Bearer must-not-escape"}}
                 end,
                 command_fetcher: fn _ -> {:ok, command} end,
                 mark_dispatched: fn _, _, _ -> flunk("tampered command must not be accepted") end
               )
    end
  end

  test "dispatch retry persists only a structural failure code" do
    {attempt, resources, _request} = fetch_job_attempt()
    secret = "Bearer callback-dispatch-must-not-survive"
    test_pid = self()

    assert {:ok, :deferred} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               callback_authorizer: &authorize_callback/3,
               resource_loader: fn _ -> {:ok, resources} end,
               claim: &claim/4,
               awx_dispatcher: fn _, _, _, _, _ ->
                 {:error, {:http_error, %{response_body: secret}}}
               end,
               command_fetcher: fn _ -> {:ok, nil} end,
               release_dispatch: fn _attempt, _token, _next_at, error_code ->
                 send(test_pid, {:error_code, error_code})
                 {:ok, %{attempt | state: :waiting, last_error_code: error_code}}
               end
             )

    assert_receive {:error_code, "http_error"}
    refute_received {:error_code, ^secret}
  end

  test "launch authority contraction is denied before claim or AWX dispatch" do
    {attempt, resources} = launch_attempt()
    test_pid = self()

    assert {:error, :current_permission_denied} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: fn mode, grant, _opts ->
                 assert mode == :launch
                 assert grant.id == attempt.grant_id
                 {:error, :current_permission_denied}
               end,
               claim: fn _, _, _, _ ->
                 flunk("denied launch must not acquire a dispatch lease")
               end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("denied launch must not reach AWX") end,
               prelaunch_denial_handler: fn denied_resources ->
                 send(test_pid, {:prelaunch_denied, denied_resources.operation.id})
                 :ok
               end,
               authority_denial_marker: fn denied_attempt, reason, now, _opts ->
                 send(test_pid, {:denial_marked, denied_attempt.id, reason, now})
                 {:ok, denied_attempt}
               end
             )

    assert_receive {:prelaunch_denied, operation_id}
    assert operation_id == attempt.operation_id
    assert_receive {:denial_marked, attempt_id, :current_permission_denied, @now}
    assert attempt_id == attempt.id
  end

  test "credential creation reauthorizes current user before claim or AWX dispatch" do
    {attempt, resources} = create_credential_attempt()
    test_pid = self()

    assert {:error, :current_permission_denied} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: fn mode, grant, _opts ->
                 assert mode == :credential_creation
                 assert grant.id == attempt.grant_id
                 {:error, :current_permission_denied}
               end,
               claim: fn _, _, _, _ ->
                 flunk("denied credential creation must not acquire a dispatch lease")
               end,
               awx_dispatcher: fn _, _, _, _, _ ->
                 flunk("denied credential creation must not reach AWX")
               end,
               prelaunch_denial_handler: fn denied_resources ->
                 send(test_pid, {:credential_prelaunch_denied, denied_resources.operation.id})
                 :ok
               end,
               authority_denial_marker: fn denied_attempt, reason, now, _opts ->
                 send(test_pid, {:credential_denial_marked, denied_attempt.id, reason, now})
                 {:ok, denied_attempt}
               end
             )

    assert_receive {:credential_prelaunch_denied, operation_id}
    assert operation_id == attempt.operation_id
    assert_receive {:credential_denial_marked, attempt_id, :current_permission_denied, @now}
    assert attempt_id == attempt.id
  end

  test "legacy callback mutation stages cannot reach a lease or AWX" do
    for {stage, {attempt, resources}} <- [
          create_credential: create_credential_attempt(),
          launch_job: launch_attempt()
        ] do
      assert {:error, :awx_preflight_attestation_required} =
               CallbackCommandDispatcher.dispatch(attempt,
                 now: @now,
                 resource_loader: fn ^attempt -> {:ok, resources} end,
                 callback_authorizer: &authorize_callback/3,
                 claim: fn _, _, _, _ ->
                   flunk("legacy #{stage} must not acquire a dispatch lease")
                 end,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   flunk("legacy #{stage} must not reach AWX")
                 end
               )
    end
  end

  test "callback launch requires evidence-backed immutable preflight on the exact edge tuple" do
    {attempt, resources} = launch_attempt()
    {resources, evidence} = attested_resources(resources)
    test_pid = self()

    assert {:ok, :dispatched} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: &authorize_callback/3,
               preflight_evidence_reader: fn @preflight_evidence_id -> {:ok, evidence} end,
               claim: &claim/4,
               awx_dispatcher: fn claimed, controller, request, _context, _opts ->
                 send(test_pid, {:awx_launch, claimed, controller, request})
                 {:ok, %{id: claimed.command_id}}
               end,
               mark_dispatched: fn claimed, _token, _now -> {:ok, claimed} end
             )

    assert_receive {:awx_launch, claimed, controller, request}
    assert claimed.dispatch_agent_id == "edge-agent-1"
    assert claimed.dispatch_partition_id == "farm01"
    assert controller.id == @controller_id
    assert request.template_id == 42
  end

  test "callback launch rejects an attested partition that differs from its durable attempt" do
    {attempt, resources} = launch_attempt()
    {resources, evidence} = attested_resources(resources, dispatch_partition_id: "tonka01")

    assert {:error, :awx_preflight_partition_drift} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: &authorize_callback/3,
               preflight_evidence_reader: fn @preflight_evidence_id -> {:ok, evidence} end,
               claim: fn _, _, _, _ -> flunk("partition drift must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("partition drift must not reach AWX") end
             )
  end

  test "an expired preflight permits an attested read-only callback continuation" do
    {attempt, resources, request} = fetch_job_attempt()

    {resources, evidence} =
      attested_resources(resources,
        verified_at: DateTime.add(@now, -120, :second),
        expires_at: DateTime.add(@now, -1, :second)
      )

    assert {:ok, :dispatched} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: &authorize_callback/3,
               preflight_evidence_reader: fn @preflight_evidence_id -> {:ok, evidence} end,
               claim: &claim/4,
               awx_dispatcher: fn claimed, _controller, ^request, _context, _opts ->
                 send(self(), {:read_only_dispatch, claimed.stage})
                 {:ok, %{id: claimed.command_id}}
               end,
               mark_dispatched: fn claimed, _token, _now -> {:ok, claimed} end
             )

    assert_receive {:read_only_dispatch, :fetch_job}
  end

  test "an expired preflight still rejects callback launch before a lease or AWX" do
    {attempt, resources} = launch_attempt()

    {resources, evidence} =
      attested_resources(resources,
        verified_at: DateTime.add(@now, -120, :second),
        expires_at: DateTime.add(@now, -1, :second)
      )

    assert {:error, :awx_preflight_evidence_expired} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: &authorize_callback/3,
               preflight_evidence_reader: fn @preflight_evidence_id -> {:ok, evidence} end,
               claim: fn _, _, _, _ -> flunk("expired launch must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("expired launch must not reach AWX") end
             )
  end

  test "active watchdog contraction enters the cancellation-unproven failure path" do
    {attempt, resources, _request} = fetch_job_attempt(:terminal_poll)
    resources = Map.put(resources, :targets, [%{id: Ash.UUID.generate()}])
    test_pid = self()

    assert {:error, :principal_disabled} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt -> {:ok, resources} end,
               callback_authorizer: fn mode, _grant, _opts ->
                 assert mode == :watchdog
                 {:error, :principal_disabled}
               end,
               claim: fn _, _, _, _ -> flunk("denied watchdog must not acquire a lease") end,
               awx_dispatcher: fn _, _, _, _, _ -> flunk("denied watchdog must not reach AWX") end,
               active_contraction_handler: fn denied_resources, reason ->
                 send(
                   test_pid,
                   {:active_contraction, denied_resources.operation.mutating, reason,
                    denied_resources.targets}
                 )

                 {:ok, :held}
               end,
               authority_denial_marker: fn denied_attempt, reason, now, _opts ->
                 send(test_pid, {:denial_marked, denied_attempt.id, reason, now})
                 {:ok, denied_attempt}
               end
             )

    assert_receive {:active_contraction, true, :principal_disabled, [_target]}
    assert_receive {:denial_marked, attempt_id, :principal_disabled, @now}
    assert attempt_id == attempt.id
  end

  test "every pre-activation known-job phase reauthorizes and cancels on contraction" do
    phases = [
      {:fetch_job, :accepted_job_proof},
      {:fetch_job, :scope_poll},
      {:fetch_host_summaries, :host_scope_proof}
    ]

    test_pid = self()

    for {stage, purpose} <- phases do
      {attempt, resources} = pending_continuation_attempt(stage, purpose)

      assert {:error, :approval_changed} =
               CallbackCommandDispatcher.dispatch(attempt,
                 now: @now,
                 resource_loader: fn ^attempt -> {:ok, resources} end,
                 callback_authorizer: fn mode, grant, _opts ->
                   assert mode == :pending_job
                   assert grant.id == attempt.grant_id
                   {:error, :approval_changed}
                 end,
                 active_contraction_handler: fn denied_resources, reason ->
                   send(
                     test_pid,
                     {:pending_contracted, stage, purpose, denied_resources.targets, reason}
                   )

                   {:ok, :held_and_cancel_requested}
                 end,
                 authority_denial_marker: fn denied_attempt, reason, _now, _opts ->
                   send(test_pid, {:pending_denied, denied_attempt.id, reason})
                   {:ok, denied_attempt}
                 end,
                 claim: fn _, _, _, _ ->
                   flunk("contracted pending child must not acquire a lease")
                 end,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   flunk("contracted pending child must not reach AWX")
                 end
               )

      assert_receive {:pending_contracted, ^stage, ^purpose, [_target], :approval_changed}
      assert_receive {:pending_denied, attempt_id, :approval_changed}
      assert attempt_id == attempt.id
    end
  end

  test "terminal confirmation attempts require one bound terminal job snapshot" do
    {attempt, resources, _request} = fetch_job_attempt(:terminal_poll)
    {:ok, request} = CallbackCommandContract.host_summaries_request(42, 1)

    base = %{
      grant_id: attempt.grant_id,
      operation_id: attempt.operation_id,
      execution_id: attempt.execution_id,
      controller_id: attempt.controller_id,
      dispatch_agent_id: attempt.dispatch_agent_id,
      dispatch_partition_id: attempt.dispatch_partition_id
    }

    common = [
      stage: :fetch_host_summaries,
      purpose: :terminal_confirmation,
      command_type: "awx.fetch_job_host_summaries",
      expected_job_id: 42,
      deadline_at: DateTime.add(@now, 60, :second),
      next_attempt_at: @now
    ]

    assert {:error, :invalid_callback_terminal_job_evidence} =
             CallbackCommandContract.build_attempt(base, resources.execution, request, common)

    terminal = %{"id" => 42, "status" => "successful"}

    assert {:ok, attrs} =
             CallbackCommandContract.build_attempt(
               base,
               resources.execution,
               request,
               Keyword.put(common, :terminal_job_snapshot, terminal)
             )

    assert attrs.terminal_job_snapshot == terminal

    assert {:error, :invalid_callback_terminal_job_evidence} =
             CallbackCommandContract.build_attempt(
               base,
               resources.execution,
               request,
               Keyword.put(common, :terminal_job_snapshot, %{terminal | "id" => 43})
             )

    assert {:error, :invalid_callback_terminal_job_evidence} =
             CallbackCommandContract.build_attempt(
               base,
               resources.execution,
               %{job_id: 42},
               stage: :fetch_job,
               purpose: :terminal_poll,
               command_type: "awx.fetch_job",
               expected_job_id: 42,
               terminal_job_snapshot: terminal,
               deadline_at: DateTime.add(@now, 60, :second),
               next_attempt_at: @now
             )
  end

  defp fetch_job_attempt(purpose \\ :accepted_job_proof) do
    execution = %{
      id: "018f3f56-1111-7222-8333-123456789abd",
      operation_id: "018f3f56-1111-7222-8333-123456789abc",
      controller_id: @controller_id,
      dispatch_id: "018f3f56-1111-7222-8333-123456789abf",
      snapshot_digest: String.duplicate("a", 64)
    }

    base = %{
      grant_id: "018f3f56-1111-7222-8333-123456789ac0",
      operation_id: execution.operation_id,
      execution_id: execution.id,
      controller_id: @controller_id,
      dispatch_agent_id: "edge-agent-1",
      dispatch_partition_id: "farm01"
    }

    controller = controller(@controller_id, "edge-agent-1")
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)
    execution = Map.put(execution, :metadata, security_metadata(controller_snapshot))

    {:ok, request} = CallbackCommandContract.fetch_job_request(42)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, execution, request,
        stage: :fetch_job,
        purpose: purpose,
        command_type: "awx.fetch_job",
        expected_job_id: 42,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    resources = %{
      operation: %{
        id: execution.operation_id,
        mutating: true,
        callback_actions: ["remote_access.ssh_ca.bundle.read"]
      },
      execution: execution,
      controller: controller,
      grant: %{
        dispatch_agent_id: base.dispatch_agent_id,
        dispatch_partition_id: base.dispatch_partition_id
      }
    }

    {attempt, resources, request}
  end

  defp launch_attempt do
    controller = controller(@controller_id, "edge-agent-1")
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    execution = %{
      id: "018f3f56-1111-7222-8333-123456789abd",
      operation_id: "018f3f56-1111-7222-8333-123456789abc",
      controller_id: @controller_id,
      dispatch_id: "018f3f56-1111-7222-8333-123456789abf",
      snapshot_digest: String.duplicate("a", 64),
      job_template_id: 42,
      inventory_id: 34,
      host_limit: "linux-01",
      execution_environment_id: 4,
      check_mode: false,
      credential_snapshot: %{"credential_ids" => [5]},
      metadata: security_metadata(controller_snapshot)
    }

    operation = %{
      id: execution.operation_id,
      mutating: true,
      declared_inputs: %{},
      callback_actions: ["remote_access.ssh_ca.bundle.read"]
    }

    base = %{
      grant_id: "018f3f56-1111-7222-8333-123456789ac0",
      operation_id: operation.id,
      execution_id: execution.id,
      controller_id: @controller_id,
      dispatch_agent_id: "edge-agent-1",
      dispatch_partition_id: "farm01"
    }

    {:ok, request} = CallbackCommandContract.launch_request(operation, execution, 91)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, execution, request,
        stage: :launch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.launch_job",
        expected_credential_id: 91,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    resources = %{
      operation: operation,
      execution: execution,
      controller: controller,
      grant: %{
        id: base.grant_id,
        dispatch_agent_id: base.dispatch_agent_id,
        dispatch_partition_id: base.dispatch_partition_id
      },
      targets: [%{id: Ash.UUID.generate()}]
    }

    {attempt, resources}
  end

  defp create_credential_attempt do
    controller = controller(@controller_id, "edge-agent-1")
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    execution = %{
      id: "018f3f56-1111-7222-8333-123456789abd",
      operation_id: "018f3f56-1111-7222-8333-123456789abc",
      controller_id: @controller_id,
      dispatch_id: "018f3f56-1111-7222-8333-123456789abf",
      snapshot_digest: String.duplicate("a", 64),
      metadata: security_metadata(controller_snapshot)
    }

    scope = %{
      inventory_id: 34,
      job_template_id: 42,
      callback_credential_type_id: 17,
      callback_credential_organization_id: 3,
      callback_credential_injector_digest: String.duplicate("c", 64)
    }

    grant_id = "018f3f56-1111-7222-8333-123456789ac0"
    envelope_ref = "018f3f56-1111-7222-8333-123456789ac1"

    {:ok, request} =
      CallbackCommandContract.create_credential_request(execution, scope, envelope_ref)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(
        %{
          grant_id: grant_id,
          operation_id: execution.operation_id,
          execution_id: execution.id,
          controller_id: @controller_id,
          dispatch_agent_id: controller.agent_id,
          dispatch_partition_id: "farm01"
        },
        execution,
        request,
        stage: :create_credential,
        purpose: :credential_provisioning,
        command_type: "awx.create_callback_credential",
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    resources = %{
      operation: %{id: execution.operation_id, mutating: true},
      execution: execution,
      controller: controller,
      grant: %{
        id: grant_id,
        launch_envelope_ref: envelope_ref,
        awx_scope_snapshot: scope,
        dispatch_agent_id: controller.agent_id,
        dispatch_partition_id: "farm01"
      },
      targets: [%{id: Ash.UUID.generate()}]
    }

    {attempt, resources}
  end

  defp pending_continuation_attempt(:fetch_job, purpose) do
    {attempt, resources, _request} = fetch_job_attempt(purpose)

    resources =
      resources
      |> Map.put(:grant, %{
        id: attempt.grant_id,
        dispatch_agent_id: attempt.dispatch_agent_id,
        dispatch_partition_id: attempt.dispatch_partition_id
      })
      |> Map.put(:targets, [%{id: Ash.UUID.generate()}])

    {attempt, resources}
  end

  defp pending_continuation_attempt(:fetch_host_summaries, :host_scope_proof) do
    {fetch_attempt, resources, _request} = fetch_job_attempt(:scope_poll)
    targets = [%{id: Ash.UUID.generate()}]
    {:ok, request} = CallbackCommandContract.host_summaries_request(42, length(targets))

    base = %{
      grant_id: fetch_attempt.grant_id,
      operation_id: fetch_attempt.operation_id,
      execution_id: fetch_attempt.execution_id,
      controller_id: fetch_attempt.controller_id,
      dispatch_agent_id: fetch_attempt.dispatch_agent_id,
      dispatch_partition_id: fetch_attempt.dispatch_partition_id
    }

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, resources.execution, request,
        stage: :fetch_host_summaries,
        purpose: :host_scope_proof,
        command_type: "awx.fetch_job_host_summaries",
        expected_job_id: 42,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    {attempt,
     resources
     |> Map.put(:grant, %{
       id: attempt.grant_id,
       dispatch_agent_id: attempt.dispatch_agent_id,
       dispatch_partition_id: attempt.dispatch_partition_id,
       awx_scope_snapshot: %{targets: targets}
     })
     |> Map.put(:targets, targets)}
  end

  defp persisted_command(attempt, controller, request, context) do
    args = %{"job_id" => request.job_id}
    {:ok, scope} = AwxClient.broker_scope(controller.base_url, attempt.command_type, args)

    broker = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
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
        "agent_id" => attempt.dispatch_agent_id
      },
      "resolution_location" => "agent",
      "inject" => %{
        "type" => "http_header",
        "name" => "Authorization",
        "scheme" => "Bearer"
      },
      "allow" => scope.allow,
      "ttl_seconds" => 300,
      "expires_at" => @now |> DateTime.add(300, :second) |> DateTime.to_iso8601()
    }

    struct!(AgentCommand, %{
      id: attempt.command_id,
      command_type: attempt.command_type,
      agent_id: attempt.dispatch_agent_id,
      partition_id: attempt.dispatch_partition_id,
      context: context,
      payload: %{
        "schema" => "serviceradar.awx_command.v1",
        "verb" => attempt.command_type,
        "args" => args,
        "base_url" => scope.base_url,
        "controller_id" => @controller_id,
        "controller_name" => controller.name,
        "insecure_skip_verify" => false,
        "credential_broker" => broker
      }
    })
  end

  defp claim(claimed, _token, _expires, _now), do: {:ok, %{claimed | state: :dispatching}}

  defp authorize_callback(_mode, _grant, _opts), do: :ok

  defp attested_resources(resources, overrides \\ %{}) do
    overrides = Map.new(overrides)
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(resources.controller)

    {:ok, controller_security_snapshot_digest} =
      ControllerSecuritySnapshot.digest(controller_snapshot)

    attestation =
      Map.merge(
        %{
          schema: AwxLaunchPreflightAttestation.schema(),
          evidence_id: @preflight_evidence_id,
          command_id: @preflight_command_id,
          controller_id: resources.controller.id,
          dispatch_agent_id: resources.controller.agent_id,
          dispatch_partition_id: "farm01",
          binding_id: @preflight_binding_id,
          binding_version: 3,
          approval_id: @preflight_approval_id,
          reviewed_launch_snapshot_digest: String.duplicate("a", 64),
          preflight_request_digest: String.duplicate("b", 64),
          target_snapshot_digest: String.duplicate("c", 64),
          controller_security_snapshot_digest: controller_security_snapshot_digest,
          live_launch_snapshot_digest: String.duplicate("d", 64),
          command_result_digest: String.duplicate("e", 64),
          verified_at: DateTime.add(@now, -1, :second),
          expires_at: DateTime.add(@now, 60, :second)
        },
        overrides
      )

    assert {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation)

    resources = %{
      resources
      | operation: Map.merge(resources.operation, attrs),
        execution: Map.merge(resources.execution, attrs)
    }

    {resources, preflight_evidence(attestation)}
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

  defp controller(id, agent_id) do
    %{
      id: id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: agent_id,
      enabled: true,
      credential_secret_id: Ash.UUID.generate(),
      sync_credential_secret_id: Ash.UUID.generate(),
      execution_credential_secret_id: @execution_secret,
      callback_credential_secret_id: Ash.UUID.generate(),
      metadata: %{}
    }
  end

  defp security_metadata(controller_snapshot) do
    %{
      "dispatch_partition_id" => "farm01",
      "controller_security_snapshot" => controller_snapshot
    }
  end
end
