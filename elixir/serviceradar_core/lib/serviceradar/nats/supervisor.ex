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
  Returns the registered name of the SHARED NATS connection.
  """
  def connection_name, do: @connection_name

  @doc """
  The connections this supervisor starts: the shared one, and only that.

  The edge publisher connections deliberately do NOT live here. They were briefly started
  alongside this one, which meant every process that enables NATS -- core and web-ng among them,
  and core's Helm chart enables it -- opened three extra sockets it had no pool for and never
  published on. Pairing them with the pools instead makes "one connection per lane, owned with
  its window" true by construction rather than by two supervisors agreeing.

  See `ServiceRadar.Edge.PublisherSupervisor`.
  """
  def connection_names, do: [@connection_name]

  @doc """
  Builds the Gnat connection settings from application config.

  Public because `ServiceRadar.Edge.PublisherSupervisor` needs the SAME settings for its lane
  connections -- host, auth, creds and TLS are properties of the deployment, not of a lane. A
  second derivation would be a second place for the fixture credentials or TLS options to drift.
  """
  @spec connection_settings() :: {:ok, map(), non_neg_integer()} | {:error, term()}
  def connection_settings do
    config = Application.get_env(:serviceradar_core, ServiceRadar.NATS.Connection, [])
    _ = ensure_ssl_started(config)

    case build_connection_settings(config) do
      {:ok, settings} -> {:ok, settings, Keyword.get(config, :backoff_period, @backoff_period)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One `Gnat.ConnectionSupervisor` child spec per name.

  Public so ID UNIQUENESS can be tested without a NATS server, and shared with
  `PublisherSupervisor` so both build their connections the same way.
  `Gnat.ConnectionSupervisor`'s default child id is the MODULE, so N of them under one supervisor
  collide on id and `Supervisor.init/2` starts only the first -- silently, because the first one
  works. The registered name is unique already, so it is the id.
  """
  def child_specs(names, connection_settings, backoff_period) do
    Enum.map(names, fn name ->
      Supervisor.child_spec(
        {Gnat.ConnectionSupervisor,
         %{
           name: name,
           backoff_period: backoff_period,
           connection_settings: [connection_settings]
         }},
        id: name
      )
    end)
  end

  @impl true
  def init(_opts) do
    case connection_settings() do
      {:ok, settings, backoff_period} ->
        children = child_specs(connection_names(), settings, backoff_period)

        Logger.info("Starting NATS supervisor with connections: #{inspect(connection_names())}")
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
    creds_file = config |> Keyword.get(:creds_file) |> resolve_value() |> normalize()
    jwt = config |> Keyword.get(:jwt) |> resolve_value() |> normalize()
    nkey_seed = config |> Keyword.get(:nkey_seed) |> resolve_value() |> normalize()
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
          if jwt == nil do
            settings
          else
            Map.put(settings, :jwt, jwt)
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
