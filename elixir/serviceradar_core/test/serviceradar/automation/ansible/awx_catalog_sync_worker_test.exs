defmodule ServiceRadar.Automation.Ansible.AwxCatalogSyncWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxCatalogSyncWorker
  alias ServiceRadar.Automation.Ansible.Controller

  defmodule FakeAwxClient do
    @moduledoc false
    def list_templates(controller, opts) do
      send(opts[:test_pid] || self(), {:list_templates, controller.id, opts})
      {:ok, %{id: "command-1"}}
    end
  end

  defmodule FailingAwxClient do
    @moduledoc false
    def list_templates(_controller, _opts), do: {:error, :unreachable}
  end

  defp controller(overrides \\ %{}) do
    Map.merge(
      %Controller{
        id: "ctrl-uuid-1",
        name: "Production AWX",
        base_url: "https://awx.example.com",
        agent_id: "agent-a",
        credential_secret_id: "secret-1",
        catalog_sync_interval_seconds: 600
      },
      Map.new(overrides)
    )
  end

  test "sync/2 dispatches awx.list_templates with controller_id context" do
    assert :ok =
             AwxCatalogSyncWorker.sync(controller(),
               awx_client: FakeAwxClient,
               test_pid: self()
             )

    assert_received {:list_templates, "ctrl-uuid-1", opts}
    assert opts[:source] == :automation
    assert opts[:context]["controller_id"] == "ctrl-uuid-1"
    assert opts[:context]["verb"] == "awx.list_templates"
  end

  test "sync/2 surfaces dispatch errors" do
    assert {:error, :unreachable} =
             AwxCatalogSyncWorker.sync(controller(), awx_client: FailingAwxClient)
  end

  test "perform/1 returns :invalid_args when controller_id missing" do
    assert {:error, :invalid_args} = AwxCatalogSyncWorker.perform(%Oban.Job{args: %{}})
  end
end
