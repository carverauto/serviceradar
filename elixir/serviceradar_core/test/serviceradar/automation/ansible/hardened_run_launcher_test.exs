defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightFixtures, as: Fixtures
  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher

  defmodule FakeActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions

    @impl true
    def persist_plan(plan, controller) do
      send(self_pid(), {:persist_plan, plan, controller})

      case Process.get(:persist_result) do
        nil ->
          {:ok,
           %{
             operation: %{id: "operation-1"},
             execution: %{id: "execution-1"},
             targets: [%{id: "target-1"}],
             attempt: %{id: "attempt-1"}
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
    def dispatch(attempt) do
      send(self_pid(), {:dispatch, attempt})

      case Process.get(:dispatch_result) do
        nil -> {:ok, :dispatched}
        result -> result
      end
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
    preflight_attrs = Fixtures.attestation_attrs()

    %{
      operation: Map.merge(%{action: "ansible.playbook.run"}, preflight_attrs),
      execution:
        Map.merge(
          %{job_template_id: 42, controller_id: Fixtures.controller_id()},
          preflight_attrs
        ),
      targets: [%{awx_host_id: 7}],
      launch_opts: %{inventory_id: 34, host_limit: "host-a"},
      command_context: %{
        "controller_id" => Fixtures.controller_id(),
        "dispatch_id" => "dispatch-1"
      }
    }
  end

  defp controller, do: Fixtures.controller()

  defp edge_principal("edge-agent-1") do
    {:ok, %{agent_id: "edge-agent-1", partition_id: "farm01"}}
  end

  defp launch(launch_plan \\ nil, opts \\ []) do
    launch_plan = launch_plan || plan()

    opts =
      Keyword.merge(
        [
          actions: FakeActions,
          edge_principal_resolver: &edge_principal/1,
          preflight_evidence_reader: fn evidence_id ->
            if evidence_id == Fixtures.evidence_id(),
              do: {:ok, Fixtures.evidence()},
              else: {:error, :not_found}
          end,
          now: Fixtures.now()
        ],
        opts
      )

    HardenedRunLauncher.launch(launch_plan, controller(), opts)
  end

  test "persists the complete plan before external dispatch" do
    controller = controller()

    assert {:ok, result} = launch(plan(), schedule_id: "schedule-1")

    assert result.dispatch_outcome == :dispatched
    assert_receive {:persist_plan, persisted_plan, ^controller}
    assert persisted_plan.targets == [%{awx_host_id: 7}]
    assert_receive {:mark_dispatching, %{operation: %{id: "operation-1"}}}
    assert_receive {:dispatch, %{id: "attempt-1"}}
  end

  test "does not dispatch a partially persisted plan" do
    Process.put(:persist_result, {:error, {:target_create_failed, :duplicate}})

    assert {:error, {:target_create_failed, :duplicate}} =
             launch()

    assert_receive {:persist_plan, _, _}
    refute_receive {:dispatch, _}
  end

  test "defers a dispatch failure to durable recovery without retaining arbitrary error data" do
    Process.put(:dispatch_result, {:error, %{password: "never-persist-this"}})

    assert {:ok, result} =
             launch()

    assert result.dispatch_outcome == {:deferred, "internal_error"}
    refute inspect(result) =~ "never-persist-this"
  end

  test "does not persist or dispatch a plan without immutable preflight evidence" do
    invalid_plan =
      plan()
      |> update_in([:operation], &Map.delete(&1, :preflight_evidence_id))
      |> update_in([:execution], &Map.delete(&1, :preflight_evidence_id))

    assert {:error, :awx_preflight_evidence_mismatch} = launch(invalid_plan)
    refute_receive {:persist_plan, _, _}
    refute_receive {:dispatch, _}
  end

  test "does not persist when the current edge partition changed after preflight" do
    assert {:error, :awx_preflight_partition_drift} =
             launch(plan(),
               edge_principal_resolver: fn "edge-agent-1" ->
                 {:ok, %{agent_id: "edge-agent-1", partition_id: "tonka01"}}
               end
             )

    refute_receive {:persist_plan, _, _}
    refute_receive {:dispatch, _}
  end
end
