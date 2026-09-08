defmodule ServiceRadar.Automation.Ansible.SecureChildLauncherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightFixtures, as: Fixtures
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.SecureChildLauncher

  @actor_id "018f3f56-1111-7222-8333-123456789a01"
  @playbook_id "018f3f56-1111-7222-8333-123456789a02"
  @controller_id "018f0000-0000-7000-8000-000000000001"
  @membership_id "018f0000-0000-7000-8000-000000000201"
  @binding_id "018f0000-0000-7000-8000-000000000101"
  @approval_id "018f0000-0000-7000-8000-000000000102"
  @source_fingerprint "sha256:" <> String.duplicate("a", 64)
  @now ~U[2026-07-14 23:20:00.000000Z]

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

    defp result(name) do
      case Process.get({__MODULE__, name}) do
        {:sequence, [result | remaining]} ->
          Process.put({__MODULE__, name}, {:sequence, remaining})
          result

        result ->
          result
      end
    end

    defp notify(message), do: send(Process.get({__MODULE__, :test_pid}), message)
  end

  setup do
    Process.put({FakeAdapter, :test_pid}, self())
    reset_fake_adapter()
    :ok
  end

  defp reset_fake_adapter do
    Process.put({FakeAdapter, :actor}, {:ok, actor()})
    Process.put({FakeAdapter, :authorization}, {:ok, authorization()})
    Process.put({FakeAdapter, :playbook}, {:ok, playbook()})
    Process.put({FakeAdapter, :memberships}, {:ok, [membership()]})
    Process.put({FakeAdapter, :binding}, {:ok, reviewed_binding()})
    Process.put({FakeAdapter, :controller}, {:ok, controller()})
    Process.put({FakeAdapter, :holds}, {:ok, []})
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
        profile_versions: [
          %{
            id: "018f3f56-1111-7222-8333-123456789a07",
            updated_at: ~U[2026-07-12 14:54:00.000000Z]
          }
        ]
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
    Fixtures.membership(overrides)
  end

  defp controller(overrides \\ %{}), do: Fixtures.controller(overrides)

  defp reviewed_binding(overrides \\ %{}), do: Fixtures.reviewed_binding(overrides)

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
    assert {:ok, result} = launch()

    assert_receive {:load_current_actor, @actor_id}
    assert_receive {:fresh_authorization, @actor_id}
    assert_receive {:load_playbook, @playbook_id}
    assert_receive {:load_memberships, [@membership_id]}
    assert_receive {:load_controller, @controller_id}
    assert_receive {:load_binding, @controller_id, 42}
    assert_receive {:active_hold_device_uids, ["device-web01"]}
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

    assert [
             %{
               membership_id: @membership_id,
               membership_generation: 5,
               source_fingerprint: @source_fingerprint
             }
           ] = plan.targets

    assert plan.execution.controller_id == @controller_id
    assert plan.execution.inventory_id == 8
    assert plan.execution.job_template_id == 42
    assert plan.execution.host_limit == "web01.example.test"
    assert plan.launch_opts.extra_vars["version"] == "1.2.3"

    refute Map.has_key?(request(), :host_limit)
    refute Map.has_key?(request(), :extra_vars)
  end

  test "fails before planning when the live preflight cannot attest the reviewed binding" do
    assert {:error, :awx_preflight_unavailable} =
             launch(%{},
               live_preflight: fn _context, _opts -> {:error, :awx_preflight_unavailable} end
             )

    refute_receive {:launch, _, _}
  end

  test "re-reads authorization and policy after preflight before it can launch" do
    Process.put(
      {FakeAdapter, :authorization},
      {:sequence,
       [
         {:ok, authorization()},
         {:ok, authorization(%{permissions: MapSet.new(["ansible.catalog.view"])})}
       ]}
    )

    assert {:error, :launch_permission_required} = launch()
    assert_receive {:live_preflight, _context}
    refute_receive {:launch, _, _}
  end

  test "rejects a hold, binding revision, controller, or target fingerprint changed after preflight" do
    cases = [
      {
        :holds,
        {:sequence, [{:ok, []}, {:ok, ["device-web01"]}]},
        {:target_held, "device-web01"}
      },
      {
        :binding,
        {:sequence, [{:ok, reviewed_binding()}, {:ok, reviewed_binding(%{binding_version: 4})}]},
        :awx_preflight_binding_drift
      },
      {
        :controller,
        {:sequence, [{:ok, controller()}, {:ok, controller(%{agent_id: "edge-agent-2"})}]},
        :awx_preflight_controller_drift
      },
      {
        :memberships,
        {:sequence,
         [
           {:ok, [membership()]},
           {:ok, [membership(%{source_fingerprint: "sha256:" <> String.duplicate("b", 64)})]}
         ]},
        :awx_preflight_request_drift
      }
    ]

    Enum.each(cases, fn {resource, result, expected_error} ->
      Process.put({FakeAdapter, resource}, result)

      assert {:error, ^expected_error} = launch()
      assert_receive {:live_preflight, _context}
      refute_receive {:launch, _, _}

      reset_fake_adapter()
    end)
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

  test "rejects membership approval contraction after selection" do
    for {overrides, expected_error} <- [
          {%{current: false}, :stale_awx_membership},
          {%{enabled: false}, :disabled_awx_membership},
          {%{link_disposition: :proposed}, :unapproved_awx_membership}
        ] do
      Process.put({FakeAdapter, :memberships}, {:ok, [membership(overrides)]})
      assert {:error, ^expected_error} = launch()
      refute_receive {:launch, _, _}
    end
  end

  test "rejects expired approval and a canonical-device-wide active hold" do
    Process.put(
      {FakeAdapter, :binding},
      {:ok, reviewed_binding(%{approval_expires_at: @now})}
    )

    assert {:error, :binding_approval_expired} = launch()

    Process.put({FakeAdapter, :binding}, {:ok, reviewed_binding()})
    Process.put({FakeAdapter, :holds}, {:ok, ["device-web01"]})
    assert {:error, {:target_held, "device-web01"}} = launch()
    refute_receive {:launch, _, _}
  end

  test "requires fresh action permissions and derives callback policy from the binding" do
    Process.put({FakeAdapter, :binding}, {:ok, callback_binding()})

    assert {:error,
            {:callback_permissions_required, ["devices.remote_access.ssh.ca_bundle.read"]}} =
             launch()

    Process.put(
      {FakeAdapter, :authorization},
      {:ok,
       authorization(%{
         permissions:
           MapSet.new([
             "ansible.runs.launch",
             "devices.remote_access.ssh.ca_bundle.read"
           ])
       })}
    )

    assert {:ok, %{plan: plan}} = launch()

    assert_receive {:launch, ^plan, _controller}

    assert plan.callback_contract.action == "remote_access.ssh_ca.bundle.read"

    assert plan.operation.authority_ceiling["permissions"] == [
             "ansible.runs.launch",
             "devices.remote_access.ssh.ca_bundle.read"
           ]

    assert plan.execution.credential_snapshot["dynamic_callback_slot"] ==
             "ssh_ca_callback"
  end

  test "rejects callback endpoint and lifecycle fields from requests and survey inputs" do
    for key <- [
          :callback_url,
          :callback_origin,
          :callback_response_policy_provider,
          :manifest_sha256,
          :phase,
          :operation,
          :state
        ] do
      assert {:error, {:raw_launch_scope_or_policy_forbidden, [expected]}} =
               launch(%{key => "attacker-selected"})

      assert expected == Atom.to_string(key)
    end

    Process.put(
      {FakeAdapter, :binding},
      {:ok,
       reviewed_binding(%{
         input_schema: %{"phase" => %{"type" => "text", "required" => true}},
         input_classifications: %{"phase" => "internal"}
       })}
    )

    assert {:error, {:sensitive_binding_input_forbidden, "phase"}} =
             launch(%{inputs: %{"phase" => "commit"}})
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

  defp launch(overrides \\ %{}, opts \\ []) do
    opts =
      Keyword.merge(
        [
          adapter: FakeAdapter,
          now: @now,
          live_preflight: &live_preflight/2,
          edge_principal_resolver: &edge_principal/1
        ],
        opts
      )

    overrides
    |> request()
    |> SecureChildLauncher.launch(opts)
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
      callback_credential_type_id: 6,
      callback_credential_organization_id: 2,
      callback_credential_injector_digest: String.duplicate("c", 64),
      callback_credential_slot: "ssh_ca_callback",
      reviewed_launch_snapshot: snapshot,
      reviewed_launch_snapshot_digest: digest,
      review_metadata: %{
        "policy_version" => "ssh-policy-v1",
        "awx_snapshot_digest" => digest,
        "dispatch_marker_contract" => DispatchMarkerContract.contract(),
        "callback_contract" => %{
          "schema" => "serviceradar.automation_callback_launch_contract/v1",
          "action" => "remote_access.ssh_ca.bundle.read",
          "action_version" => "1.0.0",
          "request_schema" => "serviceradar.remote_access.ssh_ca_bundle_request/v1",
          "response_schema" => "serviceradar.remote_access.ssh_ca_bundle/v1",
          "manifest_sha256" => String.duplicate("a", 64),
          "phase" => "preflight",
          "operation" => "enroll",
          "state" => "present",
          "policy_version" => "ssh-policy-v1",
          "ttl_seconds" => 120
        }
      }
    })
  end

  defp live_preflight(%{binding: binding} = context, _opts) do
    send(self(), {:live_preflight, context})
    {:ok, preflight_attestation(binding)}
  end

  defp edge_principal("edge-agent-1"),
    do: {:ok, %{agent_id: "edge-agent-1", partition_id: "farm01"}}

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
