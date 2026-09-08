defmodule ServiceRadar.Automation.Ansible.CallbackLaunchOrchestratorDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator.AshActions
  alias ServiceRadar.Automation.CallbackGrants.AshStore, as: GrantStore
  alias ServiceRadar.Automation.CallbackGrants.Authority
  alias ServiceRadar.Automation.LaunchEnvelopes
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @encryption_key :binary.copy(<<91>>, 32)

  defmodule CurrentGrantAuthorizer do
    @moduledoc false
    @behaviour ServiceRadar.Automation.CallbackGrants.Authorizer

    @impl true
    def current_authority(:issue, grant, _context) do
      {:ok,
       %{
         enabled: true,
         principal_type: grant.principal_type,
         principal_id: grant.principal_id,
         principal_owner_id: grant.principal_owner_id,
         tenant_id: grant.tenant_id,
         permissions: grant.issuance_ceiling["permissions"],
         actions: grant.issuance_ceiling["actions"],
         target_keys: grant.target_keys,
         approval_digest: grant.approval_digest,
         policy_digest: grant.policy_digest,
         scope_digest: grant.scope_digest,
         run_state: :authorized,
         job_state: :pending,
         job_id: nil
       }}
    end
  end

  defmodule FailingEnvelopeStore do
    @moduledoc false
    @behaviour ServiceRadar.Automation.LaunchEnvelopes.Store

    @impl true
    def transaction(fun, _context), do: fun.()

    @impl true
    def create_sealed(_attrs, _context), do: {:error, :forced_envelope_failure}

    @impl true
    def consume(_verifier, _request, _now, _cipher, _decrypt, _context),
      do: {:error, :launch_envelope_denied}
  end

  setup_all do
    TestSupport.start_core!()
    previous_origin = Application.get_env(:serviceradar_core, :automation_callback_origin)

    Application.put_env(
      :serviceradar_core,
      :automation_callback_origin,
      "https://demo.example.com"
    )

    on_exit(fn ->
      if previous_origin,
        do:
          Application.put_env(
            :serviceradar_core,
            :automation_callback_origin,
            previous_origin
          ),
        else: Application.delete_env(:serviceradar_core, :automation_callback_origin)
    end)

    :ok
  end

  test "outer transaction commits the command attempt with the launch plan and rolls every set back" do
    success = fixture()
    insert_dependencies(success)

    assert {:ok, persisted} = AshActions.persist_callback_plan(success.plan, success.callback)
    assert persisted.execution.callback_reference == success.callback.grant_id
    assert persisted.callback.command_id == success.callback.command_id

    assert {:ok, attempt} =
             Attempt.get_by_command_id(success.callback.command_id,
               actor: SystemActor.system(:callback_attempt_claim_db_test)
             )

    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

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
            actor: SystemActor.system(:callback_attempt_claim_db_test)
          )
        end,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(claims, &match?({:ok, %Attempt{state: :dispatching}}, &1)) == 1
    assert Enum.count(claims, &match?({:error, _reason}, &1)) == 1

    create_callback_command(success)

    assert {:ok, material} = resolve(success)
    assert material.callback_grant_id == success.callback.grant_id
    assert material.callback_allowed_origin == "https://demo.example.com"

    assert material.callback_url ==
             "https://demo.example.com/api/v1/automation/callback-grants/#{success.callback.grant_id}/actions/remote_access.ssh_ca.bundle.read"

    assert material.manifest_sha256 == String.duplicate("f", 64)
    assert material.scm_revision == String.duplicate("a", 40)
    assert material.content_sha256 == String.duplicate("b", 64)
    assert material.callback_phase == "preflight"
    assert material.callback_operation == "enroll"
    assert material.callback_state == "present"
    assert material.callback_credential_type_id == 6
    assert material.callback_credential_organization_id == 2
    assert material.callback_credential_injector_sha256 == String.duplicate("c", 64)
    assert envelope_state(success) == "resolved"
    assert resolution_audit_count(success) == 1
    assert {:error, :launch_envelope_denied} = resolve(success)

    assert row_counts(success) == %{
             operations: 1,
             executions: 1,
             targets: 1,
             grants: 1,
             envelopes: 1,
             attempts: 1
           }

    failed = fixture(store: FailingEnvelopeStore)
    insert_dependencies(failed)

    assert {:error, :forced_envelope_failure} =
             AshActions.persist_callback_plan(failed.plan, failed.callback)

    assert row_counts(failed) == %{
             operations: 0,
             executions: 0,
             targets: 0,
             grants: 0,
             envelopes: 0,
             attempts: 0
           }
  end

  test "decrypt failure keeps a real Ash envelope sealed and concurrent resolution wins once" do
    fixture = fixture()
    insert_dependencies(fixture)

    assert {:ok, _persisted} = AshActions.persist_callback_plan(fixture.plan, fixture.callback)
    create_callback_command(fixture)
    original_ciphertext = envelope_ciphertext(fixture)
    corrupt_envelope_ciphertext(fixture, original_ciphertext)

    assert {:error, :launch_envelope_decrypt_failed} =
             resolve(fixture)

    assert envelope_state(fixture) == "sealed"
    assert resolution_audit_count(fixture) == 0
    set_envelope_ciphertext(fixture, original_ciphertext)

    exact = fn -> resolve(fixture) end

    results = Enum.map([Task.async(exact), Task.async(exact)], &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, %{callback_grant_id: _}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :launch_envelope_denied}, &1)) == 1
    assert envelope_state(fixture) == "resolved"
    assert resolution_audit_count(fixture) == 1
  end

  defp fixture(opts \\ []) do
    suffix = System.unique_integer([:positive])
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    ids = %{
      controller: Ash.UUID.generate(),
      membership: Ash.UUID.generate(),
      binding: Ash.UUID.generate(),
      approval: Ash.UUID.generate(),
      grant: Ash.UUIDv7.generate(),
      command: Ash.UUID.generate(),
      dispatch: Ash.UUID.generate()
    }

    actor_id = "callback-outer-#{suffix}"
    device_uid = "sr:callback-outer-#{suffix}"
    source_fingerprint = "sha256:" <> String.duplicate("c", 64)
    target_digest = String.duplicate("d", 64)
    snapshot_digest = String.duplicate("e", 64)

    approval = %{
      "binding_id" => ids.binding,
      "binding_version" => 1,
      "approval_id" => ids.approval,
      "approval_expires_at" => DateTime.to_iso8601(DateTime.add(now, 3_600)),
      "reviewed_by_principal_type" => "human",
      "reviewed_by_principal_id" => "callback-reviewer",
      "reviewed_at" => DateTime.to_iso8601(DateTime.add(now, -60)),
      "review_metadata" => %{},
      "issued_at" => DateTime.to_iso8601(now)
    }

    scope_target = %{
      "membership_id" => ids.membership,
      "controller_id" => ids.controller,
      "inventory_id" => 34,
      "awx_host_id" => 7,
      "canonical_device_uid" => device_uid,
      "host_name" => "farm01-pve01",
      "ansible_host" => "192.168.2.22",
      "membership_generation" => 3,
      "source_fingerprint" => source_fingerprint
    }

    response_target = %{
      "inventory_hostname" => "farm01-pve01",
      "inventory_address" => "192.168.2.22",
      "target_identity" =>
        Map.drop(scope_target, [
          "membership_id",
          "host_name",
          "ansible_host",
          "membership_generation",
          "source_fingerprint"
        ]),
      "ca_keys" => [
        %{
          "id" => "serviceradar-user-ca-2026",
          "public_key" =>
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZm test",
          "fingerprint" => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        }
      ],
      "accounts" => [
        %{"name" => "mfreeman", "principals" => ["srp_v1_AAAAAAAAAAAAAAAAAAAA"]}
      ],
      "transaction" => %{},
      "retirement_proof" => nil
    }

    response = %{
      "manifest_sha256" => String.duplicate("f", 64),
      "phase" => "preflight",
      "operation" => "enroll",
      "state" => "present",
      "targets" => [response_target]
    }

    scope = %{
      "controller_id" => ids.controller,
      "inventory_id" => 34,
      "job_template_id" => 42,
      "project_id" => 3,
      "scm_revision" => String.duplicate("a", 40),
      "content_sha256" => String.duplicate("b", 64),
      "execution_environment_id" => 4,
      "machine_credential_id" => 5,
      "credential_ids" => [5],
      "ask_credential_on_launch" => true,
      "callback_credential_type_id" => 6,
      "callback_credential_organization_id" => 2,
      "callback_credential_injector_digest" => String.duplicate("c", 64),
      "host_limit" => "farm01-pve01",
      "target_count" => 1,
      "target_digest" => target_digest,
      "snapshot_digest" => snapshot_digest,
      "targets" => [scope_target],
      "binding_id" => ids.binding,
      "awx_created_by_id" => 11
    }

    policy = %{
      "schema" => "serviceradar.automation_callback_policy/v1",
      "action" => "remote_access.ssh_ca.bundle.read",
      "binding_id" => ids.binding,
      "binding_version" => 1,
      "version" => "ssh-policy-v1",
      "approval_id" => ids.approval,
      "approval_state" => "approved",
      "approval_expires_at" => approval["approval_expires_at"]
    }

    {:ok, allocation} =
      LaunchEnvelopes.allocate(
        encryption_key: @encryption_key,
        command_id: ids.command,
        now: now
      )

    {:ok, target_keys} = Authority.target_keys(response["targets"])

    plan = %{
      operation: %{
        tenant_id: "platform",
        action: "ansible.playbook.run",
        mutating: true,
        check_mode: false,
        initiator_principal_type: :human,
        initiator_principal_id: actor_id,
        service_principal_owner_id: nil,
        authorization_version: String.duplicate("1", 64),
        authority_ceiling: %{
          "permissions" => [
            "ansible.runs.launch",
            "devices.remote_access.ssh.ca_bundle.read"
          ],
          "target_membership_ids" => [ids.membership]
        },
        approval_snapshot: approval,
        request_source: "db_test",
        declared_inputs: %{},
        input_classifications: %{},
        input_digest: String.duplicate("2", 64),
        target_digest: target_digest,
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        run_budget: %{},
        metadata: %{"fixture" => actor_id}
      },
      execution: %{
        controller_id: ids.controller,
        inventory_id: 34,
        job_template_id: 42,
        project_id: 3,
        scm_revision: String.duplicate("a", 40),
        content_sha256: String.duplicate("b", 64),
        execution_environment_id: 4,
        machine_credential_id: 5,
        credential_snapshot: %{
          "credential_ids" => [5],
          "dynamic_callback_slot" => "ssh_ca_callback"
        },
        check_mode: false,
        host_limit: "farm01-pve01",
        dispatch_id: ids.dispatch,
        snapshot_digest: snapshot_digest,
        callback_reference: ids.grant,
        metadata: %{
          "awx_created_by_id" => 11,
          "target_digest" => target_digest,
          "callback_credential_command_id" => ids.command
        }
      },
      targets: [
        %{
          membership_id: ids.membership,
          canonical_device_uid: device_uid,
          controller_id: ids.controller,
          inventory_id: 34,
          awx_host_id: 7,
          membership_generation: 3,
          source_fingerprint: source_fingerprint,
          host_name: "farm01-pve01",
          ansible_host: "192.168.2.22",
          snapshot_digest: String.duplicate("3", 64)
        }
      ]
    }

    lifecycle_opts = [
      store: GrantStore,
      authorizer: CurrentGrantAuthorizer,
      verifier_config: [active_key_id: "callback-v1", keys: %{"callback-v1" => @encryption_key}],
      now: now
    ]

    callback = %{
      grant_id: ids.grant,
      command_id: ids.command,
      allocation: allocation,
      expires_at: DateTime.add(now, 120),
      callback_origin: "https://demo.example.com",
      lifecycle_opts: lifecycle_opts,
      envelope_opts: [
        allocation: allocation,
        encryption_key: @encryption_key,
        store: Keyword.get(opts, :store, ServiceRadar.Automation.LaunchEnvelopes.AshStore)
      ],
      dispatch_agent_id: "agent-gateway-demo",
      dispatch_partition_id: "farm01",
      grant_attrs: %{
        id: ids.grant,
        tenant_id: "platform",
        action: "remote_access.ssh_ca.bundle.read",
        audience: "serviceradar.awx.callback/v1",
        budget: 1,
        expires_at: DateTime.add(now, 120),
        actor_snapshot: %{
          principal_type: :human,
          principal_id: actor_id,
          owner_id: nil,
          tenant_id: "platform",
          authorization_version: String.duplicate("1", 64)
        },
        approval_snapshot: approval,
        policy_snapshot: policy,
        issuance_ceiling: %{
          "permissions" => [
            "ansible.runs.launch",
            "devices.remote_access.ssh.ca_bundle.read"
          ],
          "actions" => ["remote_access.ssh_ca.bundle.read"],
          "target_keys" => target_keys,
          "tenant_id" => "platform",
          "principal_type" => :human,
          "principal_id" => actor_id,
          "max_ttl_seconds" => 120,
          "success_budget" => 1
        },
        awx_scope_snapshot: scope,
        response_snapshot: response,
        dispatch_agent_id: "agent-gateway-demo",
        dispatch_partition_id: "farm01"
      }
    }

    %{
      ids: ids,
      actor_id: actor_id,
      device_uid: device_uid,
      source_fingerprint: source_fingerprint,
      plan: plan,
      callback: callback
    }
  end

  defp insert_dependencies(fixture) do
    SQL.query!(Repo, "INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [fixture.device_uid])

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_controllers
        (id, name, base_url, agent_id, credential_secret_id)
      VALUES (($1::text)::uuid, $2, 'https://awx.test.invalid', 'agent-gateway-demo',
              ($3::text)::uuid)
      """,
      [
        fixture.ids.controller,
        "callback-outer-#{fixture.actor_id}",
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
      [
        fixture.ids.membership,
        fixture.ids.controller,
        fixture.device_uid,
        fixture.source_fingerprint
      ]
    )

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
         dispatch_markers_retained,
         inventory_groups_verified, inventory_group_names, input_schema,
         input_classifications, callback_actions, callback_credential_type_id,
         callback_credential_organization_id, callback_credential_injector_digest,
         callback_credential_slot, awx_created_by_id, reviewed_by_principal_type,
         reviewed_by_principal_id, reviewed_at, review_metadata)
      VALUES
        (($1::text)::uuid, ($2::text)::uuid, 42, 1, true, 'approved', ($3::text)::uuid,
         (now() AT TIME ZONE 'utc') + INTERVAL '1 day', 'fixed', ARRAY[34]::bigint[],
         3, $4, $5, false, 4, ARRAY['{"id":5,"kind":"ssh"}'::jsonb], 5,
         true, false, false, true, true, false, true, true, ARRAY['linux']::text[],
         '{}'::jsonb, '{}'::jsonb,
         ARRAY['remote_access.ssh_ca.bundle.read']::text[], 6, 2, $6, 'ssh_ca_callback', 11,
         'human', 'callback-reviewer', (now() AT TIME ZONE 'utc'), '{}'::jsonb)
      """,
      [
        fixture.ids.binding,
        fixture.ids.controller,
        fixture.ids.approval,
        String.duplicate("a", 40),
        String.duplicate("b", 64),
        String.duplicate("c", 64)
      ]
    )
  end

  defp row_counts(fixture) do
    scalar = fn sql, params -> SQL.query!(Repo, sql, params).rows |> hd() |> hd() end

    %{
      operations:
        scalar.(
          "SELECT count(*) FROM platform.ansible_automation_operations WHERE initiator_principal_id = $1",
          [fixture.actor_id]
        ),
      executions:
        scalar.(
          """
          SELECT count(*)
          FROM platform.ansible_automation_executions e
          JOIN platform.ansible_automation_operations o ON o.id = e.operation_id
          WHERE o.initiator_principal_id = $1
          """,
          [fixture.actor_id]
        ),
      targets:
        scalar.(
          """
          SELECT count(*)
          FROM platform.ansible_automation_execution_targets t
          JOIN platform.ansible_automation_executions e ON e.id = t.execution_id
          JOIN platform.ansible_automation_operations o ON o.id = e.operation_id
          WHERE o.initiator_principal_id = $1
          """,
          [fixture.actor_id]
        ),
      grants:
        scalar.(
          "SELECT count(*) FROM platform.automation_callback_grants WHERE id = ($1::text)::uuid",
          [fixture.ids.grant]
        ),
      envelopes:
        scalar.(
          "SELECT count(*) FROM platform.automation_launch_envelopes WHERE command_id = ($1::text)::uuid",
          [fixture.ids.command]
        ),
      attempts:
        scalar.(
          "SELECT count(*) FROM platform.automation_callback_command_attempts WHERE command_id = ($1::text)::uuid",
          [fixture.ids.command]
        )
    }
  end

  defp create_callback_command(fixture) do
    actor = SystemActor.system(:callback_launch_orchestrator_db_test)

    assert {:ok, %AgentCommand{}} =
             AgentCommand.create_command_with_id(
               %{
                 command_id: fixture.ids.command,
                 command_type: "awx.create_callback_credential",
                 agent_id: "agent-gateway-demo",
                 partition_id: "farm01",
                 payload: %{"launch_envelope_ref" => fixture.callback.allocation.reference},
                 context: %{"test" => "callback_launch_orchestrator_db"},
                 ttl_seconds: 300,
                 expires_at: DateTime.add(fixture.callback.allocation.issued_at, 300, :second),
                 requested_by: "system:callback_launch_orchestrator_db_test"
               },
               actor: actor
             )
  end

  defp resolve(fixture, opts \\ []) do
    LaunchEnvelopes.resolve(
      fixture.callback.allocation.reference,
      %{
        agent_id: "agent-gateway-demo",
        partition_id: "farm01",
        command_id: fixture.ids.command
      },
      Keyword.merge(
        [
          encryption_key: @encryption_key,
          now: DateTime.add(fixture.callback.allocation.issued_at, 30, :second)
        ],
        opts
      )
    )
  end

  defp envelope_state(fixture) do
    then(
      SQL.query!(
        Repo,
        "SELECT state FROM platform.automation_launch_envelopes WHERE command_id = ($1::text)::uuid",
        [fixture.ids.command]
      ).rows,
      fn [[state]] -> state end
    )
  end

  defp resolution_audit_count(fixture) do
    then(
      SQL.query!(
        Repo,
        """
        SELECT count(*)
        FROM platform.automation_callback_audit_events
        WHERE grant_id = ($1::text)::uuid AND event_type = 'envelope_resolved'
        """,
        [fixture.ids.grant]
      ).rows,
      fn [[count]] -> count end
    )
  end

  defp envelope_ciphertext(fixture) do
    then(
      SQL.query!(
        Repo,
        "SELECT ciphertext FROM platform.automation_launch_envelopes WHERE command_id = ($1::text)::uuid",
        [fixture.ids.command]
      ).rows,
      fn [[ciphertext]] -> ciphertext end
    )
  end

  defp corrupt_envelope_ciphertext(fixture, <<first, rest::binary>>) do
    set_envelope_ciphertext(fixture, <<Bitwise.bxor(first, 1), rest::binary>>)
  end

  defp set_envelope_ciphertext(fixture, ciphertext) do
    SQL.query!(
      Repo,
      "UPDATE platform.automation_launch_envelopes SET ciphertext = $2 WHERE command_id = ($1::text)::uuid",
      [fixture.ids.command, ciphertext]
    )
  end
end
