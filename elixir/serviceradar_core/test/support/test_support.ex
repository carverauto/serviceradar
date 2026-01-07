defmodule ServiceRadar.TestSupport do
  @moduledoc false

  def start_core! do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)

    if Process.whereis(ServiceRadar.Repo) do
      mode =
        case System.get_env("SERVICERADAR_TEST_SANDBOX_MODE") do
          "shared" -> {:shared, self()}
          "manual" -> :manual
          _ -> :auto
        end

      Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, mode)
    end

    :ok
  end
end
