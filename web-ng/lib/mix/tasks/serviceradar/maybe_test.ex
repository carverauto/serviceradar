defmodule Mix.Tasks.Serviceradar.MaybeTest do
  use Mix.Task

  @moduledoc """
  Runs web-ng tests only when the database is reachable.
  """

  @shortdoc "Run DB-backed tests when the database is available"

  def run(args) do
    run_db_tests? =
      System.get_env("SERVICERADAR_REQUIRE_DB_TESTS") in ["1", "true", "TRUE"] or
        System.get_env("CI") in ["1", "true", "TRUE"]

    if run_db_tests? do
      repo_config = Application.get_env(:serviceradar_core, ServiceRadar.Repo, [])

      {hostname, port} =
        case {repo_config[:hostname], repo_config[:port]} do
          {host, port} when is_binary(host) and is_integer(port) ->
            {host, port}

          _ ->
            # When configured via `url: ...`, the hostname/port keys may not be present.
            # Parse them out so the reachability probe matches the actual connection target.
            url = repo_config[:url]

            case parse_db_target(url) do
              {:ok, {host, port}} -> {host, port}
              :error -> {"localhost", 5432}
            end
        end

      if db_reachable?(hostname, port) do
        Mix.Task.run("app.start")
        maybe_migrate()
        Mix.Tasks.Test.run(args)
      else
        message =
          "Skipping web-ng tests; database unavailable at #{hostname}:#{port}"

        Mix.raise(message)
      end
    else
      Mix.shell().info("Skipping web-ng tests; set SERVICERADAR_REQUIRE_DB_TESTS=1 to enable")
    end
  end

  defp maybe_migrate do
    repo = ServiceRadar.Repo

    # All schema objects live under the platform schema. Migrations must run with `--prefix platform`
    # so Oban tables, constraints, etc. are created in the right namespace.
    case Ecto.Adapters.SQL.query(repo, "SELECT to_regclass('platform.user_tokens')", []) do
      {:ok, %{rows: [[nil]]}} ->
        Mix.Task.run("ecto.migrate", ["--quiet", "--prefix", "platform"])

      {:ok, _} ->
        Mix.shell().info("Skipping ecto.migrate; schema already present")

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
