defmodule ServiceRadar.Inventory.Availability.Operator do
  @moduledoc """
  Support entry point for the merged availability deployment setting, usable from a
  running release or a release `eval`. It starts the repo when nothing has (`eval`) and
  reuses it when the application runs (`rpc`).

      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.transition_events(true)'

  `transition_events/1` turns the resolver's `device.*` events on or off for the
  deployment (`availability_settings.transition_events`, design Decision 8).
  """

  alias ServiceRadar.Repo

  @doc "Turns the resolver's `device.available` / `device.unavailable` events on or off."
  @spec transition_events(boolean()) :: :ok
  def transition_events(enabled?) when is_boolean(enabled?) do
    with_repo(fn ->
      Repo.query!(
        "UPDATE platform.availability_settings SET transition_events = $1 WHERE singleton",
        [enabled?]
      )

      IO.puts("availability transition events: #{enabled?}")
      :ok
    end)
  end

  defp with_repo(fun) do
    {:ok, result, _started} = Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end)
    result
  end
end
