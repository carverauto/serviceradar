defmodule ServiceRadar.NATS.Supervisor do
  @moduledoc """
  Supervisor for NATS connections.

  Wraps `Gnat.ConnectionSupervisor` to provide fault-tolerant NATS connections
  that automatically reconnect when the connection is lost.

  ## Why This Supervisor?

  When NATS connections die (e.g., during NATS server restarts), using
  `Gnat.start_link` directly can crash the parent process if `Process.unlink`
  doesn't happen before the exit signal arrives. `Gnat.ConnectionSupervisor`
  uses `trap_exit` to handle this properly.

  ## Usage

  Add to your supervision tree:

      {ServiceRadar.NATS.Supervisor, []}

  Then use `ServiceRadar.NATS.Connection` for publishing:

      ServiceRadar.NATS.Connection.publish("subject", "message")

  ## Configuration

  Configure in runtime.exs:

      config :serviceradar_core, ServiceRadar.NATS.Connection,
        host: "localhost",
        port: 4222,
        tls: true,
        creds_file: "/etc/serviceradar/creds/platform.creds"
  """

  use Supervisor

  require Logger

  @connection_name :serviceradar_nats
  @backoff_period 5_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the registered name of the NATS connection.
  """
  def connection_name, do: @connection_name

  @impl true
  def init(_opts) do
    config = Application.get_env(:serviceradar_core, ServiceRadar.NATS.Connection, [])
    _ = ensure_ssl_started(config)

    case build_connection_settings(config) do
      {:ok, connection_settings} ->
        gnat_supervisor_settings = %{
          name: @connection_name,
          backoff_period: Keyword.get(config, :backoff_period, @backoff_period),
          connection_settings: [connection_settings]
        }

        children = [
          {Gnat.ConnectionSupervisor, gnat_supervisor_settings}
        ]

        Logger.info("Starting NATS supervisor with connection name: #{@connection_name}")
        Supervisor.init(children, strategy: :one_for_one)

      {:error, reason} ->
        Logger.error("Failed to build NATS connection settings: #{inspect(reason)}")
        # Start with empty children - will not have NATS
        Supervisor.init([], strategy: :one_for_one)
    end
  end

  defp ensure_ssl_started(config) do
    tls = Keyword.get(config, :tls, false)

    if tls == true or is_list(tls) do
      case Application.ensure_all_started(:ssl) do
        {:ok, _} ->
          :ok

        {:error, {app, reason}} ->
          Logger.error("Failed to start #{app} for NATS TLS", reason: inspect(reason))
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp build_connection_settings(config) do
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port, 4222)
    tls = Keyword.get(config, :tls, false)
    creds_file = resolve_value(Keyword.get(config, :creds_file)) |> normalize()
    jwt = resolve_value(Keyword.get(config, :jwt)) |> normalize()
    nkey_seed = resolve_value(Keyword.get(config, :nkey_seed)) |> normalize()
    user = resolve_value(Keyword.get(config, :user))
    password = resolve_value(Keyword.get(config, :password))

    # Load credentials from file if provided
    {jwt, nkey_seed} = load_creds(creds_file, jwt, nkey_seed)

    settings = %{
      host: host,
      port: port
    }

    # Apply authentication
    settings =
      case apply_auth_settings(settings, jwt, nkey_seed, user, password) do
        {:ok, updated} -> updated
        {:error, _reason} = error -> error
      end

    case settings do
      {:error, _} = error ->
        error

      settings ->
        # Apply TLS settings
        settings = add_tls_settings(settings, tls)
        {:ok, settings}
    end
  end

  defp apply_auth_settings(settings, jwt, nkey_seed, user, password) do
    cond do
      nkey_seed != nil ->
        settings =
          settings
          |> Map.put(:nkey_seed, nkey_seed)
          |> Map.put(:auth_required, true)

        settings =
          if jwt != nil do
            Map.put(settings, :jwt, jwt)
          else
            settings
          end

        {:ok, settings}

      jwt != nil ->
        {:error, :missing_nkey_seed}

      user != nil ->
        {:ok, Map.merge(settings, %{user: user, password: password})}

      true ->
        {:ok, settings}
    end
  end

  defp add_tls_settings(settings, tls) do
    case tls do
      true ->
        Map.put(settings, :tls, true)

      tls_opts when is_list(tls_opts) ->
        settings
        |> Map.put(:tls, true)
        |> Map.put(:ssl_opts, tls_opts)

      _ ->
        settings
    end
  end

  defp load_creds(nil, jwt, nkey_seed), do: {jwt, nkey_seed}
  defp load_creds("", jwt, nkey_seed), do: {jwt, nkey_seed}

  defp load_creds(creds_file, jwt, nkey_seed) do
    case ServiceRadar.NATS.Creds.read(creds_file) do
      {:ok, creds} ->
        {creds.jwt, creds.nkey_seed}

      {:error, reason} ->
        Logger.warning("Failed to read NATS creds file #{creds_file}: #{inspect(reason)}")
        {jwt, nkey_seed}
    end
  end

  defp resolve_value({:system, env_var}), do: System.get_env(env_var)
  defp resolve_value(value), do: value

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value
end
