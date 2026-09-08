defmodule ServiceRadar.Automation.Ansible.SecureExecutionContinuationBoundaryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation, as: Attestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Automation.Ansible.SecureExecutionContinuationBoundary, as: Boundary
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  defmodule ObservedClient do
    def fetch_job(controller, job_id, opts) do
      send(self(), {:observed_read, controller.id, job_id, opts[:required_partition]})
      {:error, :synthetic_read_unavailable}
    end
  end

  defmodule FailureActions do
    def fail_closed(_operation, _execution, _targets, _state, diagnostics) do
      send(self(), {:failed_read, diagnostics["reason"]})
      {:ok, %{}}
    end
  end

  defmodule AttemptStore do
    def mark_failed(attempt, _attrs, _opts), do: {:ok, attempt}
  end

  setup do
    now = ~U[2031-03-04 05:06:07.000000Z]
    sync_credential = Ash.UUID.generate()

    controller = %{
      id: Ash.UUID.generate(),
      name: "controller.example.com",
      base_url: "https://controller.example.com",
      agent_id: "synthetic-edge",
      enabled: true,
      credential_secret_id: sync_credential,
      sync_credential_secret_id: sync_credential,
      execution_credential_secret_id: Ash.UUID.generate(),
      callback_credential_secret_id: nil,
      metadata: %{}
    }

    {:ok, security} = ControllerSecuritySnapshot.capture(controller)
    {:ok, security_digest} = ControllerSecuritySnapshot.digest(security)

    snapshot = %{
      schema: Attestation.schema(),
      evidence_id: Ash.UUID.generate(),
      command_id: Ash.UUID.generate(),
      controller_id: controller.id,
      dispatch_agent_id: controller.agent_id,
      dispatch_partition_id: "synthetic-partition",
      binding_id: Ash.UUID.generate(),
      binding_version: 1,
      approval_id: Ash.UUID.generate(),
      reviewed_launch_snapshot_digest: String.duplicate("1", 64),
      preflight_request_digest: String.duplicate("2", 64),
      target_snapshot_digest: String.duplicate("3", 64),
      controller_security_snapshot_digest: security_digest,
      live_launch_snapshot_digest: String.duplicate("4", 64),
      command_result_digest: String.duplicate("5", 64),
      verified_at: DateTime.add(now, -120, :second),
      expires_at: DateTime.add(now, -60, :second)
    }

    {:ok, attrs} = Attestation.attrs(snapshot)
    evidence = Map.put(snapshot, :id, snapshot.evidence_id)

    resources = %{
      operation: Map.merge(%{callback_actions: []}, attrs),
      execution: Map.merge(%{metadata: %{}}, attrs),
      controller: controller
    }

    attempt = %Attempt{
      dispatch_agent_id: controller.agent_id,
      dispatch_partition_id: snapshot.dispatch_partition_id
    }

    reader = fn id ->
      assert id == evidence.id
      {:ok, evidence}
    end

    %{resources: resources, attempt: attempt, now: now, opts: [preflight_evidence_reader: reader]}
  end

  test "existing children retain the evidenced boundary after expiry without legacy metadata",
       c do
    assert :ok = Boundary.verify(c.resources, c.attempt, c.now, c.opts)

    assert {:error, :awx_preflight_evidence_expired} =
             Attestation.verify_persisted(
               c.resources.operation,
               c.resources.execution,
               c.resources.controller,
               c.now,
               evidence_reader: c.opts[:preflight_evidence_reader]
             )
  end

  test "the coordinator uses the attested continuation boundary", c do
    command = %AgentCommand{
      id: Ash.UUID.generate(),
      agent_id: c.attempt.dispatch_agent_id,
      partition_id: c.attempt.dispatch_partition_id,
      command_type: "awx.fetch_job",
      status: :pending
    }

    bundle = Map.merge(c.resources, %{command: command, attempt: c.attempt})
    opts = c.opts ++ [now: c.now, bundle_loader: fn _ -> {:ok, bundle} end]

    assert {:error, :secure_execution_command_not_terminal} =
             Coordinator.process_persisted(
               command.id,
               command.agent_id,
               command.command_type,
               opts
             )
  end

  test "a completed command reaches a fresh provenance read without execution metadata", c do
    bundle = completed_bundle(c)

    assert {:ok, :failed_closed} =
             Coordinator.process_persisted(
               bundle.command.id,
               bundle.command.agent_id,
               bundle.command.command_type,
               c.opts ++
                 [
                   now: c.now,
                   bundle_loader: fn _ -> {:ok, bundle} end,
                   processing_claimer: fn attempt, _, _, _ -> {:ok, attempt} end,
                   transaction: fn fun -> {:ok, fun.()} end,
                   attempt_store: AttemptStore,
                   secure_lifecycle_actions: FailureActions,
                   controller_provenance_opts: [awx_client: ObservedClient]
                 ]
             )

    assert_receive {:observed_read, controller_id, 17, "synthetic-partition"}
    assert controller_id == c.resources.controller.id
    assert_receive {:failed_read, "synthetic_read_unavailable"}
  end

  test "transport recovery rejects a mismatched persisted command before claiming", c do
    bundle = completed_bundle(c)
    bundle = put_in(bundle.command.partition_id, "unrelated-partition")

    assert {:error, :secure_execution_command_correlation_mismatch} =
             Coordinator.reconcile_transport_ambiguity(
               bundle.attempt,
               c.opts ++
                 [
                   now: c.now,
                   bundle_loader: fn _ -> {:ok, bundle} end,
                   processing_claimer: fn _, _, _, _ ->
                     flunk("must not claim substituted command")
                   end
                 ]
             )
  end

  test "controller, edge, evidence and immutable copy drift fail closed", c do
    assert {:error, :awx_preflight_partition_drift} =
             Boundary.verify(
               c.resources,
               %{c.attempt | dispatch_partition_id: "other"},
               c.now,
               c.opts
             )

    changed = put_in(c.resources, [:controller, :base_url], "https://other.example.com")

    assert {:error, :awx_preflight_controller_drift} =
             Boundary.verify(changed, c.attempt, c.now, c.opts)

    assert {:error, _} =
             Boundary.verify(c.resources, c.attempt, c.now,
               preflight_evidence_reader: fn _ -> {:error, :not_found} end
             )

    changed = put_in(c.resources, [:execution, :immutable_launch_snapshot], %{})

    assert {:error, :awx_preflight_attestation_required} =
             Boundary.verify(changed, c.attempt, c.now, c.opts)
  end

  test "a partial attestation cannot fall back to valid legacy metadata", c do
    {:ok, security} = ControllerSecuritySnapshot.capture(c.resources.controller)

    legacy = %{
      operation: %{},
      execution: %{
        metadata: %{
          "dispatch_partition_id" => c.attempt.dispatch_partition_id,
          "controller_security_snapshot" => security
        }
      },
      controller: c.resources.controller
    }

    assert :ok = Boundary.verify(legacy, c.attempt, c.now, c.opts)
    partial = put_in(legacy.operation, %{preflight_evidence_id: Ash.UUID.generate()})

    assert {:error, :awx_preflight_attestation_required} =
             Boundary.verify(partial, c.attempt, c.now, c.opts)
  end

  defp completed_bundle(c) do
    operation = Map.merge(c.resources.operation, %{id: Ash.UUID.generate(), state: :dispatching})

    execution =
      Map.merge(c.resources.execution, %{
        id: Ash.UUID.generate(),
        operation_id: operation.id,
        controller_id: c.resources.controller.id,
        state: :launching,
        dispatch_id: Ash.UUID.generate(),
        snapshot_digest: String.duplicate("6", 64)
      })

    {:ok, request} = Contract.fetch_job_request(17)

    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: operation.id,
          execution_id: execution.id,
          controller_id: c.resources.controller.id,
          dispatch_agent_id: c.attempt.dispatch_agent_id,
          dispatch_partition_id: c.attempt.dispatch_partition_id
        },
        execution,
        request,
        stage: :fetch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.fetch_job",
        expected_job_id: 17,
        deadline_at: DateTime.add(c.now, 60)
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :dispatched}))
    context = Contract.context(attempt, execution)
    controller = c.resources.controller
    {:ok, scope} = AwxClient.broker_scope(controller.base_url, "awx.fetch_job", %{"job_id" => 17})

    broker = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_id" => Ash.UUID.generate(),
      "grant_type" => "awx_oauth2_token",
      "credential_secret_ref" =>
        SecretRefs.network_credential_ref(controller.execution_credential_secret_id),
      "consumer" => %{"kind" => "ansible", "id" => controller.id, "purpose" => "awx.fetch_job"},
      "target" => %{
        "kind" => "awx_controller",
        "id" => controller.id,
        "agent_id" => controller.agent_id
      },
      "resolution_location" => "agent",
      "inject" => %{"type" => "http_header", "name" => "Authorization", "scheme" => "Bearer"},
      "allow" => scope.allow,
      "ttl_seconds" => 300,
      "expires_at" => DateTime.to_iso8601(DateTime.add(c.now, 300))
    }

    command = %AgentCommand{
      id: attempt.command_id,
      agent_id: attempt.dispatch_agent_id,
      partition_id: attempt.dispatch_partition_id,
      command_type: attempt.command_type,
      status: :completed,
      context: context,
      payload: %{
        "schema" => "serviceradar.awx_command.v1",
        "verb" => "awx.fetch_job",
        "args" => %{"job_id" => 17},
        "base_url" => controller.base_url,
        "controller_id" => controller.id,
        "controller_name" => controller.name,
        "insecure_skip_verify" => false,
        "credential_broker" => broker
      },
      result_payload: %{
        "ok" => true,
        "verb" => "awx.fetch_job",
        "job_id" => 17,
        "job" => %{"id" => 17, "status" => "successful"}
      }
    }

    Map.merge(c.resources, %{
      operation: operation,
      execution: execution,
      attempt: attempt,
      command: command,
      targets: [%{id: Ash.UUID.generate()}]
    })
  end
end
