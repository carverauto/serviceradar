defmodule ServiceRadar.Automation.Ansible.CallbackCommandResultProvenanceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.CallbackCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  @now ~U[2026-07-13 23:30:00.000000Z]
  @credential_id 401

  defmodule CaptureAttemptStore do
    @moduledoc false

    def list_for_grant(_grant_id, _opts), do: {:ok, []}

    def mark_ambiguous(attempt, attrs, _opts) do
      send(Process.get(:callback_provenance_test_pid), {:attempt_ambiguous, attempt, attrs})
      {:ok, %{attempt | state: :ambiguous}}
    end

    def mark_succeeded(attempt, attrs, _opts) do
      send(Process.get(:callback_provenance_test_pid), {:attempt_succeeded, attempt, attrs})
      {:ok, %{attempt | state: :succeeded}}
    end

    def create_planned(attrs, _opts) do
      attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))
      send(Process.get(:callback_provenance_test_pid), {:attempt_planned, attempt})
      {:ok, attempt}
    end
  end

  defmodule CaptureLifecycle do
    @moduledoc false

    def revoke_verified_cleanup(grant_id, binding, reason, _opts) do
      send(
        Process.get(:callback_provenance_test_pid),
        {:verified_cleanup_revoked, grant_id, binding, reason}
      )

      {:ok, %{id: grant_id, state: :revoked}}
    end

    def revoke(grant_id, reason, _opts) do
      send(Process.get(:callback_provenance_test_pid), {:grant_revoked, grant_id, reason})
      {:ok, %{id: grant_id, state: :revoked}}
    end

    def bind_credential(grant_id, credential_id, _opts) do
      send(
        Process.get(:callback_provenance_test_pid),
        {:unexpected_credential_bind, grant_id, credential_id}
      )

      {:error, :unexpected_credential_bind}
    end

    def bind_job(grant_id, binding, _opts) do
      send(Process.get(:callback_provenance_test_pid), {:unexpected_job_bind, grant_id, binding})
      {:error, :unexpected_job_bind}
    end

    def activate(grant_id, binding, _opts) do
      send(
        Process.get(:callback_provenance_test_pid),
        {:unexpected_activation, grant_id, binding}
      )

      {:error, :unexpected_activation}
    end
  end

  defmodule CaptureExecutionLifecycleActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.ExecutionLifecycleActions

    @impl true
    def bind_accepted_job(execution, snapshot) do
      send(Process.get(:callback_provenance_test_pid), {:unexpected_execution_bind, snapshot})
      {:ok, execution}
    end

    @impl true
    def mark_scope_verified(execution, summaries, evidence) do
      send(
        Process.get(:callback_provenance_test_pid),
        {:unexpected_scope_activation, summaries, evidence}
      )

      {:ok, execution}
    end

    @impl true
    def reject_scope(_execution, _targets, _evidence), do: :ok
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
      send(Process.get(:callback_provenance_test_pid), {
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

  setup do
    Process.put(:callback_provenance_test_pid, self())
    :ok
  end

  test "complete controller provenance retains every verified candidate beyond one page" do
    env = environment()
    jobs = Enum.map(10_001..10_075, &accepted_job(env, &1, "running"))
    bundle = recent_jobs_bundle(env, [])

    assert {:ok, :verified_launch_candidates_contained} =
             process(bundle,
               controller_provenance: fn controller, request, _opts ->
                 assert controller.id == env.controller.id
                 assert request.page_size == 50
                 {:ok, %{jobs: jobs, complete?: true}}
               end,
               lifecycle: CaptureLifecycle,
               lifecycle_opts: [],
               secure_lifecycle_actions: CaptureSecureLifecycleActions
             )

    assert_receive {:attempt_ambiguous, _attempt, attrs}
    assert attrs.last_error_code == "callback_launch_reconciliation_ambiguous"

    assert_receive {:attempt_planned, cleanup}
    assert cleanup.stage == :cancel_job

    retained_ids = [cleanup.expected_job_id | cleanup.candidate_job_ids]
    assert retained_ids == Enum.to_list(10_001..10_075)
    assert length(retained_ids) == 75

    grant_id = env.grant.id
    assert_receive {:grant_revoked, ^grant_id, :callback_launch_reconciliation_ambiguous}
    assert_receive {:execution_failed_closed, _, _, _, :dispatch_ambiguous, diagnostics}
    assert diagnostics["cancel_required"] == true
    assert_receive {:dispatched_follow_up, ^cleanup}
  end

  test "forged cancel success cannot remove an independently unconfirmed job from cleanup" do
    env = environment()
    bundle = cancel_bundle(env, 20_001, [20_002, 20_003])

    assert {:ok, :cancel_not_independently_confirmed} =
             process(bundle,
               controller_provenance: fn controller, job_id, _opts ->
                 assert controller.id == env.controller.id
                 assert job_id == 20_001
                 {:ok, %{"id" => job_id, "status" => "running"}}
               end
             )

    assert_receive {:attempt_succeeded, _attempt, attrs}
    assert attrs.outcome_code == "cancel_not_independently_confirmed"

    assert_receive {:attempt_planned, retry}
    assert retry.stage == :cancel_job
    assert retry.expected_job_id == 20_001
    assert retry.candidate_job_ids == [20_002, 20_003]
    assert_receive {:dispatched_follow_up, ^retry}
  end

  test "independently observed terminal job advances the durable cleanup queue" do
    env = environment()
    bundle = cancel_bundle(env, 30_001, [30_002, 30_003])

    assert {:ok, :candidate_canceled} =
             process(bundle,
               controller_provenance: fn _controller, job_id, _opts ->
                 {:ok, %{"id" => job_id, "status" => "canceled"}}
               end
             )

    assert_receive {:attempt_planned, next}
    assert next.expected_job_id == 30_002
    assert next.candidate_job_ids == [30_003]
    assert_receive {:dispatched_follow_up, ^next}
  end

  test "live callback wake-ups require and bind the authenticated gateway partition" do
    env = environment()
    bundle = cancel_bundle(env, 30_101, [])

    refute_received {:attempt_succeeded, _, _}

    assert {:error, :authenticated_partition_required} =
             Coordinator.handle_command_result(%{
               command_id: bundle.command.id,
               command_type: bundle.command.command_type,
               agent_id: bundle.command.agent_id
             })

    assert {:error, :callback_result_authenticated_partition_mismatch} =
             Coordinator.handle_command_result(
               %{
                 command_id: bundle.command.id,
                 command_type: bundle.command.command_type,
                 agent_id: bundle.command.agent_id,
                 partition_id: "tonka01"
               },
               bundle_loader: fn _ -> {:ok, bundle} end
             )

    refute_received {:attempt_succeeded, _, _}
  end

  test "attested callback result provenance ignores mutable execution boundary metadata" do
    env = environment()
    bundle = recent_jobs_bundle(env, [])

    bundle =
      put_in(bundle, [:execution, :metadata], %{
        "awx_created_by_id" => 11,
        "dispatch_partition_id" => "tonka01",
        "controller_security_snapshot" => %{"tampered" => true}
      })

    {:ok, expected_snapshot} = ControllerSecuritySnapshot.capture(env.controller)

    assert {:ok, :launch_candidate_not_visible} =
             process(bundle,
               controller_provenance: fn controller, request, provenance_opts ->
                 assert controller.id == env.controller.id
                 assert request.template_id == env.execution.job_template_id
                 assert provenance_opts[:expected_partition_id] == "farm01"
                 assert provenance_opts[:expected_controller_snapshot] == expected_snapshot
                 {:ok, %{jobs: [], complete?: true}}
               end
             )

    assert_receive {:attempt_planned, retry}
    assert retry.stage == :list_recent_jobs
  end

  test "legacy callback credential results are constrained to cleanup and cannot schedule launch" do
    env = environment()

    bundle =
      env |> create_credential_bundle(cleanup_only: false) |> remove_preflight_attestation()

    assert {:ok, :credential_cleanup_lookup_scheduled} =
             process(bundle,
               controller_credential_lookup: fn _controller, _expected, _opts ->
                 {:ok, %{credentials: [], complete?: true}}
               end
             )

    assert_receive {:attempt_planned, cleanup}
    assert cleanup.stage == :fetch_credential
    assert cleanup.cleanup_only == true
    refute cleanup.stage == :launch_job
  end

  test "an expired preflight contains an already-launched callback job without binding or activation" do
    env = environment()
    job_id = 40_101
    bundle = env |> launch_bundle(job_id, cleanup_only: false) |> expire_preflight_attestation()

    {:ok, expected_snapshot} = ControllerSecuritySnapshot.capture(env.controller)

    assert {:ok, :launch_cleanup_contained} =
             process(bundle,
               lifecycle: CaptureLifecycle,
               lifecycle_opts: [],
               controller_provenance: fn controller, ^job_id, provenance_opts ->
                 assert controller.id == env.controller.id
                 assert provenance_opts[:expected_partition_id] == "farm01"
                 assert provenance_opts[:expected_controller_snapshot] == expected_snapshot
                 {:ok, accepted_job(env, job_id, "running")}
               end
             )

    grant_id = env.grant.id

    assert_receive {:verified_cleanup_revoked, ^grant_id,
                    %{credential_id: @credential_id, job_id: ^job_id},
                    :callback_deadline_cleanup_only}

    refute_received {:unexpected_credential_bind, _, _}
    refute_received {:unexpected_job_bind, _, _}
    refute_received {:unexpected_execution_bind, _}
    refute_received {:unexpected_scope_activation, _, _}
    refute_received {:unexpected_activation, _, _}
  end

  test "deadline cleanup for credential creation persists a read-only cleanup retry" do
    env = environment_with_unbound_credential()
    bundle = create_credential_bundle(env, cleanup_only: false)

    assert {:ok, :credential_cleanup_lookup_scheduled} =
             process(bundle,
               cleanup_only: true,
               lifecycle: CaptureLifecycle,
               lifecycle_opts: [],
               controller_credential_lookup: fn controller, expected, _opts ->
                 assert controller.id == env.controller.id
                 assert expected.credential_name == "sr-callback-#{env.execution.id}"
                 {:ok, %{credentials: [], complete?: true}}
               end,
               execution_lifecycle_actions: CaptureExecutionLifecycleActions
             )

    assert_receive {:attempt_planned, cleanup_retry}
    assert cleanup_retry.stage == :fetch_credential
    assert cleanup_retry.purpose == :credential_reconciliation
    assert cleanup_retry.command_type == "awx.fetch_callback_credential"
    assert cleanup_retry.cleanup_only == true
    assert DateTime.after?(cleanup_retry.deadline_at, @now)
    assert Contract.context(cleanup_retry, env.execution)["cleanup_only"] == true

    assert Contract.context_matches?(
             cleanup_retry,
             env.execution,
             Contract.context(cleanup_retry, env.execution)
           )

    assert_receive {:dispatched_follow_up, ^cleanup_retry}
    refute_received {:unexpected_credential_bind, _, _}
    refute_received {:unexpected_job_bind, _, _}
    refute_received {:unexpected_execution_bind, _}
    refute_received {:unexpected_scope_activation, _, _}
    refute_received {:unexpected_activation, _, _}
  end

  test "persistent cleanup credential retry can only revoke the independently verified selector" do
    env = environment_with_unbound_credential()
    bundle = fetch_credential_bundle(env, cleanup_only: true)

    verified = %{
      "id" => @credential_id,
      "name" => "sr-callback-#{env.execution.id}",
      "credential_type_id" => env.grant.awx_scope_snapshot.callback_credential_type_id,
      "organization_id" => env.grant.awx_scope_snapshot.callback_credential_organization_id
    }

    assert {:ok, :credential_cleanup_contained} =
             process(bundle,
               lifecycle: CaptureLifecycle,
               lifecycle_opts: [],
               controller_credential_lookup: fn _controller, _expected, _opts ->
                 {:ok, %{credentials: [verified], complete?: true}}
               end,
               execution_lifecycle_actions: CaptureExecutionLifecycleActions
             )

    grant_id = env.grant.id

    assert_receive {:verified_cleanup_revoked, ^grant_id, %{credential_id: @credential_id},
                    :callback_deadline_cleanup_only}

    assert_receive {:attempt_succeeded, _attempt, attrs}
    assert attrs.outcome_code == "credential_cleanup_contained"
    refute_received {:attempt_planned, _}
    refute_received {:unexpected_credential_bind, _, _}
    refute_received {:unexpected_job_bind, _, _}
    refute_received {:unexpected_execution_bind, _}
    refute_received {:unexpected_scope_activation, _, _}
    refute_received {:unexpected_activation, _, _}
  end

  test "deadline cleanup for a terminal launch revokes exact selectors without binding or activation" do
    env = environment()
    job_id = 40_001
    bundle = launch_bundle(env, job_id, cleanup_only: false)

    assert {:ok, :launch_cleanup_contained} =
             process(bundle,
               cleanup_only: true,
               lifecycle: CaptureLifecycle,
               lifecycle_opts: [],
               controller_provenance: fn controller, ^job_id, _opts ->
                 assert controller.id == env.controller.id
                 {:ok, accepted_job(env, job_id, "running")}
               end,
               execution_lifecycle_actions: CaptureExecutionLifecycleActions
             )

    grant_id = env.grant.id

    assert_receive {:verified_cleanup_revoked, ^grant_id,
                    %{credential_id: @credential_id, job_id: ^job_id},
                    :callback_deadline_cleanup_only}

    assert_receive {:attempt_succeeded, _attempt, attrs}
    assert attrs.outcome_code == "launch_cleanup_contained"
    refute_received {:attempt_planned, _}
    refute_received {:unexpected_credential_bind, _, _}
    refute_received {:unexpected_job_bind, _, _}
    refute_received {:unexpected_execution_bind, _}
    refute_received {:unexpected_scope_activation, _, _}
    refute_received {:unexpected_activation, _, _}
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
        transaction: fn fun -> {:ok, fun.()} end,
        rollback: fn reason -> throw({:rollback, reason}) end,
        dispatcher: fn attempt ->
          send(self(), {:dispatched_follow_up, attempt})
          {:ok, :dispatched}
        end,
        preflight_evidence_reader: fn evidence_id ->
          case value(bundle, :preflight_evidence) do
            %{id: ^evidence_id} = evidence -> {:ok, evidence}
            _ -> {:error, :not_found}
          end
        end,
        now: @now
      ] ++ opts
    )
  end

  defp recent_jobs_bundle(env, agent_jobs) do
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
      "count" => length(agent_jobs),
      "complete" => true,
      "jobs" => agent_jobs
    }

    exact_bundle(env, request, result_payload,
      stage: :list_recent_jobs,
      purpose: :launch_reconciliation,
      command_type: "awx.list_recent_jobs",
      expected_credential_id: @credential_id,
      reconcile_after: reconcile_after,
      candidate_job_ids: []
    )
  end

  defp create_credential_bundle(env, opts) do
    {:ok, request} =
      Contract.create_credential_request(
        env.execution,
        env.grant.awx_scope_snapshot,
        env.grant.launch_envelope_ref
      )

    scope = env.grant.awx_scope_snapshot

    result_payload = %{
      "verb" => "awx.create_callback_credential",
      "ok" => true,
      # This assigned-agent selector is deliberately not authoritative.
      "credential_id" => 999_999,
      "credential_type_id" => scope.callback_credential_type_id,
      "organization_id" => scope.callback_credential_organization_id,
      "credential_name" => "sr-callback-#{env.execution.id}",
      "injector_sha256" => scope.callback_credential_injector_digest
    }

    exact_bundle(
      env,
      request,
      result_payload,
      Keyword.merge(
        [
          stage: :create_credential,
          purpose: :credential_creation,
          command_type: "awx.create_callback_credential"
        ],
        opts
      )
    )
  end

  defp fetch_credential_bundle(env, opts) do
    {:ok, request} =
      Contract.credential_lookup_request(env.execution, env.grant.awx_scope_snapshot)

    result_payload = %{
      "verb" => "awx.fetch_callback_credential",
      "ok" => true,
      "found" => true,
      # The direct controller lookup below proves a different exact selector.
      "credential_id" => 999_999,
      "credential_type_id" => request.credential_type_id,
      "organization_id" => request.organization_id,
      "credential_name" => request.credential_name
    }

    exact_bundle(
      env,
      request,
      result_payload,
      Keyword.merge(
        [
          stage: :fetch_credential,
          purpose: :credential_reconciliation,
          command_type: "awx.fetch_callback_credential"
        ],
        opts
      )
    )
  end

  defp launch_bundle(env, job_id, opts) do
    {:ok, request} = Contract.launch_request(env.operation, env.execution, @credential_id)

    result_payload = %{
      "verb" => "awx.launch_job",
      "ok" => true,
      "template_id" => env.execution.job_template_id,
      "job" => %{"id" => job_id}
    }

    exact_bundle(
      env,
      request,
      result_payload,
      Keyword.merge(
        [
          stage: :launch_job,
          purpose: :accepted_job_proof,
          command_type: "awx.launch_job",
          expected_credential_id: @credential_id
        ],
        opts
      )
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

    exact_bundle(env, request, result_payload,
      stage: :cancel_job,
      purpose: :terminal_cleanup,
      command_type: "awx.cancel_job",
      expected_credential_id: @credential_id,
      expected_job_id: job_id,
      candidate_job_ids: remaining
    )
  end

  defp exact_bundle(env, request, result_payload, opts) do
    {:ok, attrs} =
      Contract.build_attempt(
        %{
          grant_id: env.grant.id,
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
          opts
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
      %{
        "schema" => "serviceradar.awx_command.v1",
        "verb" => attempt.command_type,
        "args" => args,
        "base_url" => scope.base_url,
        "controller_id" => env.controller.id,
        "controller_name" => env.controller.name,
        "insecure_skip_verify" => false,
        "credential_broker" => broker(env.controller, attempt, scope)
      }
      |> maybe_put_authorized_body(scope)
      |> maybe_put_callback_binding(attempt, request, env)

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
      controller: env.controller,
      grant: env.grant,
      preflight_evidence: env.preflight_evidence
    }
  end

  defp expected_args(%Attempt{stage: :list_recent_jobs}, request), do: stringify(request)
  defp expected_args(%Attempt{stage: :cancel_job}, request), do: %{"job_id" => request.job_id}

  defp expected_args(%Attempt{stage: :create_credential}, request) do
    binding = stringify(request.binding)

    %{
      "credential_type_id" => binding["credential_type_id"],
      "organization_id" => binding["organization_id"],
      "credential_name" => "sr-callback-#{binding["child_execution_id"]}",
      "injector_sha256" => binding["injector_sha256"]
    }
  end

  defp expected_args(%Attempt{stage: :fetch_credential}, request), do: stringify(request)

  defp expected_args(%Attempt{stage: :launch_job}, request) do
    request.launch_opts
    |> stringify()
    |> Map.put("template_id", request.template_id)
  end

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

  defp maybe_put_callback_binding(payload, %Attempt{stage: :create_credential}, request, env) do
    binding =
      request.binding
      |> stringify()
      |> Map.put("schema", "serviceradar.awx_callback_credential_binding.v1")
      |> Map.put("credential_name", "sr-callback-#{env.execution.id}")
      |> Map.put("dispatch_agent_id", env.controller.agent_id)
      |> Map.put("controller_id", env.controller.id)

    Map.put(payload, "callback_credential_binding", binding)
  end

  defp maybe_put_callback_binding(payload, _attempt, _request, _env), do: payload

  defp environment do
    operation_id = Ash.UUID.generate()
    execution_id = Ash.UUID.generate()
    controller_id = Ash.UUID.generate()
    grant_id = Ash.UUID.generate()
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
      callback_credential_secret_id: secret_id,
      metadata: %{}
    }

    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)
    {preflight_attrs, preflight_evidence} = preflight_attrs(controller)

    operation =
      Map.merge(
        %{
          id: operation_id,
          mutating: true,
          declared_inputs: %{},
          callback_actions: ["remote_access.ssh_ca.bundle.read"],
          state: :dispatching
        },
        preflight_attrs
      )

    execution =
      Map.merge(
        %{
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
          state: :dispatching
        },
        preflight_attrs
      )

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

    grant = %{
      id: grant_id,
      ephemeral_credential_id: @credential_id,
      launch_envelope_ref: "launch-envelope-ref",
      awx_scope_snapshot: %{
        controller_id: controller_id,
        inventory_id: 34,
        job_template_id: 42,
        callback_credential_type_id: 71,
        callback_credential_organization_id: 72,
        callback_credential_injector_digest: String.duplicate("b", 64)
      },
      state: :pending,
      dispatch_agent_id: controller.agent_id,
      dispatch_partition_id: "farm01"
    }

    %{
      controller: controller,
      operation: operation,
      execution: execution,
      targets: targets,
      grant: grant,
      preflight_evidence: preflight_evidence
    }
  end

  defp environment_with_unbound_credential do
    env = environment()
    %{env | grant: %{env.grant | ephemeral_credential_id: nil}}
  end

  defp preflight_attrs(controller) do
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
      binding_version: 3,
      approval_id: Ash.UUID.generate(),
      reviewed_launch_snapshot_digest: String.duplicate("a", 64),
      preflight_request_digest: String.duplicate("b", 64),
      target_snapshot_digest: String.duplicate("c", 64),
      controller_security_snapshot_digest: controller_security_snapshot_digest,
      live_launch_snapshot_digest: String.duplicate("d", 64),
      command_result_digest: String.duplicate("e", 64),
      verified_at: DateTime.add(@now, -1, :second),
      expires_at: DateTime.add(@now, 60, :second)
    }

    {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation)
    {attrs, preflight_evidence(attestation)}
  end

  defp preflight_evidence(attestation) do
    %{
      id: value(attestation, :evidence_id),
      command_id: value(attestation, :command_id),
      controller_id: value(attestation, :controller_id),
      dispatch_agent_id: value(attestation, :dispatch_agent_id),
      dispatch_partition_id: value(attestation, :dispatch_partition_id),
      binding_id: value(attestation, :binding_id),
      binding_version: value(attestation, :binding_version),
      approval_id: value(attestation, :approval_id),
      reviewed_launch_snapshot_digest: value(attestation, :reviewed_launch_snapshot_digest),
      preflight_request_digest: value(attestation, :preflight_request_digest),
      target_snapshot_digest: value(attestation, :target_snapshot_digest),
      controller_security_snapshot_digest:
        value(attestation, :controller_security_snapshot_digest),
      live_launch_snapshot_digest: value(attestation, :live_launch_snapshot_digest),
      command_result_digest: value(attestation, :command_result_digest),
      verified_at: value(attestation, :verified_at),
      expires_at: value(attestation, :expires_at)
    }
  end

  defp remove_preflight_attestation(bundle) do
    fields = [
      :preflight_evidence_id,
      :immutable_launch_snapshot,
      :immutable_launch_snapshot_digest
    ]

    bundle
    |> update_in([:operation], &Map.drop(&1, fields))
    |> update_in([:execution], &Map.drop(&1, fields))
  end

  defp expire_preflight_attestation(bundle) do
    attestation =
      bundle.operation.immutable_launch_snapshot
      |> Map.put("verified_at", DateTime.to_iso8601(DateTime.add(@now, -120, :second)))
      |> Map.put("expires_at", DateTime.to_iso8601(DateTime.add(@now, -1, :second)))

    {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation)

    %{
      bundle
      | operation: Map.merge(bundle.operation, attrs),
        execution: Map.merge(bundle.execution, attrs),
        preflight_evidence: preflight_evidence(attestation)
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
      "credentials" => [
        %{"id" => 5, "kind" => "machine"},
        %{"id" => @credential_id, "kind" => "vault"}
      ],
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

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
