defmodule Mix.Tasks.Serviceradar.MaybeTest do
  @shortdoc "Run DB-backed tests when the database is available"

  @moduledoc """
  Runs web-ng tests only when the database is reachable.
  """

  use Boundary,
    top_level?: true,
    check: [in: false, out: false]

  use Mix.Task

  def run(args) do
    if require_db_tests?() do
      repo_config = Application.get_env(:serviceradar_core, ServiceRadar.Repo, [])
      {hostname, port} = db_target(repo_config)
      run_db_tests(args, hostname, port)
    else
      Mix.shell().info("Skipping web-ng tests; set SERVICERADAR_REQUIRE_DB_TESTS=1 to enable")
    end
  end

  defp require_db_tests? do
    env_true?("SERVICERADAR_REQUIRE_DB_TESTS") or env_true?("CI")
  end

  defp env_true?(key) do
    System.get_env(key) in ["1", "true", "TRUE"]
  end

  defp run_db_tests(args, hostname, port) do
    if db_reachable?(hostname, port) do
      Mix.Task.run("app.start")
      maybe_migrate()
      Mix.Tasks.Test.run(args)
    else
      Mix.raise("Skipping web-ng tests; database unavailable at #{hostname}:#{port}")
    end
  end

  defp db_target(repo_config) do
    case {repo_config[:hostname], repo_config[:port]} do
      {host, port} when is_binary(host) and is_integer(port) ->
        {host, port}

      _ ->
        # When configured via `url: ...`, the hostname/port keys may not be present.
        # Parse them out so the reachability probe matches the actual connection target.
        case parse_db_target(repo_config[:url]) do
          {:ok, target} -> target
          :error -> {"localhost", 5432}
        end
    end
  end

  defp maybe_migrate do
    repo = ServiceRadar.Repo

    # Guard against partially migrated databases: legacy baseline tables can exist
    # while newer RBAC tables (like role_profiles) are still missing.
    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT to_regclass('platform.user_tokens'), to_regclass('platform.role_profiles'), pg_catalog.pg_is_in_recovery() = false AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper)",
           []
         ) do
      {:ok, %{rows: [[user_tokens, role_profiles, _can_migrate]]}}
      when not is_nil(user_tokens) and not is_nil(role_profiles) ->
        Mix.shell().info("Skipping ecto.migrate; schema already present")

      {:ok, %{rows: [[_user_tokens, _role_profiles, true]]}} ->
        Mix.Task.run("ecto.migrate", ["--quiet", "--prefix", "platform"])

      {:ok, %{rows: [[user_tokens, role_profiles, false]]}} ->
        Mix.shell().info(
          "Skipping ecto.migrate; schema incomplete but current DB user lacks migrate privileges " <>
            "(user_tokens=#{inspect(user_tokens)}, role_profiles=#{inspect(role_profiles)})"
        )

      {:error, reason} ->
        Mix.shell().info("Skipping ecto.migrate; probe failed: #{inspect(reason)}")
    end
  end

  defp db_reachable?(hostname, port) do
    host =
      case hostname do
        host when is_binary(host) -> String.to_charlist(host)
        host when is_list(host) -> host
        _ -> ~c"localhost"
      end

    case :gen_tcp.connect(host, port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp parse_db_target(url) when is_binary(url) do
    # Typical: ecto://USER:PASS@HOST:PORT/DB?sslmode=require
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        port = URI.parse(url).port || 5432
        {:ok, {host, port}}

      _ ->
        :error
    end
  end

  defp parse_db_target(_), do: :error
end
