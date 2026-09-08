defmodule ServiceRadarWebNG.TestSupport.AnsibleControllersStub do
  @moduledoc false

  def list(opts) do
    send(test_pid(), {:ansible_controllers_list, opts})
    {:ok, [controller()]}
  end

  def get(id, opts) do
    send(test_pid(), {:ansible_controllers_get, id, opts})

    if to_string(id) == controller().id do
      {:ok, controller()}
    else
      {:error, :not_found}
    end
  end

  def create(attrs, opts) do
    send(test_pid(), {:ansible_controllers_create, attrs, opts})
    {:ok, Map.merge(controller(), Map.take(attrs, [:name, :base_url, :agent_id]))}
  end

  def update(id, attrs, opts) do
    send(test_pid(), {:ansible_controllers_update, id, attrs, opts})
    {:ok, Map.merge(controller(), attrs)}
  end

  def set_enabled(id, enabled, opts) do
    send(test_pid(), {:ansible_controllers_set_enabled, id, enabled, opts})
    {:ok, Map.put(controller(), :enabled, enabled)}
  end

  def controller do
    %{
      id: "00000000-0000-4000-8000-000000000301",
      name: "demo-awx",
      description: nil,
      base_url: "https://awx.example.com",
      awx_version: "24.6.1",
      agent_id: "agent-site01-01",
      enabled: true,
      credential_secret_id: "00000000-0000-4000-8000-000000000101",
      sync_credential_secret_id: "00000000-0000-4000-8000-000000000101",
      execution_credential_secret_id: "00000000-0000-4000-8000-000000000101",
      callback_credential_secret_id: nil,
      inventory_sync_interval_seconds: 300,
      catalog_sync_interval_seconds: 600,
      status: :healthy,
      last_health_at: ~U[2026-09-01 00:00:00Z],
      last_health_summary: "ok",
      metadata: %{},
      inserted_at: ~U[2026-09-01 00:00:00Z],
      updated_at: ~U[2026-09-01 00:00:00Z]
    }
  end

  defp test_pid do
    Application.get_env(:serviceradar_web_ng, :ansible_controllers_test_pid, self())
  end
end
