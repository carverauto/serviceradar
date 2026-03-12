defmodule ServiceRadar.TestSupport do
  @moduledoc """
  Test support utilities for ServiceRadar Core.

  In the single-deployment architecture, each deployment is single-deployment.
  The PostgreSQL search_path (set by CNPG credentials) determines the schema.
  """

  def start_core! do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    ensure_repo_started!()

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

  defp ensure_repo_started! do
    repo_enabled? = Application.get_env(:serviceradar_core, :repo_enabled, true) != false

    if repo_enabled? and is_nil(Process.whereis(ServiceRadar.Repo)) do
      case ServiceRadar.Repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end
  end
end
