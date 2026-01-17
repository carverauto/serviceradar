defmodule ServiceRadar.Infrastructure.Changes.EnsureStateMonitor do
  @moduledoc """
  Ash change that ensures the StateMonitor is running.

  When infrastructure resources (gateways, agents, checkers) are created,
  this change ensures that the StateMonitor GenServer is running to
  monitor their health.

  In schema-agnostic mode, the StateMonitor is started as a singleton by
  the application supervisor. This change just verifies it's running.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Infrastructure.StateMonitor

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      ensure_state_monitor_running()
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp ensure_state_monitor_running do
    # In schema-agnostic mode, StateMonitor is a singleton started by the supervisor
    case StateMonitor.whereis() do
      nil ->
        Logger.warning("StateMonitor is not running - infrastructure monitoring may be degraded")

      _pid ->
        :ok
    end
  end
end
