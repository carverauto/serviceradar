defmodule ServiceRadar.Automation.Ansible.CallbackLaunchOrchestratorTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator
  alias ServiceRadar.Automation.Ansible.CallbackResponsePolicyProvider
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.UnavailableCallbackResponsePolicyProvider

  @preflight_evidence_id "018f3f56-1111-7222-8333-123456789a01"
  @preflight_command_id "018f3f56-1111-7222-8333-123456789a02"
  @controller_id "018f3f56-1111-7222-8333-123456789a03"
  @membership_id "018f3f56-1111-7222-8333-123456789a04"
  @binding_id "018f3f56-1111-7222-8333-123456789a05"
  @approval_id "018f3f56-1111-7222-8333-123456789a06"
  @grant_id "018f3f56-1111-7222-8333-123456789a09"
  @issued_at ~U[2026-07-13 02:00:00.000000Z]
  @envelope_key :binary.copy(<<91>>, 32)

  defmodule PolicyProvider do
    @moduledoc false
    @behaviour CallbackResponsePolicyProvider

    @impl true
    def snapshot(context) do
      send(Process.get({__MODULE__, :test_pid}), {:policy_context, context})

      targets =
        Enum.map(context.targets, fn target ->
          Map.merge(target, %{
            "ca_keys" => [
              %{
                "id" => "serviceradar-user-ca-2026",
                "public_key" =>
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZm test",
                "fingerprint" => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
              }
            ],
            "accounts" => [
              %{"name" => "mfreeman", "principals" => ["srp_v1_operator_01"]}
            ],
            "transaction" => %{},
            "retirement_proof" => nil
          })
        end)

      {:ok, %{targets: targets}}
    end
  end

  defmodule OverrideProvider do
    @moduledoc false
    @behaviour CallbackResponsePolicyProvider

    @impl true
    def snapshot(context) do
      {:ok, %{targets: context.targets, manifest_sha256: String.duplicate("f", 64)}}
    end
  end

  defmodule FakeActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator.Actions

    @impl true
    def persist_callback_plan(plan, callback) do
      notify({:persist_callback_plan, plan, callback})

      {:ok,
       %{
         operation: %{id: "operation-1"},
         execution: %{id: "018f3f56-1111-7222-8333-123456789a10"},
         targets: [%{id: "target-1"}],
         callback: %{
           grant: %{id: callback.grant_id},
           command_id: callback.command_id,
           envelope_ref: callback.allocation.reference,
           attempt: %{id: "attempt-1", command_id: callback.command_id}
         }
       }}
    end

    @impl true
    def mark_dispatching(persisted) do
      notify({:mark_dispatching, persisted})
      Process.get({__MODULE__, :mark_result}, :ok)
    end

    @impl true
    def dispatch_callback_credential(controller, attempt) do
      notify({:dispatch_callback_credential, controller, attempt})
      Process.get({__MODULE__, :dispatch_result}, {:ok, %{id: attempt.command_id}})
    end

    @impl true
    def revoke_callback_grant(grant_id, reason, lifecycle_opts) do
      notify({:revoke_callback_grant, grant_id, reason, lifecycle_opts})
      Process.get({__MODULE__, :revoke_result}, {:ok, %{id: grant_id, state: :revoked}})
    end

    @impl true
    def mark_callback_dispatch_failed(persisted, reason) do
      notify({:mark_callback_dispatch_failed, persisted, reason})
      :ok
    end

    defp notify(message), do: send(Process.get({__MODULE__, :test_pid}), message)
  end

  defmodule FakeEnvelopes do
    @moduledoc false

    def allocate(_opts) do
      send(Process.get({__MODULE__, :test_pid}), :callback_envelope_allocate)
      {:error, :callback_envelope_allocation_should_not_run}
    end
  end

  setup do
    previous_origin = Application.get_env(:serviceradar_core, :automation_callback_origin)

    Application.put_env(
      :serviceradar_core,
      :automation_callback_origin,
      "https://demo.example.com"
    )

    Process.put({PolicyProvider, :test_pid}, self())
    Process.put({FakeActions, :test_pid}, self())
    Process.put({FakeEnvelopes, :test_pid}, self())
    Process.delete({FakeActions, :mark_result})
    Process.delete({FakeActions, :dispatch_result})
    Process.delete({FakeActions, :revoke_result})

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

  test "persists the full callback context before dispatching only credential creation" do
    assert {:ok, result} = launch()

    assert_receive {:policy_context, policy_context}
    assert policy_context.action == "remote_access.ssh_ca.bundle.read"
    assert policy_context.targets == provider_targets()

    assert_receive {:persist_callback_plan, persisted_plan, callback}
    assert persisted_plan.execution.callback_reference == @grant_id

    assert persisted_plan.execution.metadata["callback_credential_command_id"] ==
             callback.command_id

    assert callback.grant_attrs.policy_snapshot["phase"] == nil
    assert callback.grant_attrs.response_snapshot["phase"] == "preflight"
    assert callback.callback_origin == "https://demo.example.com"
    assert callback.dispatch_agent_id == "agent-farm01"
    assert callback.dispatch_partition_id == "farm01"
    assert callback.grant_attrs.dispatch_partition_id == "farm01"

    assert_receive {:mark_dispatching, _persisted}

    assert_receive {:dispatch_callback_credential, controller, attempt}
    assert controller.agent_id == "agent-farm01"
    assert attempt.command_id == callback.command_id

    assert result.callback == %{
             grant_id: @grant_id,
             command_id: callback.command_id,
             state: :pending,
             dispatch: :accepted
           }

    public = inspect(result)
    refute public =~ "srle1_"
    refute public =~ "envelope_ref"
    refute public =~ "bearer"
    refute public =~ "idempotency"
  end

  test "fails closed before persistence without a complete approved policy provider" do
    assert {:error, :callback_response_policy_unavailable} =
             launch(response_policy_provider: UnavailableCallbackResponsePolicyProvider)

    refute_receive {:persist_callback_plan, _, _}

    assert {:error, :invalid_callback_response_policy_snapshot} =
             launch(response_policy_provider: OverrideProvider)

    refute_receive {:persist_callback_plan, _, _}
  end

  test "fails closed without a server-owned callback origin" do
    Application.delete_env(:serviceradar_core, :automation_callback_origin)

    assert {:error, :automation_callback_origin_unavailable} = launch()
    refute_receive {:persist_callback_plan, _, _}
  end

  test "fails closed when control-session evidence does not match the controller agent" do
    resolver = fn _agent_id ->
      {:ok, %{agent_id: "agent-tonka01", partition_id: "tonka01"}}
    end

    assert {:error, :authenticated_edge_principal_mismatch} =
             launch(edge_principal_resolver: resolver)

    refute_receive {:persist_callback_plan, _, _}
  end

  test "requires evidence-backed immutable preflight before callback envelope allocation" do
    legacy_plan = remove_preflight_attestation(plan())

    assert {:error, :awx_preflight_attestation_required} =
             launch(plan: legacy_plan, launch_envelopes: FakeEnvelopes)

    refute_receive :callback_envelope_allocate
    refute_receive {:persist_callback_plan, _, _}
  end

  test "ignores callback destinations supplied by launch data" do
    injected_plan =
      plan()
      |> put_in([:callback_contract, :callback_origin], "https://attacker.invalid")
      |> put_in([:snapshot, "binding", "callback_origin"], "https://attacker.invalid")
      |> put_in([:command_context, "callback_origin"], "https://attacker.invalid")

    assert {:ok, _result} = launch(plan: injected_plan)
    assert_receive {:persist_callback_plan, _, callback}
    assert callback.callback_origin == "https://demo.example.com"
  end

  test "loads a configured provider module before checking its callback" do
    provider = UnavailableCallbackResponsePolicyProvider
    assert :code.which(provider) != :non_existing
    :code.purge(provider)
    :code.delete(provider)
    refute Code.loaded?(provider)

    assert {:error, :callback_response_policy_unavailable} =
             launch(response_policy_provider: provider)

    assert Code.loaded?(provider)
  end

  test "requires the complete fresh action permission ceiling" do
    plan =
      update_in(plan(), [:operation, :authority_ceiling, "permissions"], fn _ ->
        ["ansible.runs.launch"]
      end)

    assert {:error, :issuance_permission_ceiling_exceeded} = launch(plan: plan)
    refute_receive {:policy_context, _}
    refute_receive {:persist_callback_plan, _, _}
  end

  test "revokes authority before marking a synchronous dispatch failure" do
    Process.put({FakeActions, :dispatch_result}, {:error, {:agent_offline, "secret detail"}})

    assert {:error, {:dispatch_failed, :callback_credential_dispatch_failed}} = launch()

    assert_receive {:persist_callback_plan, _, callback}
    assert_receive {:mark_dispatching, _}
    assert_receive {:dispatch_callback_credential, _, _}

    assert_receive {:revoke_callback_grant, @grant_id, :callback_credential_dispatch_failed,
                    _lifecycle_opts}

    assert_receive {:mark_callback_dispatch_failed, _persisted,
                    :callback_credential_dispatch_failed}

    refute inspect(callback) =~ "secret detail"
  end

  test "accepts a bounded service-principal authority but never a system principal" do
    service_plan =
      plan()
      |> put_in([:operation, :initiator_principal_type], :service_principal)
      |> put_in([:operation, :initiator_principal_id], "oauth-client-7")
      |> put_in([:operation, :service_principal_owner_id], "owner-7")
      |> put_in([:snapshot, "actor", "principal_type"], :service_principal)
      |> put_in([:snapshot, "actor", "principal_id"], "oauth-client-7")
      |> put_in([:snapshot, "actor", "service_principal_owner_id"], "owner-7")

    assert {:ok, _result} = launch(plan: service_plan)

    system_plan =
      service_plan
      |> put_in([:operation, :initiator_principal_type], :human)
      |> put_in([:operation, :initiator_principal_id], "system:automation")

    assert {:error, :system_actor_has_no_authority} = launch(plan: system_plan)
  end

  defp launch(opts \\ []) do
    plan = Keyword.get(opts, :plan, plan())
    controller = Keyword.get(opts, :controller, controller())

    CallbackLaunchOrchestrator.launch(
      plan,
      controller,
      Keyword.merge(
        [
          actions: FakeActions,
          edge_principal_resolver: fn agent_id ->
            {:ok, %{agent_id: agent_id, partition_id: "farm01"}}
          end,
          response_policy_provider: PolicyProvider,
          lifecycle_opts: [],
          envelope_opts: [encryption_key: @envelope_key],
          grant_id: @grant_id,
          now: @issued_at,
          preflight_evidence_reader: &preflight_evidence_reader/1
        ],
        opts |> Keyword.delete(:plan) |> Keyword.delete(:controller)
      )
    )
  end

  defp plan do
    actor = %{
      "principal_type" => :human,
      "principal_id" => "user-7",
      "tenant_id" => "platform",
      "authorization_version" => String.duplicate("1", 64),
      "service_principal_owner_id" => nil
    }

    approval = %{
      "binding_id" => @binding_id,
      "binding_version" => 3,
      "approval_id" => @approval_id,
      "approval_expires_at" => "2026-07-13T03:00:00.000000Z",
      "reviewed_by_principal_type" => "human",
      "reviewed_by_principal_id" => "reviewer-1",
      "reviewed_at" => "2026-07-13T01:00:00.000000Z",
      "review_metadata" => %{},
      "issued_at" => "2026-07-13T02:00:00.000000Z"
    }

    attestation_attrs = attestation_attrs()

    %{
      callback_contract: %{
        action: "remote_access.ssh_ca.bundle.read",
        action_version: "1.0.0",
        manifest_sha256: String.duplicate("a", 64),
        phase: "preflight",
        operation: "enroll",
        state: "present",
        policy_version: "ssh-policy-v1",
        ttl_seconds: 120
      },
      operation:
        Map.merge(
          %{
            tenant_id: "platform",
            initiator_principal_type: :human,
            initiator_principal_id: "user-7",
            service_principal_owner_id: nil,
            authority_ceiling: %{
              "permissions" => ["ansible.runs.launch", "devices.remote_access.ssh.ca_bundle.read"],
              "target_membership_ids" => [@membership_id]
            },
            approval_snapshot: approval,
            target_digest: String.duplicate("d", 64),
            callback_actions: ["remote_access.ssh_ca.bundle.read"]
          },
          attestation_attrs
        ),
      execution:
        Map.merge(
          %{
            controller_id: @controller_id,
            inventory_id: 34,
            job_template_id: 42,
            project_id: 3,
            scm_revision: String.duplicate("a", 40),
            content_sha256: String.duplicate("b", 64),
            execution_environment_id: 4,
            machine_credential_id: 5,
            credential_snapshot: %{"credential_ids" => [5]},
            host_limit: "farm01-pve01",
            snapshot_digest: String.duplicate("e", 64),
            metadata: %{"awx_created_by_id" => 11}
          },
          attestation_attrs
        ),
      targets: [
        %{
          membership_id: @membership_id,
          controller_id: @controller_id,
          inventory_id: 34,
          awx_host_id: 7,
          canonical_device_uid: "sr:device-7",
          membership_generation: 3,
          source_fingerprint: "sha256:" <> String.duplicate("c", 64),
          host_name: "farm01-pve01",
          ansible_host: "192.168.2.22"
        }
      ],
      snapshot: %{
        "actor" => actor,
        "binding" => %{
          "ask_credential_on_launch" => true,
          "callback_credential_type_id" => 6,
          "callback_credential_organization_id" => 2,
          "callback_credential_injector_digest" => String.duplicate("c", 64),
          "callback_credential_slot" => "ssh_ca_callback"
        }
      },
      command_context: %{"dispatch_id" => "dispatch-1"}
    }
  end

  defp remove_preflight_attestation(plan) do
    fields = [
      :preflight_evidence_id,
      :immutable_launch_snapshot,
      :immutable_launch_snapshot_digest
    ]

    plan
    |> update_in([:operation], &Map.drop(&1, fields))
    |> update_in([:execution], &Map.drop(&1, fields))
  end

  defp attestation_attrs do
    assert {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation())
    attrs
  end

  defp attestation do
    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller())

    {:ok, controller_security_snapshot_digest} =
      ControllerSecuritySnapshot.digest(controller_snapshot)

    %{
      schema: AwxLaunchPreflightAttestation.schema(),
      evidence_id: @preflight_evidence_id,
      command_id: @preflight_command_id,
      controller_id: @controller_id,
      dispatch_agent_id: "agent-farm01",
      dispatch_partition_id: "farm01",
      binding_id: @binding_id,
      binding_version: 3,
      approval_id: @approval_id,
      reviewed_launch_snapshot_digest: String.duplicate("a", 64),
      preflight_request_digest: String.duplicate("b", 64),
      target_snapshot_digest: String.duplicate("c", 64),
      controller_security_snapshot_digest: controller_security_snapshot_digest,
      live_launch_snapshot_digest: String.duplicate("d", 64),
      command_result_digest: String.duplicate("e", 64),
      verified_at: @issued_at,
      expires_at: DateTime.add(@issued_at, 120, :second)
    }
  end

  defp preflight_evidence_reader(@preflight_evidence_id), do: {:ok, preflight_evidence()}
  defp preflight_evidence_reader(_id), do: {:error, :not_found}

  defp preflight_evidence do
    attestation = attestation()

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

  defp controller do
    %{
      id: @controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: "agent-farm01",
      enabled: true,
      sync_credential_secret_id: "018f3f56-1111-7222-8333-123456789a07",
      execution_credential_secret_id: "018f3f56-1111-7222-8333-123456789a08",
      callback_credential_secret_id: nil,
      metadata: %{}
    }
  end

  defp provider_targets do
    [
      %{
        "inventory_hostname" => "farm01-pve01",
        "inventory_address" => "192.168.2.22",
        "target_identity" => %{
          "controller_id" => @controller_id,
          "inventory_id" => 34,
          "awx_host_id" => 7,
          "canonical_device_uid" => "sr:device-7"
        }
      }
    ]
  end
end
