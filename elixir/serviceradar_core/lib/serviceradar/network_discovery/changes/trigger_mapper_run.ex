defmodule ServiceRadar.NetworkDiscovery.Changes.TriggerMapperRun do
  @moduledoc """
  Updates mapper job options to trigger an immediate run and invalidates mapper configs.
  """

  use Ash.Resource.Change

  alias ServiceRadar.AgentConfig.ConfigServer

  @impl true
  def change(changeset, _opts, _context) do
    run_now_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    options =
      Ash.Changeset.get_attribute(changeset, :options) ||
        Map.get(changeset.data, :options) || %{}

    updated_options = Map.put(options, "run_now_at", run_now_at)

    changeset
    |> Ash.Changeset.change_attribute(:options, updated_options)
    |> Ash.Changeset.after_action(fn _changeset, record ->
      ConfigServer.invalidate(:mapper)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
