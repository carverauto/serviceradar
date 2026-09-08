defmodule ServiceRadar.Automation.Ansible.HardenedLaunchPlanTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightFixtures, as: Fixtures
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.HardenedLaunchPlan
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var

  @controller_id "018f0000-0000-7000-8000-000000000001"
  @membership_id "018f0000-0000-7000-8000-000000000201"
  @source_fingerprint "sha256:" <> String.duplicate("a", 64)

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
    Fixtures.membership(overrides)
  end

  defp reviewed_binding(overrides \\ %{}) do
    Fixtures.reviewed_binding()
    |> Map.merge(%{
      approval_state: "approved",
      credential_ids: [101, 102],
      job_type: "run",
      dispatch_marker_contract: DispatchMarkerContract.contract()
    })
    |> Map.merge(overrides)
  end

  defp intent(overrides \\ %{}) do
    intent =
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
          preflight_checked_at: Fixtures.now(),
          variable_schema: [%Var{name: "version", type: :text, required: true}],
          inputs: %{"version" => "1.2.3"},
          dispatch_id: "018f0000-0000-7000-8000-000000000501"
        },
        overrides
      )

    preflight_binding = Map.get(intent, :preflight_binding, intent.binding)

    intent
    |> Map.put_new(:preflight_binding, preflight_binding)
    |> Map.put_new(:preflight_attestation, preflight_attestation(preflight_binding))
  end

  defp controller_security_snapshot, do: Fixtures.controller_security_snapshot()

  test "builds a complete secret-free local plan before dispatch" do
    assert {:ok, plan} = HardenedLaunchPlan.build(intent())

    assert plan.operation.initiator_principal_type == :human
    assert plan.operation.declared_inputs == %{"version" => "1.2.3"}
    assert plan.operation.target_digest =~ ~r/\A[0-9a-f]{64}\z/

    assert plan.execution.inventory_id == 8
    assert plan.execution.job_template_id == 42
    assert plan.execution.host_limit == "web01.example.test"
    assert plan.execution.machine_credential_id == 101

    assert [
             %{
               membership_id: @membership_id,
               awx_host_id: 201,
               membership_generation: 5,
               source_fingerprint: @source_fingerprint
             }
           ] = plan.targets

    assert [%{source_fingerprint: @source_fingerprint}] = plan.snapshot["targets"]

    assert plan.launch_opts.inventory_id == 8
    assert plan.launch_opts.host_limit == "web01.example.test"
    assert plan.launch_opts.credential_ids == [101, 102]

    assert plan.execution.credential_snapshot["credentials"] == [
             %{"id" => 101, "kind" => "ssh"},
             %{"id" => 102, "kind" => "vault"}
           ]

    assert plan.launch_opts.extra_vars["version"] == "1.2.3"

    assert plan.launch_opts.extra_vars["serviceradar_dispatch_id"] ==
             "018f0000-0000-7000-8000-000000000501"

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

    assert {:error, {:target_held, "device-web01"}} =
             HardenedLaunchPlan.build(intent(%{held_device_uids: ["device-web01"]}))
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
    callback_binding = callback_binding()

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

  defp callback_binding do
    snapshot =
      put_in(
        Fixtures.reviewed_snapshot(),
        ["template", "prompt_on_launch", "ask_credential_on_launch"],
        true
      )

    {:ok, digest} = AwxLaunchContract.digest(snapshot)

    reviewed_binding(%{
      callback_actions: ["remote_access.ssh_ca.bundle.read"],
      ask_credential_on_launch: true,
      callback_credential_type_id: 91,
      callback_credential_organization_id: 2,
      callback_credential_injector_digest: String.duplicate("c", 64),
      callback_credential_slot: "ssh_ca_callback",
      reviewed_launch_snapshot: snapshot,
      reviewed_launch_snapshot_digest: digest,
      review_metadata: %{
        "review_ticket" => "SEC-1042",
        "awx_snapshot_digest" => digest,
        "dispatch_marker_contract" => DispatchMarkerContract.contract()
      }
    })
  end

  defp preflight_attestation(binding) do
    {:ok, request} = Fixtures.preflight_request(binding)
    {:ok, request_digest} = AwxLaunchContract.request_digest(request)
    {:ok, target_digest} = AwxLaunchContract.target_snapshot_digest(request)

    Fixtures.attestation(%{
      reviewed_launch_snapshot_digest: binding.reviewed_launch_snapshot_digest,
      preflight_request_digest: request_digest,
      target_snapshot_digest: target_digest
    })
  end
end
