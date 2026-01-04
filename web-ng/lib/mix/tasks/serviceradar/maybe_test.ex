defmodule Mix.Tasks.Serviceradar.MaybeTest do
  use Mix.Task

  @moduledoc """
  Runs web-ng tests only when the database is reachable.
  """

  @shortdoc "Run DB-backed tests when the database is available"

  def run(args) do
    require_db? =
      System.get_env("SERVICERADAR_REQUIRE_DB_TESTS") in ["1", "true", "TRUE"] or
        System.get_env("CI") in ["1", "true", "TRUE"]

    repo_config = Application.get_env(:serviceradar_core, ServiceRadar.Repo, [])
    hostname = repo_config[:hostname] || "localhost"
    port = repo_config[:port] || 5432

    if db_reachable?(hostname, port) do
      Mix.Task.run("app.start")
      Mix.Task.run("ecto.migrate", ["--quiet"])
      Mix.Tasks.Test.run(args)
    else
      message =
        "Skipping web-ng tests; database unavailable at #{hostname}:#{port}"

      if require_db? do
        Mix.raise(message)
      else
        Mix.shell().info(message)
      end
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
end
