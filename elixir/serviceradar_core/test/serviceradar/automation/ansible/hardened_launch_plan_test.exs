defmodule ServiceRadar.Automation.Ansible.HardenedLaunchPlanTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.HardenedLaunchPlan
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var

  @controller_id "018f3f56-1111-7222-8333-123456789abc"
  @membership_id "018f3f56-1111-7222-8333-123456789abd"
  @source_fingerprint "sha256:" <> String.duplicate("c", 64)

  defp actor(overrides \\ %{}) do
    Map.merge(
      %{
        principal_type: :human,
        principal_id: "018f3f56-1111-7222-8333-123456789abe",
        tenant_id: "platform",
        authorization_version: "role-v7",
        authority_ceiling: %{
          "permissions" => ["ansible.runs.launch"],
          "target_membership_ids" => [@membership_id]
        },
        approval_snapshot: %{}
      },
      overrides
    )
  end

  defp membership(overrides \\ %{}) do
    Map.merge(
      %{
        id: @membership_id,
        controller_id: @controller_id,
        inventory_id: 34,
        awx_host_id: 7,
        canonical_device_uid: "sr:device-7",
        source_generation: 3,
        source_fingerprint: @source_fingerprint,
        host_name: "farm01-pve01",
        ansible_host: "192.168.2.22",
        current: true,
        enabled: true,
        link_disposition: :approved
      },
      overrides
    )
  end

  defp reviewed_binding(overrides \\ %{}) do
    Map.merge(
      %{
        approval_state: "approved",
        inventory_id: 34,
        inventory_group_names: ["linux"],
        ask_limit_on_launch: true,
        dispatch_markers_retained: true,
        dispatch_marker_contract: DispatchMarkerContract.contract(),
        project_update_on_launch: false,
        project_id: 3,
        scm_revision: String.duplicate("a", 40),
        content_sha256: String.duplicate("b", 64),
        execution_environment_id: 4,
        credential_ids: [5],
        credentials: [%{"id" => 5, "kind" => "ssh"}],
        machine_credential_id: 5,
        job_type: "run",
        awx_created_by_id: 11,
        input_classifications: %{"version" => "internal"},
        callback_actions: []
      },
      overrides
    )
  end

  defp intent(overrides \\ %{}) do
    Map.merge(
      %{
        action: "ansible.playbook.run",
        request_source: "interactive",
        mode: :run,
        mutating: true,
        controller_id: @controller_id,
        controller_security_snapshot: controller_security_snapshot(),
        job_template_id: 42,
        actor_snapshot: actor(),
        memberships: [membership()],
        held_device_uids: [],
        binding: reviewed_binding(),
        variable_schema: [%Var{name: "version", type: :text, required: true}],
        inputs: %{"version" => "1.2.3"},
        dispatch_id: "018f3f56-1111-7222-8333-123456789abf"
      },
      overrides
    )
  end

  defp controller_security_snapshot do
    %{
      "schema" => "serviceradar.awx_controller_security_snapshot.v1",
      "controller_id" => @controller_id,
      "name" => "farm01-awx",
      "base_url" => "https://awx.example.test:443",
      "agent_id" => "edge-agent-1",
      "enabled" => true,
      "insecure_skip_verify" => false,
      "credential_refs" => %{
        "sync" => "018f3f56-1111-7222-8333-123456789ac1",
        "execution" => "018f3f56-1111-7222-8333-123456789ac2",
        "callback" => nil
      }
    }
  end

  test "builds a complete secret-free local plan before dispatch" do
    assert {:ok, plan} = HardenedLaunchPlan.build(intent())

    assert plan.operation.initiator_principal_type == :human
    assert plan.operation.declared_inputs == %{"version" => "1.2.3"}
    assert plan.operation.target_digest =~ ~r/\A[0-9a-f]{64}\z/

    assert plan.execution.inventory_id == 34
    assert plan.execution.job_template_id == 42
    assert plan.execution.host_limit == "farm01-pve01"
    assert plan.execution.machine_credential_id == 5

    assert [
             %{
               membership_id: @membership_id,
               awx_host_id: 7,
               membership_generation: 3,
               source_fingerprint: @source_fingerprint
             }
           ] = plan.targets

    assert [%{source_fingerprint: @source_fingerprint}] = plan.snapshot["targets"]

    assert plan.launch_opts.inventory_id == 34
    assert plan.launch_opts.host_limit == "farm01-pve01"
    assert plan.launch_opts.credential_ids == [5]

    assert plan.execution.credential_snapshot["credentials"] == [
             %{"id" => 5, "kind" => "ssh"}
           ]

    assert plan.launch_opts.extra_vars["version"] == "1.2.3"

    assert plan.launch_opts.extra_vars["serviceradar_dispatch_id"] ==
             "018f3f56-1111-7222-8333-123456789abf"

    assert plan.launch_opts.extra_vars["serviceradar_snapshot_digest"] ==
             plan.execution.snapshot_digest

    refute inspect(plan) =~ "password"
    refute inspect(plan) =~ "Bearer "
  end

  test "rejects SystemActor substitution and absent authority" do
    system_actor = actor(%{principal_id: "system:awx_schedule_evaluator"})

    assert {:error, :initiating_principal_required} =
             HardenedLaunchPlan.build(intent(%{actor_snapshot: system_actor}))
  end

  test "rejects permissions or targets outside the issuance ceiling" do
    no_launch = actor(%{authority_ceiling: %{"target_membership_ids" => [@membership_id]}})

    assert {:error, :launch_permission_required} =
             HardenedLaunchPlan.build(intent(%{actor_snapshot: no_launch}))

    wrong_target =
      actor(%{
        authority_ceiling: %{
          "permissions" => ["ansible.runs.launch"],
          "target_membership_ids" => ["018f3f56-1111-7222-8333-000000000000"]
        }
      })

    assert {:error, :target_outside_authority_ceiling} =
             HardenedLaunchPlan.build(intent(%{actor_snapshot: wrong_target}))
  end

  test "rejects stale, unapproved, or held memberships" do
    assert {:error, :stale_awx_membership} =
             HardenedLaunchPlan.build(intent(%{memberships: [membership(%{current: false})]}))

    assert {:error, :unapproved_awx_membership} =
             HardenedLaunchPlan.build(
               intent(%{memberships: [membership(%{link_disposition: :proposed})]})
             )

    assert {:error, {:target_held, "sr:device-7"}} =
             HardenedLaunchPlan.build(intent(%{held_device_uids: ["sr:device-7"]}))
  end

  test "requires the canonical source fingerprint on every frozen membership" do
    assert {:error, :membership_source_fingerprint_required} =
             HardenedLaunchPlan.build(
               intent(%{memberships: [membership(%{source_fingerprint: nil})]})
             )

    assert {:error, :membership_source_fingerprint_required} =
             HardenedLaunchPlan.build(
               intent(%{memberships: [membership(%{source_fingerprint: "not-a-fingerprint"})]})
             )
  end

  test "rejects a secret survey binding before local persistence" do
    secret_schema = [%Var{name: "password", type: :password, private: true}]

    assert {:error, {:sensitive_launch_inputs, ["password"]}} =
             HardenedLaunchPlan.build(
               intent(%{variable_schema: secret_schema, inputs: %{"password" => "do-not-store"}})
             )
  end

  test "keeps callback-enabled content unavailable until its owner is installed" do
    callback_binding =
      reviewed_binding(%{
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        ask_credential_on_launch: true,
        callback_credential_type_id: 91,
        callback_credential_organization_id: 2,
        callback_credential_injector_digest: String.duplicate("c", 64),
        callback_credential_slot: "ssh_ca_callback"
      })

    assert {:error, :callback_gate_unavailable} =
             HardenedLaunchPlan.build(intent(%{binding: callback_binding}))

    assert {:ok, plan} =
             HardenedLaunchPlan.build(
               intent(%{binding: callback_binding, callback_gate_available: true})
             )

    assert plan.operation.callback_actions == ["remote_access.ssh_ca.bundle.read"]
    assert plan.snapshot["binding"]["ask_credential_on_launch"] == true
    assert plan.snapshot["binding"]["callback_credential_type_id"] == 91
    assert plan.snapshot["binding"]["callback_credential_organization_id"] == 2

    assert plan.snapshot["binding"]["callback_credential_injector_digest"] ==
             String.duplicate("c", 64)
  end
end
