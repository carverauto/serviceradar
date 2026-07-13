defmodule ServiceRadar.Automation.Ansible.SecureLaunchResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.SecureLaunchResolver
  alias ServiceRadar.Automation.Ansible.SecureLaunchService

  @actor_id "018f3f56-2222-7222-8333-123456789a01"
  @playbook_id "018f3f56-2222-7222-8333-123456789a02"
  @controller_id "018f3f56-2222-7222-8333-123456789a03"
  @binding_id "018f3f56-2222-7222-8333-123456789a04"
  @approval_id "018f3f56-2222-7222-8333-123456789a05"
  @membership_one "018f3f56-2222-7222-8333-123456789a06"
  @membership_two "018f3f56-2222-7222-8333-123456789a07"
  @now ~U[2026-07-13 03:00:00.000000Z]

  defmodule FakeAdapter do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureLaunchResolver.Adapter

    @impl true
    def load_playbook(playbook_id, actor) do
      notify({:load_playbook, playbook_id, actor.id})
      result(:playbook)
    end

    @impl true
    def list_current_memberships(device_uid, actor) do
      notify({:list_current_memberships, device_uid, actor.id})
      Process.get({__MODULE__, {:memberships, device_uid}})
    end

    @impl true
    def load_current_approved_binding(controller_id, job_template_id, actor) do
      notify({:load_binding, controller_id, job_template_id, actor.id})
      result(:binding)
    end

    defp result(name), do: Process.get({__MODULE__, name})
    defp notify(message), do: send(Process.get({__MODULE__, :test_pid}), message)
  end

  defmodule FakeLauncher do
    @moduledoc false

    def launch(request, opts) do
      send(Process.get({__MODULE__, :test_pid}), {:secure_launch, request, opts})

      {:ok,
       %{
         operation: %{id: "018f3f56-2222-7222-8333-123456789a08"},
         execution: %{id: "018f3f56-2222-7222-8333-123456789a09"}
       }}
    end
  end

  setup do
    Process.put({FakeAdapter, :test_pid}, self())
    Process.put({FakeLauncher, :test_pid}, self())
    Process.put({FakeAdapter, :playbook}, {:ok, playbook()})
    Process.put({FakeAdapter, :binding}, {:ok, template_binding()})
    put_memberships("sr:one", [membership(@membership_one, "sr:one", 7)])
    put_memberships("sr:two", [membership(@membership_two, "sr:two", 8)])
    :ok
  end

  test "resolves exact approved memberships and the reviewed binding schema" do
    assert {:ok, resolution} = resolve()

    assert resolution.controller_id == @controller_id
    assert resolution.inventory_id == 34
    assert resolution.membership_ids == [@membership_one, @membership_two]
    assert resolution.binding_version == 4
    assert Enum.map(resolution.variables, & &1.name) == ["environment", "replicas"]
    assert Enum.find(resolution.variables, &(&1.name == "replicas")).type == :integer

    assert_receive {:load_playbook, @playbook_id, @actor_id}
    assert_receive {:load_binding, @controller_id, 42, @actor_id}
    assert_receive {:list_current_memberships, "sr:one", @actor_id}
    assert_receive {:list_current_memberships, "sr:two", @actor_id}
  end

  test "requires an active human actor before any catalog lookup" do
    assert {:error, :human_actor_required} =
             SecureLaunchResolver.resolve(
               %{id: "system:ansible", role: :system, status: :active},
               ["sr:one"],
               @playbook_id,
               adapter: FakeAdapter,
               now: @now
             )

    assert {:error, :actor_inactive} =
             SecureLaunchResolver.resolve(
               %{id: @actor_id, role: :operator},
               ["sr:one"],
               @playbook_id,
               adapter: FakeAdapter,
               now: @now
             )

    refute_receive {:load_playbook, _, _}
  end

  test "fails closed unless memberships are approved, current, and enabled" do
    for overrides <- [
          [link_disposition: :proposed],
          [current: false],
          [enabled: false]
        ] do
      put_memberships("sr:one", [membership(@membership_one, "sr:one", 7, overrides)])
      assert {:error, {:target_not_ready, "sr:one"}} = resolve()
    end
  end

  test "requires exactly one common inventory and one membership per target" do
    other_one = "018f3f56-2222-7222-8333-123456789a10"
    other_two = "018f3f56-2222-7222-8333-123456789a11"

    put_memberships("sr:one", [
      membership(@membership_one, "sr:one", 7),
      membership(other_one, "sr:one", 17, inventory_id: 35)
    ])

    put_memberships("sr:two", [
      membership(@membership_two, "sr:two", 8),
      membership(other_two, "sr:two", 18, inventory_id: 35)
    ])

    Process.put(
      {FakeAdapter, :binding},
      {:ok, template_binding(%{allowed_inventory_ids: [34, 35]})}
    )

    assert {:error, :ambiguous_common_approved_inventory} = resolve()

    put_memberships("sr:one", [membership(@membership_one, "sr:one", 7)])
    put_memberships("sr:two", [membership(other_two, "sr:two", 18, inventory_id: 35)])
    assert {:error, :no_common_approved_inventory} = resolve()
  end

  test "callback readiness requires credential prompting in the reviewed template" do
    Process.put(
      {FakeAdapter, :binding},
      {:ok,
       template_binding(%{
         callback_actions: ["remote_access.ssh_ca.bundle.read"],
         ask_credential_on_launch: false
       })}
    )

    assert {:error, :binding_callback_credentials_not_promptable} = resolve()
  end

  test "revalidates resolution on submit and never launches stale proposed targets" do
    assert {:ok, _ready} = resolve()

    put_memberships("sr:one", [
      membership(@membership_one, "sr:one", 7, link_disposition: :proposed)
    ])

    assert {:error, {:target_not_ready, "sr:one"}} =
             SecureLaunchService.launch(
               actor(),
               ["sr:one", "sr:two"],
               @playbook_id,
               %{"environment" => "prod", "replicas" => "3"},
               resolver_adapter: FakeAdapter,
               launcher: FakeLauncher,
               now: @now,
               request_source: :ansible_launch_live
             )

    refute_receive {:secure_launch, _, _}
  end

  test "launches only canonical binding-declared typed inputs with the human actor" do
    assert {:ok, %{operation: %{id: _id}}} =
             SecureLaunchService.launch(
               actor(),
               ["sr:one", "sr:two"],
               @playbook_id,
               %{"environment" => "prod", "replicas" => "3"},
               resolver_adapter: FakeAdapter,
               launcher: FakeLauncher,
               launcher_adapter: :child_adapter,
               now: @now,
               request_source: :ansible_launch_live
             )

    assert_receive {:secure_launch, request, launcher_opts}
    assert request.actor.id == @actor_id
    assert request.membership_ids == [@membership_one, @membership_two]
    assert request.inputs == %{"environment" => "prod", "replicas" => 3}
    assert request.request_source == :ansible_launch_live
    assert launcher_opts[:adapter] == :child_adapter

    assert {:error, {:undeclared_launch_inputs, ["extra_vars"]}} =
             SecureLaunchService.launch(
               actor(),
               ["sr:one", "sr:two"],
               @playbook_id,
               %{"extra_vars" => "{}"},
               resolver_adapter: FakeAdapter,
               launcher: FakeLauncher,
               now: @now
             )

    refute_receive {:secure_launch, _, _}
  end

  defp resolve do
    SecureLaunchResolver.resolve(actor(), ["sr:one", "sr:two"], @playbook_id,
      adapter: FakeAdapter,
      now: @now
    )
  end

  defp actor do
    %{id: @actor_id, role: :operator, status: :active}
  end

  defp playbook do
    %{
      id: @playbook_id,
      source_type: :awx,
      controller_id: @controller_id,
      awx_job_template_id: 42,
      parse_status: :ok,
      name: "Install ServiceRadar access CA"
    }
  end

  defp template_binding(overrides \\ %{}) do
    Map.merge(
      %{
        id: @binding_id,
        controller_id: @controller_id,
        job_template_id: 42,
        binding_version: 4,
        current: true,
        approval_state: :approved,
        approval_id: @approval_id,
        approval_expires_at: ~U[2026-07-13 04:00:00.000000Z],
        allowed_inventory_ids: [34],
        run_mode_supported: true,
        check_mode_supported: false,
        input_schema: %{
          "environment" => %{
            "type" => "select",
            "required" => true,
            "choices" => ["stage", "prod"]
          },
          "replicas" => %{"type" => "integer", "required" => false, "min" => 1, "max" => 10}
        },
        input_classifications: %{"environment" => "internal", "replicas" => "internal"}
      },
      overrides
    )
  end

  defp membership(id, device_uid, awx_host_id, overrides \\ []) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        id: id,
        controller_id: @controller_id,
        inventory_id: 34,
        awx_host_id: awx_host_id,
        canonical_device_uid: device_uid,
        source_generation: 3,
        host_name: "host-#{awx_host_id}",
        current: true,
        enabled: true,
        link_disposition: :approved
      },
      overrides
    )
  end

  defp put_memberships(device_uid, memberships) do
    Process.put({FakeAdapter, {:memberships, device_uid}}, {:ok, memberships})
  end
end
