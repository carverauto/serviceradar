defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandResultProvenanceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  @now ~U[2026-07-13 23:45:00.000000Z]

  defmodule CaptureAttemptStore do
    @moduledoc false

    def list_for_execution(_execution_id, _opts), do: {:ok, []}

    def mark_failed(attempt, attrs, _opts) do
      send(Process.get(:secure_provenance_test_pid), {:attempt_failed, attempt, attrs})
      {:ok, %{attempt | state: :failed}}
    end

    def mark_ambiguous(attempt, attrs, _opts) do
      send(Process.get(:secure_provenance_test_pid), {:attempt_ambiguous, attempt, attrs})
      {:ok, %{attempt | state: :ambiguous}}
    end

    def mark_succeeded(attempt, attrs, _opts) do
      send(Process.get(:secure_provenance_test_pid), {:attempt_succeeded, attempt, attrs})
      {:ok, %{attempt | state: :succeeded}}
    end

    def create_planned(attrs, _opts) do
      attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))
      send(Process.get(:secure_provenance_test_pid), {:attempt_planned, attempt})
      {:ok, attempt}
    end
  end

  defmodule CaptureSecureLifecycleActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureExecutionLifecycleActions

    @impl true
    def mark_running(_operation, _execution), do: {:error, :unexpected_mark_running}

    @impl true
    def complete_terminal(_operation, _execution, _outcomes, _state, _evidence),
      do: {:error, :unexpected_complete_terminal}

    @impl true
    def fail_closed(operation, execution, targets, state, diagnostics) do
      send(Process.get(:secure_provenance_test_pid), {
        :execution_failed_closed,
        operation,
        execution,
        targets,
        state,
        diagnostics
      })

      {:ok, %{state: state}}
    end
  end

  defmodule CaptureExecutionLifecycleActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.ExecutionLifecycleActions

    @impl true
    def bind_accepted_job(execution, snapshot) do
      send(Process.get(:secure_provenance_test_pid), {:accepted_job_bound, snapshot})

      {:ok,
       execution
       |> Map.put(:state, :launching)
       |> Map.put(:awx_job_id, snapshot["awx_job_id"])
       |> Map.put(:accepted_job_snapshot, snapshot)}
    end

    @impl true
    def mark_scope_verified(_execution, _targets, _evidence),
      do: {:error, :unexpected_scope_verification}

    @impl true
    def reject_scope(_execution, _targets, diagnostics) do
      send(Process.get(:secure_provenance_test_pid), {:scope_rejected, diagnostics})
      :ok
    end
  end

  setup do
    Process.put(:secure_provenance_test_pid, self())
    :ok
  end

  test "agent-substituted launch job id is rejected without becoming cancellation authority" do
    env = environment()
    bundle = launch_bundle(env, 91_001)
    victim = env |> accepted_job(91_001, "running") |> Map.put("limit", "unrelated-host")

    assert {:ok, :failed_closed} =
             process(bundle,
               controller_provenance: fn controller, job_id, opts ->
                 assert controller.id == env.controller.id
                 assert job_id == 91_001
                 assert opts[:expected_partition_id] == "farm01"
                 assert opts[:expected_controller_snapshot] == env.controller_snapshot
                 {:ok, victim}
               end
             )

    assert_receive {:scope_rejected, diagnostics}
    assert diagnostics.reason == :accepted_limit_mismatch
    assert_receive {:execution_failed_closed, _, _, _, :failed, failure}
    assert failure["cancel_required"] == false
    assert_receive {:attempt_failed, _, attrs}
    assert attrs.last_error_code == "accepted_limit_mismatch"
    refute_receive {:attempt_planned, %{stage: :cancel_job}}
    refute_receive {:accepted_job_bound, _snapshot}
  end

  test "forged cancel success retries the same independently active job" do
    env = environment()
    bundle = cancel_bundle(env, 92_001, [92_002, 92_003])

    assert {:ok, :cancel_not_independently_confirmed} =
             process(bundle,
               controller_provenance: fn _controller, job_id, _opts ->
                 {:ok, %{"id" => job_id, "status" => "running"}}
               end
             )

    assert_receive {:attempt_planned, retry}
    assert retry.stage == :cancel_job
    assert retry.expected_job_id == 92_001
    assert retry.candidate_job_ids == [92_002, 92_003]
    assert_receive {:dispatched_follow_up, ^retry}
  end

  test "independently terminal cancellation advances the durable queue" do
    env = environment()
    bundle = cancel_bundle(env, 93_001, [93_002, 93_003])

    assert {:ok, :candidate_canceled} =
             process(bundle,
               controller_provenance: fn _controller, job_id, _opts ->
                 {:ok, %{"id" => job_id, "status" => "canceled"}}
               end
             )

    assert_receive {:attempt_planned, next}
    assert next.expected_job_id == 93_002
    assert next.candidate_job_ids == [93_003]
    assert_receive {:dispatched_follow_up, ^next}
  end

  test "reconciliation retains every independently verified active candidate beyond one page" do
    env = environment()
    jobs = Enum.map(94_001..94_075, &accepted_job(env, &1, "running"))
    bundle = recent_jobs_bundle(env)

    assert {:ok, :dispatch_ambiguous} =
             process(bundle,
               controller_provenance: fn _controller, request, _opts ->
                 assert request.page_size == 50
                 {:ok, %{jobs: jobs, complete?: true}}
               end
             )

    assert_receive {:attempt_ambiguous, _, attrs}
    assert attrs.last_error_code == "multiple_launch_candidates"
    assert_receive {:attempt_planned, cleanup}

    retained = [cleanup.expected_job_id | cleanup.candidate_job_ids]
    assert retained == Enum.to_list(94_001..94_075)
    assert length(retained) == 75
    assert_receive {:execution_failed_closed, _, _, _, :dispatch_ambiguous, diagnostics}
    assert diagnostics["cancel_required"] == true
    assert_receive {:dispatched_follow_up, ^cleanup}
  end

  defp process(bundle, opts) do
    Coordinator.process_persisted(
      bundle.command.id,
      bundle.command.agent_id,
      bundle.command.command_type,
      [
        bundle_loader: fn _command_id -> {:ok, bundle} end,
        processing_claimer: fn attempt, token, expires_at, now ->
          {:ok,
           %{
             attempt
             | state: :processing,
               lease_token: token,
               lease_expires_at: expires_at,
               processing_started_at: now
           }}
        end,
        attempt_store: CaptureAttemptStore,
        transaction: &transaction/1,
        rollback: fn reason -> throw({:rollback, reason}) end,
        dispatcher: fn attempt ->
          send(self(), {:dispatched_follow_up, attempt})
          {:ok, :dispatched}
        end,
        execution_lifecycle_actions: CaptureExecutionLifecycleActions,
        secure_lifecycle_actions: CaptureSecureLifecycleActions,
        now: @now
      ] ++ opts
    )
  end

  defp transaction(fun) do
    {:ok, fun.()}
  catch
    {:rollback, reason} -> {:error, reason}
  end

  defp launch_bundle(env, job_id) do
    {:ok, request} = Contract.launch_request(env.operation, env.execution)

    result_payload = %{
      "verb" => "awx.launch_job",
      "ok" => true,
      "template_id" => request.template_id,
      "job" => %{"id" => job_id, "status" => "pending"}
    }

    exact_bundle(env, request, result_payload,
      stage: :launch_job,
      purpose: :accepted_job_proof,
      command_type: "awx.launch_job"
    )
  end

  defp recent_jobs_bundle(env) do
    reconcile_after = DateTime.add(@now, -60, :second)
    {:ok, request} = Contract.recent_jobs_request(env.execution, reconcile_after)

    result_payload = %{
      "verb" => "awx.list_recent_jobs",
      "ok" => true,
      "template_id" => request.template_id,
      "inventory_id" => request.inventory_id,
      "created_by_id" => request.created_by_id,
      "created_after" => request.created_after,
      "page_size" => request.page_size,
      "max_candidates" => request.max_candidates,
      "count" => 0,
      "complete" => true,
      "jobs" => []
    }

    exact_bundle(env, request, result_payload,
      stage: :list_recent_jobs,
      purpose: :launch_reconciliation,
      command_type: "awx.list_recent_jobs",
      reconcile_after: reconcile_after
    )
  end

  defp cancel_bundle(env, job_id, remaining) do
    {:ok, request} = Contract.cancel_job_request(job_id)

    result_payload = %{
      "verb" => "awx.cancel_job",
      "ok" => true,
      "job_id" => job_id,
      "status" => 202
    }

    env =
      env
      |> put_in([:operation, :state], :dispatch_ambiguous)
      |> put_in([:execution, :state], :dispatch_ambiguous)

    exact_bundle(env, request, result_payload,
      stage: :cancel_job,
      purpose: :terminal_cleanup,
      command_type: "awx.cancel_job",
      expected_job_id: job_id,
      candidate_job_ids: remaining
    )
  end

  defp exact_bundle(env, request, result_payload, attempt_opts) do
    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: env.operation.id,
          execution_id: env.execution.id,
          controller_id: env.controller.id,
          dispatch_agent_id: env.controller.agent_id,
          dispatch_partition_id: "farm01"
        },
        env.execution,
        request,
        Keyword.merge(
          [
            attempt: 1,
            deadline_at: DateTime.add(@now, 120, :second),
            next_attempt_at: @now
          ],
          attempt_opts
        )
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :dispatched, dispatched_at: @now})
      )

    context = Contract.context(attempt, env.execution)
    args = expected_args(attempt, request)
    {:ok, scope} = AwxClient.broker_scope(env.controller.base_url, attempt.command_type, args)

    payload =
      maybe_put_authorized_body(
        %{
          "schema" => "serviceradar.awx_command.v1",
          "verb" => attempt.command_type,
          "args" => args,
          "base_url" => scope.base_url,
          "controller_id" => env.controller.id,
          "controller_name" => env.controller.name,
          "insecure_skip_verify" => false,
          "credential_broker" => broker(env.controller, attempt, scope)
        },
        scope
      )

    assert Contract.persisted_payload_matches?(
             attempt,
             env.execution,
             env.controller,
             request,
             payload
           )

    command =
      struct!(AgentCommand,
        id: attempt.command_id,
        command_type: attempt.command_type,
        agent_id: attempt.dispatch_agent_id,
        partition_id: attempt.dispatch_partition_id,
        status: :completed,
        payload: payload,
        context: context,
        result_payload: result_payload
      )

    %{
      command: command,
      attempt: attempt,
      operation: env.operation,
      execution: env.execution,
      targets: env.targets,
      controller: env.controller
    }
  end

  defp expected_args(%Attempt{stage: :launch_job}, request) do
    request.launch_opts
    |> stringify_deep()
    |> Map.put("template_id", request.template_id)
  end

  defp expected_args(%Attempt{stage: :list_recent_jobs}, request), do: stringify_deep(request)
  defp expected_args(%Attempt{stage: :cancel_job}, request), do: %{"job_id" => request.job_id}

  defp broker(controller, attempt, scope) do
    %{
      "schema" => broker_schema(scope),
      "grant_id" => Ash.UUID.generate(),
      "grant_type" => "awx_oauth2_token",
      "credential_secret_ref" =>
        SecretRefs.network_credential_ref(controller.execution_credential_secret_id),
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
      "expires_at" => @now |> DateTime.add(300, :second) |> DateTime.to_iso8601()
    }
  end

  defp broker_schema(%{request_body_policy: policy}) when is_map(policy) and map_size(policy) > 0,
    do: CredentialBrokerGrant.body_bound_schema()

  defp broker_schema(_scope), do: CredentialBrokerGrant.schema()

  defp maybe_put_authorized_body(payload, %{authorized_request_body_b64: nil}), do: payload

  defp maybe_put_authorized_body(payload, scope),
    do: Map.put(payload, "authorized_request_body_b64", scope.authorized_request_body_b64)

  defp environment do
    operation_id = Ash.UUID.generate()
    execution_id = Ash.UUID.generate()
    controller_id = Ash.UUID.generate()
    secret_id = Ash.UUID.generate()

    controller = %{
      id: controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: "edge-agent-1",
      enabled: true,
      credential_secret_id: secret_id,
      sync_credential_secret_id: secret_id,
      execution_credential_secret_id: secret_id,
      callback_credential_secret_id: nil,
      metadata: %{}
    }

    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    operation = %{
      id: operation_id,
      mutating: true,
      declared_inputs: %{},
      callback_actions: [],
      state: :dispatching,
      run_budget: %{"max_runtime_seconds" => 600}
    }

    execution = %{
      id: execution_id,
      operation_id: operation_id,
      controller_id: controller_id,
      dispatch_id: Ash.UUID.generate(),
      snapshot_digest: String.duplicate("d", 64),
      job_template_id: 42,
      inventory_id: 34,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      execution_environment_id: 4,
      machine_credential_id: 5,
      host_limit: "farm01-pve01",
      check_mode: false,
      credential_snapshot: %{
        "credential_ids" => [5],
        "credentials" => [%{"id" => 5, "kind" => "machine"}]
      },
      metadata: %{
        "awx_created_by_id" => 11,
        "dispatch_partition_id" => "farm01",
        "controller_security_snapshot" => controller_snapshot
      },
      awx_job_id: nil,
      accepted_job_snapshot: nil,
      state: :dispatching,
      started_at: @now
    }

    targets = [
      %{
        id: Ash.UUID.generate(),
        membership_id: Ash.UUID.generate(),
        execution_id: execution_id,
        controller_id: controller_id,
        inventory_id: 34,
        awx_host_id: 7,
        canonical_device_uid: "sr:device-7",
        host_name: "farm01-pve01"
      }
    ]

    %{
      controller: controller,
      controller_snapshot: controller_snapshot,
      operation: operation,
      execution: execution,
      targets: targets
    }
  end

  defp accepted_job(env, job_id, status) do
    %{
      "id" => job_id,
      "status" => status,
      "created" => DateTime.to_iso8601(@now),
      "job_template" => env.execution.job_template_id,
      "inventory" => env.execution.inventory_id,
      "limit" => env.execution.host_limit,
      "project" => env.execution.project_id,
      "scm_revision" => env.execution.scm_revision,
      "execution_environment" => env.execution.execution_environment_id,
      "credentials" => [%{"id" => 5, "kind" => "machine"}],
      "launched_by" => %{"id" => 11},
      "job_type" => "run",
      "job_slice_count" => 1,
      "job_slice_number" => 0,
      "dispatch_markers" => %{
        "serviceradar_dispatch_id" => env.execution.dispatch_id,
        "serviceradar_snapshot_digest" => env.execution.snapshot_digest
      }
    }
  end

  defp stringify_deep(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify_deep(item)} end)
  end

  defp stringify_deep(value) when is_list(value), do: Enum.map(value, &stringify_deep/1)
  defp stringify_deep(value), do: value
end
