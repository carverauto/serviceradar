defmodule Mix.Tasks.Serviceradar.Proxmox.Smoke do
  @shortdoc "Smoke-test Proxmox API credentials from env vars"

  @moduledoc """
  Runs a direct Proxmox API smoke test from local environment variables.

      SERVICERADAR_PROXMOX_URL=https://pve.example:8006 \\
      SERVICERADAR_PROXMOX_API_TOKEN='root@pam!serviceradar=secret' \\
      SERVICERADAR_PROXMOX_INSECURE_SKIP_VERIFY=true \\
      mix serviceradar.proxmox.smoke
  """

  use Mix.Task

  alias ServiceRadar.Credentials.ProxmoxApiSmoke

  @impl Mix.Task
  def run(_args) do
    {:ok, _started} = Application.ensure_all_started(:req)

    with {:ok, config} <- ProxmoxApiSmoke.from_env(),
         {:ok, result} <- ProxmoxApiSmoke.run(config) do
      result
      |> Jason.encode!(pretty: true)
      |> Mix.shell().info()
    else
      {:error, {:missing_env, key}} ->
        Mix.raise("missing required environment variable #{key}")

      {:error, reason} ->
        Mix.raise("Proxmox API smoke test failed: #{inspect(reason)}")
    end
  end
end
