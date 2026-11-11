defmodule ServiceRadar.Automation.Ansible.ControllerHealthWorkerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerHealthWorker

  defmodule FakeAwxClient do
    @moduledoc false
    def ping(controller, opts) do
      send(opts[:test_pid] || self(), {:ping, controller.id, opts})
      {:ok, %{id: "command-1"}}
    end
  end

  defmodule FailingAwxClient do
    @moduledoc false
    def ping(_controller, _opts), do: {:error, :unreachable}
  end

  defmodule OfflineAgentAwxClient do
    @moduledoc false
    def ping(controller, _opts), do: {:error, {:agent_offline, controller.agent_id}}
  end

  defp controller(overrides \\ %{}) do
    Map.merge(
      %Controller{
        id: "ctrl-uuid-1",
        name: "Production AWX",
        base_url: "https://awx.example.com",
        agent_id: "agent-a",
        credential_secret_id: "secret-1",
        run_pulse_interval_ms: 2000
      },
      Map.new(overrides)
    )
  end

  test "probe/2 dispatches awx.ping with controller_id context" do
    assert :ok =
             ControllerHealthWorker.probe(controller(),
               awx_client: FakeAwxClient,
               test_pid: self()
             )

    assert_received {:ping, "ctrl-uuid-1", opts}
    assert opts[:source] == :automation
    assert opts[:context]["controller_id"] == "ctrl-uuid-1"
    assert opts[:context]["verb"] == "awx.ping"
  end

  test "probe/2 returns the dispatch error and warns with the reason an operator needs" do
    log =
      capture_log([level: :warning], fn ->
        assert {:error, :unreachable} =
                 ControllerHealthWorker.probe(controller(), awx_client: FailingAwxClient)
      end)

    assert log =~ "controller_id=ctrl-uuid-1"
    assert log =~ "agent_id=agent-a"
    assert log =~ "reason=:unreachable"
  end

  test "probe/2 does not warn while the controller's agent has no control session" do
    log =
      capture_log([level: :warning], fn ->
        assert {:error, {:agent_offline, "agent-a"}} =
                 ControllerHealthWorker.probe(controller(), awx_client: OfflineAgentAwxClient)
      end)

    refute log =~ "ControllerHealthWorker"
  end

  test "perform/1 returns invalid_args when controller_id is missing" do
    assert {:error, :invalid_args} = ControllerHealthWorker.perform(%Oban.Job{args: %{}})
  end
end
