defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher

  defmodule FakeActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions

    @impl true
    def persist_plan(plan) do
      send(self_pid(), {:persist_plan, plan})

      case Process.get(:persist_result) do
        nil ->
          {:ok,
           %{
             operation: %{id: "operation-1"},
             execution: %{id: "execution-1"},
             targets: [%{id: "target-1"}]
           }}

        result ->
          result
      end
    end

    @impl true
    def mark_dispatching(persisted) do
      send(self_pid(), {:mark_dispatching, persisted})
      :ok
    end

    @impl true
    def dispatch(controller, template_id, launch_opts, context) do
      send(self_pid(), {:dispatch, controller, template_id, launch_opts, context})

      case Process.get(:dispatch_result) do
        nil -> {:ok, %{id: "command-1"}}
        result -> result
      end
    end

    @impl true
    def mark_dispatch_failed(persisted, reason) do
      send(self_pid(), {:mark_dispatch_failed, persisted, reason})
      :ok
    end

    defp self_pid, do: Process.get(:test_pid)
  end

  setup do
    Process.put(:test_pid, self())
    Process.delete(:persist_result)
    Process.delete(:dispatch_result)
    :ok
  end

  defp plan do
    %{
      operation: %{action: "ansible.playbook.run"},
      execution: %{job_template_id: 42},
      targets: [%{awx_host_id: 7}],
      launch_opts: %{inventory_id: 34, host_limit: "host-a"},
      command_context: %{
        "controller_id" => "controller-1",
        "dispatch_id" => "dispatch-1"
      }
    }
  end

  test "persists the complete plan before external dispatch" do
    controller = %{id: "controller-1"}

    assert {:ok, result} =
             HardenedRunLauncher.launch(plan(), controller,
               actions: FakeActions,
               schedule_id: "schedule-1"
             )

    assert result.command.id == "command-1"
    assert_receive {:persist_plan, persisted_plan}
    assert persisted_plan.targets == [%{awx_host_id: 7}]
    assert_receive {:mark_dispatching, %{operation: %{id: "operation-1"}}}

    assert_receive {:dispatch, ^controller, 42, launch_opts, context}
    assert launch_opts.host_limit == "host-a"
    assert context["operation_id"] == "operation-1"
    assert context["execution_id"] == "execution-1"
    assert context["schedule_id"] == "schedule-1"
  end

  test "does not dispatch a partially persisted plan" do
    Process.put(:persist_result, {:error, {:target_create_failed, :duplicate}})

    assert {:error, {:target_create_failed, :duplicate}} =
             HardenedRunLauncher.launch(plan(), %{id: "controller-1"}, actions: FakeActions)

    assert_receive {:persist_plan, _}
    refute_receive {:dispatch, _, _, _, _}
  end

  test "records a dispatch failure against already persisted state" do
    Process.put(:dispatch_result, {:error, :agent_offline})

    assert {:error, {:dispatch_failed, :agent_offline}} =
             HardenedRunLauncher.launch(plan(), %{id: "controller-1"}, actions: FakeActions)

    assert_receive {:mark_dispatch_failed, %{execution: %{id: "execution-1"}}, :agent_offline}
  end
end
