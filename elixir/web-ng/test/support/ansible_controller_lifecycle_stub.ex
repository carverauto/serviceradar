defmodule ServiceRadarWebNG.TestSupport.AnsibleControllerLifecycleStub do
  @moduledoc false

  def get(_id, _opts), do: {:ok, record()}

  def update(id, attrs, opts) do
    send(self(), {:update, id, attrs, opts})
    {:ok, Map.merge(record(), attrs)}
  end

  def delete(id, opts) do
    send(self(), {:delete, id, opts})
    Process.get({__MODULE__, :delete}, {:ok, :ok})
  end

  def record do
    %{
      id: "00000000-0000-4000-8000-000000000801",
      name: "example-controller",
      description: nil,
      base_url: "https://awx.example.com",
      awx_version: nil,
      agent_id: "example-agent",
      enabled: false,
      sync_credential_secret_id: "00000000-0000-4000-8000-000000000802",
      execution_credential_secret_id: nil,
      callback_credential_secret_id: nil,
      inventory_sync_interval_seconds: 300,
      catalog_sync_interval_seconds: 600,
      status: :unknown,
      last_health_at: nil,
      last_health_summary: nil,
      metadata: %{},
      inserted_at: ~U[2025-04-05 06:07:08.000009Z],
      updated_at: ~U[2025-04-05 06:07:08.000009Z]
    }
  end
end
