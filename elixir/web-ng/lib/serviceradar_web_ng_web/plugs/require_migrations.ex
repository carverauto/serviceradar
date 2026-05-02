defmodule ServiceRadarWebNGWeb.Plugs.RequireMigrations do
  @moduledoc """
  Blocks requests until database migrations are applied.

  This prevents the UI from querying missing tables/views during startup.
  """

  import Plug.Conn

  require Logger

  @cache_key {__MODULE__, :status}
  @default_cache_ttl_ms 5_000

  def init(opts), do: opts

  def call(conn, opts) do
    if enabled?(opts) do
      case cached_status(opts) do
        :ok ->
          conn

        {:error, reason} ->
          Logger.debug("[MigrationsGate] Blocking request: #{inspect(reason)}")

          conn
          |> put_resp_content_type("text/plain")
          |> put_resp_header("retry-after", "5")
          |> send_resp(503, response_message(reason))
          |> halt()
      end
    else
      conn
    end
  end

  defp enabled?(opts) do
    Keyword.get(opts, :enabled, env_enabled?())
  end

  defp env_enabled? do
    case System.get_env("SERVICERADAR_MIGRATIONS_GATE", "true") do
      "false" -> false
      "0" -> false
      _ -> true
    end
  end

  defp cached_status(opts) do
    ttl = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {timestamp, status} when now - timestamp < ttl ->
        status

      _ ->
        status = migrations_ready?()
        :persistent_term.put(@cache_key, {now, status})
        status
    end
  end

  defp response_message(:pending_migrations) do
    "ServiceRadar is starting up. Database migrations are still running."
  end

  defp response_message({:repo_unavailable, _reason}) do
    "ServiceRadar is temporarily unavailable. Database connectivity is degraded."
  end

  defp response_message(_reason) do
    "ServiceRadar is temporarily unavailable. Database connectivity is degraded."
  end

  defp migrations_ready? do
    case migration_marker_status() do
      :ok ->
        :ok

      {:error, :pending_migrations} ->
        {:error, :pending_migrations}

      :unknown ->
        repo_migrations_ready?()
    end
  end

  defp migration_marker_status do
    case System.get_env("SERVICERADAR_MIGRATIONS_MARKER_PATH") do
      nil ->
        :unknown

      "" ->
        :unknown

      path ->
        if File.regular?(path), do: :ok, else: {:error, :pending_migrations}
    end
  end

  defp repo_migrations_ready? do
    case Process.whereis(ServiceRadar.Repo) do
      nil ->
        {:error, {:repo_unavailable, :repo_down}}

      _pid ->
        migrations_path = Application.app_dir(:serviceradar_core, "priv/repo/migrations")
        opts = [prefix: "platform"]

        try do
          migrations = Ecto.Migrator.migrations(ServiceRadar.Repo, migrations_path, opts)

          pending =
            Enum.any?(migrations, fn
              %{status: :down} -> true
              {:down, _, _} -> true
              {:down, _, _, _} -> true
              _ -> false
            end)

          if pending, do: {:error, :pending_migrations}, else: :ok
        rescue
          error in [DBConnection.ConnectionError, Postgrex.Error] ->
            {:error, {:repo_unavailable, error}}
        end
    end
  end
end
