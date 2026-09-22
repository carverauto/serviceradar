defmodule ServiceRadarWebNG.TestSupport.AnsibleRepositoriesStub do
  @moduledoc false

  def list(scope, filters), do: reply(:list, [scope, filters], %{items: [repository()], next_cursor: nil})
  def get(scope, id), do: reply(:get, [scope, id], repository())
  def create(scope, attrs), do: reply(:create, [scope, attrs], Map.merge(repository(), attrs))
  def update(scope, id, attrs, opts), do: reply(:update, [scope, id, attrs, opts], Map.merge(repository(), attrs))
  def delete(scope, id, opts), do: reply(:delete, [scope, id, opts], :ok)

  def sync(scope, id), do: reply(:sync, [scope, id], %{repository: repository(), scheduling_status: :already_scheduled})

  def repository do
    %{
      id: "00000000-0000-4000-8000-000000000701",
      name: "example-playbooks",
      description: "Synthetic catalog",
      git_url: "https://git.example.com/automation.git",
      git_ref: "main",
      credential_secret_id: nil,
      sync_interval_seconds: 600,
      last_sync_at: nil,
      last_sync_status: :pending,
      last_sync_summary: "secret-valued diagnostic must not escape",
      parse_diagnostics: %{"synthetic.yml" => "private diagnostic body"},
      metadata: %{"token" => "synthetic-hidden-token"},
      inserted_at: ~U[2025-02-03 04:05:06.000007Z],
      updated_at: ~U[2025-02-03 04:05:06.000007Z]
    }
  end

  defp reply(action, args, default) do
    send(self(), {:repositories, action, args})
    Process.get({__MODULE__, action}, {:ok, default})
  end
end
