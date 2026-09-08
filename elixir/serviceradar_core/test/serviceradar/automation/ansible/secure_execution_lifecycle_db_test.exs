defmodule ServiceRadar.Automation.Ansible.SecureExecutionLifecycleDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @actor SystemActor.system(:secure_execution_lifecycle_db_test)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "durable attempt claims exactly once and enforces one active stage" do
    fixture = fixture(:dispatching)
    {:ok, request} = Contract.launch_request(fixture.operation, fixture.execution)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: fixture.operation.id,
          execution_id: fixture.execution.id,
          controller_id: fixture.controller_id,
          dispatch_agent_id: "edge-secure-db",
          dispatch_partition_id: "farm01"
        },
        fixture.execution,
        request,
        stage: :launch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.launch_job",
        deadline_at: DateTime.add(now, 60, :second)
      )

    assert {:ok, attempt} = Attempt.create_planned(attrs, actor: @actor)

    claims =
      [Ash.UUID.generate(), Ash.UUID.generate()]
      |> Task.async_stream(
        fn token ->
          Attempt.claim_dispatch(
            attempt,
            %{
              lease_token: token,
              lease_expires_at: DateTime.add(now, 15, :second),
              now: now
            },
            actor: @actor
          )
        end,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(claims, &match?({:ok, %Attempt{state: :dispatching}}, &1)) == 1
    assert Enum.count(claims, &match?({:error, _reason}, &1)) == 1

    duplicate =
      attrs
      |> Map.put(:attempt, 2)
      |> Map.put(:command_id, Ash.UUID.generate())

    assert {:error, _reason} = Attempt.create_planned(duplicate, actor: @actor)
    assert {:ok, stored} = Attempt.get_by_command_id(attempt.command_id, actor: @actor)
    assert stored.state == :dispatching
  end

  test "fail-closed mutation state, target outcome, and hold commit atomically without secrets" do
    fixture = fixture(:running)
    secret = "Bearer durable-row-must-not-contain-this"

    assert {:ok, _result} =
             SecureExecutionLifecycle.fail_closed(
               fixture.operation,
               fixture.execution,
               [fixture.target],
               :dispatch_ambiguous,
               {:transport_failed, %{response_body: secret}}
             )

    assert {:ok, operation} = AutomationOperation.get_by_id(fixture.operation.id, actor: @actor)
    assert {:ok, execution} = AutomationExecution.get_by_id(fixture.execution.id, actor: @actor)
    assert {:ok, target} = AutomationExecutionTarget.get_by_id(fixture.target.id, actor: @actor)

    assert {:ok, hold} =
             AutomationTargetHold.get_active_for_device(fixture.device_uid, actor: @actor)

    assert operation.state == :dispatch_ambiguous
    assert execution.state == :dispatch_ambiguous
    assert target.status == :scope_mismatch
    assert hold.active
    assert hold.evidence_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert hold.reason == "transport_failed"

    durable = [operation.diagnostics, execution.diagnostics, target.diagnostics, hold.diagnostics]
    refute inspect(durable) =~ secret
    assert Enum.all?(durable, &(&1["reason"] == "transport_failed"))
  end

  test "a target update failure rolls back operation, execution, and hold state" do
    fixture = fixture(:running)
    missing_target = %{fixture.target | id: Ash.UUID.generate()}

    assert {:error, _reason} =
             SecureExecutionLifecycle.fail_closed(
               fixture.operation,
               fixture.execution,
               [missing_target],
               :failed,
               :forced_target_write_failure
             )

    assert {:ok, operation} = AutomationOperation.get_by_id(fixture.operation.id, actor: @actor)
    assert {:ok, execution} = AutomationExecution.get_by_id(fixture.execution.id, actor: @actor)
    assert {:ok, target} = AutomationExecutionTarget.get_by_id(fixture.target.id, actor: @actor)

    # Active-hold reads are optional lookups (not_found_error?: false).
    assert {:ok, nil} =
             AutomationTargetHold.get_active_for_device(fixture.device_uid, actor: @actor)

    assert operation.state == :running
    assert execution.state == :running
    assert target.status == :pending
  end

  defp fixture(state) do
    suffix = System.unique_integer([:positive])
    controller_id = Ash.UUID.generate()
    membership_id = Ash.UUID.generate()
    device_uid = "sr:secure-execution-db-#{suffix}"
    source_fingerprint = "sha256:" <> String.duplicate("d", 64)

    SQL.query!(Repo, "INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [device_uid])

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_controllers
        (id, name, base_url, agent_id, credential_secret_id,
         sync_credential_secret_id, execution_credential_secret_id)
      VALUES (($1::text)::uuid, $2, 'https://awx.example.test', 'edge-secure-db',
              ($3::text)::uuid, ($3::text)::uuid, ($4::text)::uuid)
      """,
      [
        controller_id,
        "secure-execution-db-#{suffix}",
        # ansible_controllers.*credential_secret_id are foreign keys onto
        # network_credential_secrets; a generated UUID references nothing.
        CredentialIntegrationFixtures.secret_id!(),
        CredentialIntegrationFixtures.secret_id!()
      ]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_awx_host_memberships
        (id, controller_id, inventory_id, awx_host_id, canonical_device_uid,
         source_generation, host_name, ansible_host, enabled, current,
         last_seen_at, link_disposition, source_fingerprint)
      VALUES (($1::text)::uuid, ($2::text)::uuid, 34, 7, $3, 3,
              'farm01-pve01', '192.168.2.22', true, true,
              (now() AT TIME ZONE 'utc'), 'approved', $4)
      """,
      [membership_id, controller_id, device_uid, source_fingerprint]
    )

    {:ok, operation} =
      AutomationOperation.create_operation(
        %{
          tenant_id: "platform",
          action: "ansible.playbook.run",
          mutating: true,
          check_mode: false,
          initiator_principal_type: :human,
          initiator_principal_id: "secure-execution-db-#{suffix}",
          authorization_version: String.duplicate("1", 64),
          authority_ceiling: %{"target_membership_ids" => [membership_id]},
          approval_snapshot: %{},
          request_source: "db_test",
          declared_inputs: %{},
          input_classifications: %{},
          input_digest: String.duplicate("2", 64),
          target_digest: String.duplicate("3", 64),
          callback_actions: [],
          run_budget: %{},
          metadata: %{}
        },
        actor: @actor
      )

    {:ok, operation} =
      AutomationOperation.record_state(operation, %{state: state}, actor: @actor)

    {:ok, execution} =
      AutomationExecution.create_execution(
        %{
          operation_id: operation.id,
          controller_id: controller_id,
          inventory_id: 34,
          job_template_id: 42,
          project_id: 3,
          scm_revision: String.duplicate("a", 40),
          content_sha256: String.duplicate("b", 64),
          execution_environment_id: 4,
          machine_credential_id: 5,
          credential_snapshot: %{"credential_ids" => [5]},
          check_mode: false,
          host_limit: "farm01-pve01",
          dispatch_id: Ash.UUID.generate(),
          snapshot_digest: String.duplicate("c", 64),
          metadata: %{"awx_created_by_id" => 11}
        },
        actor: @actor
      )

    {:ok, execution} =
      AutomationExecution.record_state(execution, %{state: state}, actor: @actor)

    {:ok, target} =
      AutomationExecutionTarget.create_target(
        %{
          execution_id: execution.id,
          membership_id: membership_id,
          canonical_device_uid: device_uid,
          controller_id: controller_id,
          inventory_id: 34,
          awx_host_id: 7,
          membership_generation: 3,
          source_fingerprint: source_fingerprint,
          host_name: "farm01-pve01",
          ansible_host: "192.168.2.22",
          snapshot_digest: String.duplicate("d", 64)
        },
        actor: @actor
      )

    %{
      operation: operation,
      execution: execution,
      target: target,
      controller_id: controller_id,
      device_uid: device_uid
    }
  end
end
