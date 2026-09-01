defmodule ServiceRadar.Automation.Ansible.LiveAwxLaunchPreflightPersistenceDbTest do
  @moduledoc """
  Database-bound regression coverage for the persistence boundary after a live
  AWX preflight. The controller read itself is covered by
  `LiveAwxLaunchPreflightTest`; this test proves that its attestation is the
  only route from `SecureChildLauncher` to durable mutable rows.
  """

  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidence
  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightFixtures, as: Fixtures
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher
  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher.AshActions
  alias ServiceRadar.Automation.Ansible.SecureChildLauncher
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  defmodule DatabaseActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions

    @actor SystemActor.system(:live_awx_launch_preflight_persistence_db_test)

    @impl true
    def persist_plan(plan, controller), do: AshActions.persist_plan(plan, controller)

    @impl true
    def mark_dispatching(persisted), do: AshActions.mark_dispatching(persisted)

    @impl true
    def dispatch(attempt) do
      fixture = fixture!()

      SecureExecutionCommandDispatcher.dispatch(attempt,
        now: fixture.now,
        current_authorizer: fn _attempt, _resources, _now, _context -> :ok end,
        awx_dispatcher: fn claimed, _controller, request, context, _opts ->
          send(test_pid!(), {:awx_launch_job_dispatched, claimed.command_id, request})

          AgentCommand.create_command_with_id(
            %{
              command_id: claimed.command_id,
              command_type: "awx.launch_job",
              agent_id: claimed.dispatch_agent_id,
              partition_id: claimed.dispatch_partition_id,
              payload: %{
                "template_id" => request.template_id,
                "inventory_id" => request.launch_opts.inventory_id,
                "host_limit" => request.launch_opts.host_limit
              },
              context: context,
              ttl_seconds: 60,
              expires_at: DateTime.add(fixture.now, 60, :second),
              requested_by: "system:live_awx_launch_preflight_persistence_db_test"
            },
            actor: @actor
          )
        end
      )
    end

    defp fixture! do
      fetch_process!({__MODULE__, :fixture})
    end

    defp test_pid! do
      fetch_process!({__MODULE__, :test_pid})
    end

    defp fetch_process!(key) do
      case Process.get(key) do
        nil -> raise "missing process-local test fixture: #{inspect(key)}"
        value -> value
      end
    end
  end

  defmodule IntegrationAdapter do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureChildLauncher.Adapter

    @impl true
    def load_current_actor(_actor_id), do: {:ok, value!(:actor)}

    @impl true
    def fresh_authorization(_actor) do
      authorization = value!(:authorization)

      send(
        test_pid!(),
        {:fresh_authorization_read, authorization.profile_id, authorization.profile_updated_at,
         authorization.permissions}
      )

      {:ok, authorization}
    end

    @impl true
    def load_playbook(_playbook_id), do: {:ok, value!(:playbook)}

    @impl true
    def load_memberships(_membership_ids), do: {:ok, [value!(:membership)]}

    @impl true
    def load_binding(_controller_id, _job_template_id), do: {:ok, value!(:binding)}

    @impl true
    def load_controller(_controller_id), do: {:ok, value!(:controller)}

    @impl true
    def active_hold_device_uids(_device_uids), do: {:ok, []}

    @impl true
    def launch(plan, controller) do
      fixture = fixture!()

      HardenedRunLauncher.launch(plan, controller,
        actions: DatabaseActions,
        now: fixture.now,
        edge_principal_resolver: &edge_principal/1
      )
    end

    defp edge_principal("edge-agent-1"),
      do: {:ok, %{agent_id: "edge-agent-1", partition_id: "farm01"}}

    defp fixture! do
      case Process.get({__MODULE__, :fixture}) do
        nil -> raise "missing process-local integration fixture"
        fixture -> fixture
      end
    end

    defp test_pid! do
      case Process.get({__MODULE__, :test_pid}) do
        nil -> raise "missing process-local integration test process"
        test_pid -> test_pid
      end
    end

    defp value!(key), do: Map.fetch!(fixture!(), key)
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Process.put({DatabaseActions, :test_pid}, self())
    Process.put({IntegrationAdapter, :test_pid}, self())
    :ok
  end

  test "a failed live preflight creates no mutable rows or AWX launch command" do
    fixture = fixture()
    seed_dependencies(fixture, evidence?: false)
    baseline = row_counts(fixture)

    assert {:error, :awx_preflight_static_drift} =
             launch(fixture, {:error, :awx_preflight_static_drift})

    assert row_counts(fixture) == baseline
    refute_received {:awx_launch_job_dispatched, _, _}
  end

  test "an attested live preflight persists one immutable child and one launch command" do
    fixture = fixture()
    seed_dependencies(fixture)
    baseline = row_counts(fixture)

    assert {:ok, persisted} = launch(fixture, {:ok, fixture.attestation})
    assert persisted.dispatch_outcome == :dispatched

    assert_receive {:fresh_authorization_read, profile_id, profile_updated_at, permissions}
    assert_receive {:fresh_authorization_read, ^profile_id, ^profile_updated_at, ^permissions}
    refute_receive {:fresh_authorization_read, _, _, _}

    assert profile_id == fixture.authorization.profile_id
    assert profile_updated_at == fixture.authorization.profile_updated_at
    assert permissions == fixture.authorization.permissions

    assert_receive {:awx_launch_job_dispatched, command_id, request}
    assert request.template_id == 42
    assert request.launch_opts.inventory_id == 8
    assert request.launch_opts.host_limit == "web01.example.test"

    assert row_counts(fixture) == %{
             baseline
             | operations: baseline.operations + 1,
               executions: baseline.executions + 1,
               targets: baseline.targets + 1,
               secure_launch_attempts: baseline.secure_launch_attempts + 1,
               launch_commands: baseline.launch_commands + 1
           }

    {:ok, immutable_snapshot} = AwxLaunchPreflightAttestation.normalize(fixture.attestation)
    {:ok, immutable_snapshot_digest} = AwxLaunchPreflightAttestation.digest(immutable_snapshot)

    assert immutable_snapshot_row(fixture.actor.id) == %{
             evidence_id: fixture.attestation.evidence_id,
             command_id: command_id,
             operation_digest: immutable_snapshot_digest,
             execution_digest: immutable_snapshot_digest,
             operation_snapshot: immutable_snapshot,
             execution_snapshot: immutable_snapshot
           }
  end

  defp launch(fixture, preflight_result) do
    Process.put({IntegrationAdapter, :fixture}, fixture)
    Process.put({DatabaseActions, :fixture}, fixture)
    Process.put({__MODULE__, :preflight_result}, preflight_result)

    SecureChildLauncher.launch(
      %{
        actor: fixture.actor,
        membership_ids: [fixture.membership.id],
        playbook_id: fixture.playbook.id,
        job_template_id: 42,
        mode: :run,
        inputs: %{"version" => "1.2.3"},
        request_source: :integration_test
      },
      adapter: IntegrationAdapter,
      now: fixture.now,
      post_preflight_now: fixture.now,
      live_preflight: &live_preflight/2,
      edge_principal_resolver: &edge_principal/1
    )
  end

  defp live_preflight(_context, _opts) do
    case Process.get({__MODULE__, :preflight_result}) do
      nil -> raise "missing process-local preflight result"
      result -> result
    end
  end

  defp edge_principal("edge-agent-1"),
    do: {:ok, %{agent_id: "edge-agent-1", partition_id: "farm01"}}

  defp fixture do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    device_uid = "sr:preflight-persistence-#{System.unique_integer([:positive])}"

    binding =
      Fixtures.reviewed_binding(%{
        approval_expires_at: DateTime.add(now, 600, :second)
      })

    membership =
      Fixtures.membership(%{
        id: Ash.UUID.generate(),
        canonical_device_uid: device_uid
      })

    # The controller's secret ids must exist (foreign keys) AND must match what
    # the attestation was digested over: ControllerSecuritySnapshot covers them,
    # so seeding the row with different ids reads as controller drift.
    controller =
      Fixtures.controller(%{
        sync_credential_secret_id: CredentialIntegrationFixtures.secret_id!(),
        execution_credential_secret_id: CredentialIntegrationFixtures.secret_id!()
      })

    attestation = attestation(binding, membership, now, controller)

    %{
      now: now,
      actor: %{
        id: Ash.UUID.generate(),
        role: :operator,
        role_profile_id: Ash.UUID.generate(),
        status: :active,
        updated_at: now,
        tenant_id: "platform"
      },
      authorization: %{
        permissions: MapSet.new(["ansible.runs.launch"]),
        profile_id: Ash.UUID.generate(),
        profile_updated_at: now
      },
      playbook: %{
        id: Ash.UUID.generate(),
        source_type: :awx,
        controller_id: Fixtures.controller_id(),
        awx_job_template_id: 42,
        parse_status: :ok
      },
      controller: controller,
      binding: binding,
      membership: membership,
      device_uid: device_uid,
      attestation: attestation
    }
  end

  defp attestation(binding, membership, now, controller) do
    {:ok, request} =
      Fixtures.preflight_request(binding, [Fixtures.request_host(membership)])

    {:ok, request_digest} = AwxLaunchContract.request_digest(request)
    {:ok, target_digest} = AwxLaunchContract.target_snapshot_digest(request)
    {:ok, security_snapshot} = ControllerSecuritySnapshot.capture(controller)
    {:ok, security_digest} = ControllerSecuritySnapshot.digest(security_snapshot)

    Fixtures.attestation(%{
      evidence_id: Ash.UUIDv7.generate(),
      command_id: Ash.UUID.generate(),
      binding_id: binding.id,
      binding_version: binding.binding_version,
      approval_id: binding.approval_id,
      reviewed_launch_snapshot_digest: binding.reviewed_launch_snapshot_digest,
      preflight_request_digest: request_digest,
      target_snapshot_digest: target_digest,
      controller_security_snapshot_digest: security_digest,
      verified_at: now,
      expires_at: DateTime.add(now, 60, :second)
    })
  end

  defp seed_dependencies(fixture, opts \\ []) do
    seed_controller(fixture.controller)
    seed_device_and_membership(fixture)
    seed_binding(fixture.binding)

    if Keyword.get(opts, :evidence?, true) do
      seed_preflight_evidence(fixture.attestation)
    end
  end

  defp seed_controller(controller) do
    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_controllers
        (id, name, base_url, agent_id, credential_secret_id,
         sync_credential_secret_id, execution_credential_secret_id,
         callback_credential_secret_id, enabled, metadata)
      VALUES (($1::text)::uuid, $2, $3, $4, ($5::text)::uuid,
              ($5::text)::uuid, ($6::text)::uuid, NULL, true, '{}'::jsonb)
      """,
      [
        controller.id,
        controller.name,
        controller.base_url,
        controller.agent_id,
        controller.sync_credential_secret_id,
        controller.execution_credential_secret_id
      ]
    )
  end

  defp seed_device_and_membership(fixture) do
    SQL.query!(Repo, "INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [fixture.device_uid])

    membership = fixture.membership

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_awx_host_memberships
        (id, controller_id, inventory_id, awx_host_id, canonical_device_uid,
         source_generation, host_name, ansible_host, enabled, current,
         last_seen_at, link_disposition, source_fingerprint)
      VALUES (($1::text)::uuid, ($2::text)::uuid, $3, $4, $5, $6,
              $7, $8, true, true, (now() AT TIME ZONE 'utc'), 'approved', $9)
      """,
      [
        membership.id,
        membership.controller_id,
        membership.inventory_id,
        membership.awx_host_id,
        membership.canonical_device_uid,
        membership.source_generation,
        membership.host_name,
        membership.ansible_host,
        membership.source_fingerprint
      ]
    )
  end

  defp seed_binding(binding) do
    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_awx_template_bindings
        (id, controller_id, job_template_id, binding_version, current, approval_state,
         approval_id, approval_expires_at, inventory_policy, allowed_inventory_ids,
         project_id, scm_revision, content_sha256, project_update_on_launch,
         execution_environment_id, credentials, machine_credential_id,
         run_mode_supported, check_mode_supported, ask_inventory_on_launch,
         ask_limit_on_launch, ask_credential_on_launch, ask_job_type_on_launch,
         dispatch_markers_retained, inventory_groups_verified, inventory_group_names,
         input_schema, input_classifications, callback_actions,
         callback_credential_type_id, callback_credential_organization_id,
         callback_credential_injector_digest, callback_credential_slot,
         awx_created_by_id, reviewed_by_principal_type, reviewed_by_principal_id,
         reviewed_at, review_metadata, reviewed_launch_snapshot,
         reviewed_launch_snapshot_digest)
      VALUES
        (($1::text)::uuid, ($2::text)::uuid, $3, $4, true, 'approved',
         ($5::text)::uuid, $6, 'allow_list', ARRAY[$7]::bigint[],
         $8, $9, $10, false, $11,
         ARRAY['{"id":101,"kind":"ssh"}'::jsonb, '{"id":102,"kind":"vault"}'::jsonb],
         101, true, false, true, true, false, false, true, true, ARRAY['linux']::text[],
         '{"version":{"type":"text","required":true,"label":"Package version"}}'::jsonb,
         '{"version":"internal"}'::jsonb, ARRAY[]::text[], NULL, NULL, NULL, NULL,
         11, 'human', 'preflight-persistence-reviewer', (now() AT TIME ZONE 'utc'),
         jsonb_build_object('awx_snapshot_digest', $12::text), $13::jsonb, $12::text)
      """,
      [
        binding.id,
        binding.controller_id,
        binding.job_template_id,
        binding.binding_version,
        binding.approval_id,
        binding.approval_expires_at,
        hd(binding.allowed_inventory_ids),
        binding.project_id,
        binding.scm_revision,
        binding.content_sha256,
        binding.execution_environment_id,
        binding.reviewed_launch_snapshot_digest,
        Jason.encode!(binding.reviewed_launch_snapshot)
      ]
    )
  end

  defp seed_preflight_evidence(attestation) do
    SQL.query!(
      Repo,
      """
      INSERT INTO platform.automation_awx_launch_preflight_evidences
        (id, command_id, controller_id, dispatch_agent_id, dispatch_partition_id,
         binding_id, binding_version, approval_id, reviewed_launch_snapshot_digest,
         preflight_request_digest, target_snapshot_digest,
         controller_security_snapshot_digest, live_launch_snapshot_digest,
         command_result_digest, verified_at, expires_at)
      VALUES (($1::text)::uuid, ($2::text)::uuid, ($3::text)::uuid, $4, $5,
              ($6::text)::uuid, $7, ($8::text)::uuid, $9, $10, $11, $12, $13,
              $14, $15, $16)
      """,
      [
        attestation.evidence_id,
        attestation.command_id,
        attestation.controller_id,
        attestation.dispatch_agent_id,
        attestation.dispatch_partition_id,
        attestation.binding_id,
        attestation.binding_version,
        attestation.approval_id,
        attestation.reviewed_launch_snapshot_digest,
        attestation.preflight_request_digest,
        attestation.target_snapshot_digest,
        attestation.controller_security_snapshot_digest,
        attestation.live_launch_snapshot_digest,
        attestation.command_result_digest,
        attestation.verified_at,
        attestation.expires_at
      ]
    )

    assert {:ok, evidence} =
             AutomationAwxLaunchPreflightEvidence.get_by_id(attestation.evidence_id,
               actor: SystemActor.system(:live_awx_launch_preflight_persistence_db_test)
             )

    assert evidence.id == attestation.evidence_id
  end

  defp row_counts(fixture) do
    actor_id = fixture.actor.id

    %{
      operations:
        scalar(
          "SELECT count(*) FROM platform.ansible_automation_operations WHERE initiator_principal_id = $1",
          [actor_id]
        ),
      executions:
        scalar(
          """
          SELECT count(*)
          FROM platform.ansible_automation_executions e
          JOIN platform.ansible_automation_operations o ON o.id = e.operation_id
          WHERE o.initiator_principal_id = $1
          """,
          [actor_id]
        ),
      targets:
        scalar(
          """
          SELECT count(*)
          FROM platform.ansible_automation_execution_targets t
          JOIN platform.ansible_automation_executions e ON e.id = t.execution_id
          JOIN platform.ansible_automation_operations o ON o.id = e.operation_id
          WHERE o.initiator_principal_id = $1
          """,
          [actor_id]
        ),
      secure_launch_attempts:
        scalar(
          """
          SELECT count(*)
          FROM platform.automation_secure_execution_command_attempts a
          JOIN platform.ansible_automation_operations o ON o.id = a.operation_id
          WHERE o.initiator_principal_id = $1 AND a.command_type = 'awx.launch_job'
          """,
          [actor_id]
        ),
      launch_commands:
        scalar(
          """
          SELECT count(*)
          FROM platform.agent_commands c
          JOIN platform.automation_secure_execution_command_attempts a ON a.command_id = c.command_id
          JOIN platform.ansible_automation_operations o ON o.id = a.operation_id
          WHERE o.initiator_principal_id = $1 AND c.command_type = 'awx.launch_job'
          """,
          [actor_id]
        ),
      playbook_runs: scalar("SELECT count(*) FROM platform.ansible_playbook_runs", [])
    }
  end

  defp immutable_snapshot_row(actor_id) do
    [
      [
        evidence_id,
        operation_digest,
        operation_snapshot,
        execution_digest,
        execution_snapshot,
        command_id
      ]
    ] =
      SQL.query!(
        Repo,
        """
        SELECT o.preflight_evidence_id::text,
               o.immutable_launch_snapshot_digest,
               o.immutable_launch_snapshot,
               e.immutable_launch_snapshot_digest,
               e.immutable_launch_snapshot,
               a.command_id::text
        FROM platform.ansible_automation_operations o
        JOIN platform.ansible_automation_executions e ON e.operation_id = o.id
        JOIN platform.automation_secure_execution_command_attempts a ON a.operation_id = o.id
        WHERE o.initiator_principal_id = $1 AND a.command_type = 'awx.launch_job'
        """,
        [actor_id]
      ).rows

    %{
      evidence_id: evidence_id,
      command_id: command_id,
      operation_digest: operation_digest,
      execution_digest: execution_digest,
      operation_snapshot: operation_snapshot,
      execution_snapshot: execution_snapshot
    }
  end

  defp scalar(sql, params), do: SQL.query!(Repo, sql, params).rows |> hd() |> hd()
end
