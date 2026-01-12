defmodule ServiceRadar.Infrastructure.Changes.EnsureStateMonitor do
  @moduledoc """
  Ash change that ensures the StateMonitor is running for a tenant.

  When infrastructure resources (gateways, agents, checkers) are created,
  this change ensures that the tenant-scoped StateMonitor GenServer is
  running to monitor their health.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Infrastructure.StateMonitor

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      ensure_state_monitor_running(record.tenant_id)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp ensure_state_monitor_running(tenant_id) do
    case StateMonitor.ensure_started(tenant_id) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to start StateMonitor for tenant",
          tenant_id: tenant_id,
          reason: inspect(reason)
        )
    end
  end
end
