defmodule ServiceRadar.Automation.Ansible.SecureChildLauncherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.SecureChildLauncher

  @actor_id "018f3f56-1111-7222-8333-123456789a01"
  @playbook_id "018f3f56-1111-7222-8333-123456789a02"
  @controller_id "018f3f56-1111-7222-8333-123456789a03"
  @membership_id "018f3f56-1111-7222-8333-123456789a04"
  @binding_id "018f3f56-1111-7222-8333-123456789a05"
  @approval_id "018f3f56-1111-7222-8333-123456789a06"
  @now ~U[2026-07-12 15:00:00.000000Z]

  defmodule FakeAdapter do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureChildLauncher.Adapter

    @impl true
    def load_current_actor(actor_id) do
      notify({:load_current_actor, actor_id})
      result(:actor)
    end

    @impl true
    def fresh_authorization(actor) do
      notify({:fresh_authorization, actor.id})
      result(:authorization)
    end

    @impl true
    def load_playbook(playbook_id) do
      notify({:load_playbook, playbook_id})
      result(:playbook)
    end

    @impl true
    def load_memberships(membership_ids) do
      notify({:load_memberships, membership_ids})
      result(:memberships)
    end

    @impl true
    def load_binding(controller_id, job_template_id) do
      notify({:load_binding, controller_id, job_template_id})
      result(:binding)
    end

    @impl true
    def load_controller(controller_id) do
      notify({:load_controller, controller_id})
      result(:controller)
    end

    @impl true
    def active_hold_device_uids(device_uids) do
      notify({:active_hold_device_uids, device_uids})
      result(:holds)
    end

    @impl true
    def launch(plan, controller) do
      notify({:launch, plan, controller})
      {:ok, %{plan: plan, controller: controller}}
    end

    defp result(name), do: Process.get({__MODULE__, name})
    defp notify(message), do: send(Process.get({__MODULE__, :test_pid}), message)
  end

  setup do
    Process.put({FakeAdapter, :test_pid}, self())
    Process.put({FakeAdapter, :actor}, {:ok, actor()})
    Process.put({FakeAdapter, :authorization}, {:ok, authorization()})
    Process.put({FakeAdapter, :playbook}, {:ok, playbook()})
    Process.put({FakeAdapter, :memberships}, {:ok, [membership()]})
    Process.put({FakeAdapter, :binding}, {:ok, reviewed_binding()})
    Process.put({FakeAdapter, :controller}, {:ok, controller()})
    Process.put({FakeAdapter, :holds}, {:ok, []})
    :ok
  end

  defp actor(overrides \\ %{}) do
    Map.merge(
      %{
        id: @actor_id,
        role: :operator,
        role_profile_id: "018f3f56-1111-7222-8333-123456789a07",
        status: :active,
        updated_at: ~U[2026-07-12 14:55:00.000000Z]
      },
      overrides
    )
  end

  defp authorization(overrides \\ %{}) do
    Map.merge(
      %{
        permissions: MapSet.new(["ansible.runs.launch", "ansible.catalog.view"]),
        profile_id: "018f3f56-1111-7222-8333-123456789a07",
        profile_updated_at: ~U[2026-07-12 14:54:00.000000Z]
      },
      overrides
    )
  end

  defp playbook(overrides \\ %{}) do
    Map.merge(
      %{
        id: @playbook_id,
        source_type: :awx,
        controller_id: @controller_id,
        awx_job_template_id: 42,
        parse_status: :ok
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
        host_name: "farm01-pve01",
        ansible_host: "192.168.2.22",
        current: true,
        enabled: true,
        link_disposition: :approved
      },
      overrides
    )
  end

  defp controller(overrides \\ %{}) do
    Map.merge(%{id: @controller_id, enabled: true, name: "farm01-awx"}, overrides)
  end

  defp reviewed_binding(overrides \\ %{}) do
    Map.merge(
      %{
        id: @binding_id,
        controller_id: @controller_id,
        job_template_id: 42,
        binding_version: 3,
        current: true,
        approval_state: :approved,
        approval_id: @approval_id,
        approval_expires_at: ~U[2026-07-12 16:00:00.000000Z],
        allowed_inventory_ids: [34],
        inventory_group_names: ["linux"],
        ask_limit_on_launch: true,
        dispatch_markers_retained: true,
        project_update_on_launch: false,
        project_id: 3,
        scm_revision: String.duplicate("a", 40),
        content_sha256: String.duplicate("b", 64),
        execution_environment_id: 4,
        credentials: [%{"id" => 5, "kind" => "ssh"}],
        machine_credential_id: 5,
        run_mode_supported: true,
        check_mode_supported: true,
        awx_created_by_id: 11,
        input_schema: %{
          "version" => %{
            "type" => "text",
            "required" => true,
            "label" => "Package version"
          }
        },
        input_classifications: %{"version" => "internal"},
        callback_actions: [],
        reviewed_by_principal_type: :human,
        reviewed_by_principal_id: "reviewer-1",
        reviewed_at: ~U[2026-07-12 14:00:00.000000Z],
        review_metadata: %{"review_ticket" => "SEC-42"}
      },
      overrides
    )
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        actor: actor(),
        membership_ids: [@membership_id],
        playbook_id: @playbook_id,
        job_template_id: 42,
        mode: :run,
        inputs: %{"version" => "1.2.3"},
        request_source: :device_details
      },
      overrides
    )
  end

  test "loads exact durable identities and dispatches an attenuated immutable plan" do
    assert {:ok, result} =
             SecureChildLauncher.launch(request(), adapter: FakeAdapter, now: @now)

    assert_receive {:load_current_actor, @actor_id}
    assert_receive {:fresh_authorization, @actor_id}
    assert_receive {:load_playbook, @playbook_id}
    assert_receive {:load_memberships, [@membership_id]}
    assert_receive {:load_controller, @controller_id}
    assert_receive {:load_binding, @controller_id, 42}
    assert_receive {:active_hold_device_uids, ["sr:device-7"]}
    assert_receive {:launch, plan, %{id: @controller_id}}

    assert result.plan == plan
    assert plan.operation.initiator_principal_type == :human
    assert plan.operation.initiator_principal_id == @actor_id

    assert plan.operation.authority_ceiling == %{
             "permissions" => ["ansible.runs.launch"],
             "target_membership_ids" => [@membership_id]
           }

    assert plan.operation.approval_snapshot["binding_id"] == @binding_id
    assert plan.operation.approval_snapshot["binding_version"] == 3
    assert plan.operation.approval_snapshot["approval_id"] == @approval_id
    assert plan.operation.request_source == "device_details"

    assert [%{membership_id: @membership_id, membership_generation: 3}] = plan.targets
    assert plan.execution.controller_id == @controller_id
    assert plan.execution.inventory_id == 34
    assert plan.execution.job_template_id == 42
    assert plan.execution.host_limit == "farm01-pve01"
    assert plan.launch_opts.extra_vars["version"] == "1.2.3"

    refute Map.has_key?(request(), :host_limit)
    refute Map.has_key?(request(), :extra_vars)
  end

  test "rejects SystemActor and non-membership selectors before any lookup" do
    system_actor = %{id: "system:ansible", role: :system}

    assert {:error, :human_actor_required} =
             SecureChildLauncher.launch(request(%{actor: system_actor}),
               adapter: FakeAdapter,
               now: @now
             )

    assert {:error, :invalid_membership_id} =
             SecureChildLauncher.launch(request(%{membership_ids: ["192.168.2.22"]}),
               adapter: FakeAdapter,
               now: @now
             )

    assert {:error, {:raw_launch_scope_or_policy_forbidden, ["host_limit"]}} =
             SecureChildLauncher.launch(request(%{host_limit: "all"}),
               adapter: FakeAdapter,
               now: @now
             )

    refute_receive {:load_current_actor, _}
  end

  test "requires a freshly loaded active actor and fresh launch permission" do
    Process.put({FakeAdapter, :actor}, {:ok, actor(%{status: :inactive})})

    assert {:error, :actor_inactive} = launch()
    refute_receive {:load_playbook, _}

    Process.put({FakeAdapter, :actor}, {:ok, actor()})

    Process.put(
      {FakeAdapter, :authorization},
      {:ok, authorization(%{permissions: MapSet.new(["ansible.catalog.view"])})}
    )

    assert {:error, :launch_permission_required} = launch()
    refute_receive {:load_playbook, _}
  end

  test "rejects membership, controller, inventory, and binding drift" do
    other_controller = "018f3f56-1111-7222-8333-123456789a08"

    Process.put(
      {FakeAdapter, :memberships},
      {:ok, [membership(%{controller_id: other_controller})]}
    )

    assert {:error, :playbook_controller_drift} = launch()
    refute_receive {:launch, _, _}

    Process.put({FakeAdapter, :memberships}, {:ok, [membership()]})
    Process.put({FakeAdapter, :controller}, {:ok, controller(%{enabled: false})})
    assert {:error, :controller_disabled} = launch()

    Process.put({FakeAdapter, :controller}, {:ok, controller()})

    Process.put(
      {FakeAdapter, :binding},
      {:ok, reviewed_binding(%{allowed_inventory_ids: [35]})}
    )

    assert {:error, :binding_inventory_drift} = launch()
    refute_receive {:launch, _, _}
  end

  test "rejects expired approval and a canonical-device-wide active hold" do
    Process.put(
      {FakeAdapter, :binding},
      {:ok, reviewed_binding(%{approval_expires_at: @now})}
    )

    assert {:error, :binding_approval_expired} = launch()

    Process.put({FakeAdapter, :binding}, {:ok, reviewed_binding()})
    Process.put({FakeAdapter, :holds}, {:ok, ["sr:device-7"]})
    assert {:error, {:target_held, "sr:device-7"}} = launch()
    refute_receive {:launch, _, _}
  end

  test "rejects callback-enabled bindings until pending-grant gating exists" do
    Process.put(
      {FakeAdapter, :binding},
      {:ok, reviewed_binding(%{callback_actions: ["remote_access.ssh_ca.bundle.read"]})}
    )

    assert {:error, {:callback_permissions_required, ["remote_access.ssh_ca.bundle.read"]}} =
             launch()

    Process.put(
      {FakeAdapter, :authorization},
      {:ok,
       authorization(%{
         permissions:
           MapSet.new([
             "ansible.runs.launch",
             "remote_access.ssh_ca.bundle.read"
           ])
       })}
    )

    assert {:error, :callback_gate_unavailable} = launch()
    refute_receive {:launch, _, _}
  end

  test "passes only binding-declared typed inputs to the planner" do
    assert {:error, {:undeclared_launch_inputs, ["bearer_token"]}} =
             launch(%{
               inputs: %{
                 "version" => "1.2.3",
                 "bearer_token" => "must-not-cross-the-boundary"
               }
             })

    refute_receive {:launch, _, _}

    Process.put(
      {FakeAdapter, :binding},
      {:ok,
       reviewed_binding(%{
         input_schema: %{
           "bearer_token" => %{"type" => "text", "required" => true}
         },
         input_classifications: %{"bearer_token" => "internal"}
       })}
    )

    assert {:error, {:sensitive_binding_input_forbidden, "bearer_token"}} =
             launch(%{inputs: %{"bearer_token" => "must-not-be-collected"}})

    refute_receive {:launch, _, _}
  end

  defp launch(overrides \\ %{}) do
    overrides
    |> request()
    |> SecureChildLauncher.launch(adapter: FakeAdapter, now: @now)
  end
end
