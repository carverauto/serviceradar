defmodule ServiceRadar.TestSupport do
  @moduledoc false

  def start_core! do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)

    if Process.whereis(ServiceRadar.Repo) do
      Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :auto)
    end

    :ok
  end
end
