defmodule ServiceRadarWebNGWeb.Plugs.RequireMigrationsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNGWeb.Plugs.RequireMigrations

  @moduletag :db_free
  @endpoint ServiceRadarWebNGWeb.Endpoint
  @cache_key {RequireMigrations, :status}

  setup do
    start_endpoint()

    marker_path_env = System.get_env("SERVICERADAR_MIGRATIONS_MARKER_PATH")
    gate_env = System.get_env("SERVICERADAR_MIGRATIONS_GATE")

    on_exit(fn -> :persistent_term.erase(@cache_key) end)

    on_exit(fn ->
      case marker_path_env do
        nil -> System.delete_env("SERVICERADAR_MIGRATIONS_MARKER_PATH")
        value -> System.put_env("SERVICERADAR_MIGRATIONS_MARKER_PATH", value)
      end
    end)

    on_exit(fn ->
      case gate_env do
        nil -> System.delete_env("SERVICERADAR_MIGRATIONS_GATE")
        value -> System.put_env("SERVICERADAR_MIGRATIONS_GATE", value)
      end
    end)

    :ok
  end

  defp start_endpoint do
    {:ok, _started_apps} = Application.ensure_all_started(:phoenix_pubsub)

    if Process.whereis(ServiceRadarWebNG.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: ServiceRadarWebNG.PubSub})
    end

    if Process.whereis(ServiceRadarWebNGWeb.Endpoint) == nil do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end
  end

  test "keeps the pending migrations banner for real pending migrations" do
    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), {:error, :pending_migrations}})

    conn = RequireMigrations.call(build_conn(), enabled: true)

    assert conn.halted
    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["5"]
    assert conn.resp_body == "ServiceRadar is starting up. Database migrations are still running."
  end

  test "returns a database connectivity message when the repo is unavailable" do
    :persistent_term.put(
      @cache_key,
      {System.monotonic_time(:millisecond), {:error, {:repo_unavailable, :repo_down}}}
    )

    conn = RequireMigrations.call(build_conn(), enabled: true)

    assert conn.halted
    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["5"]
    assert conn.resp_body == "ServiceRadar is temporarily unavailable. Database connectivity is degraded."
  end

  test "allows requests when the configured migrations marker exists" do
    marker = Path.join(System.tmp_dir!(), "serviceradar-migrations-#{System.unique_integer()}")
    File.write!(marker, "complete\n")
    System.put_env("SERVICERADAR_MIGRATIONS_MARKER_PATH", marker)
    :persistent_term.erase(@cache_key)

    conn = RequireMigrations.call(build_conn(), enabled: true)

    refute conn.halted

    File.rm(marker)
  end

  test "blocks requests when the configured migrations marker is missing" do
    marker = Path.join(System.tmp_dir!(), "serviceradar-migrations-missing-#{System.unique_integer()}")
    System.put_env("SERVICERADAR_MIGRATIONS_MARKER_PATH", marker)
    :persistent_term.erase(@cache_key)

    conn = RequireMigrations.call(build_conn(), enabled: true)

    assert conn.halted
    assert conn.status == 503
    assert conn.resp_body == "ServiceRadar is starting up. Database migrations are still running."
  end

  test "keeps liveness available while readiness is blocked by pending migrations" do
    System.put_env("SERVICERADAR_MIGRATIONS_GATE", "true")

    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), {:error, :pending_migrations}})

    liveness_conn = get(build_conn(), "/health/live")
    readiness_conn = get(build_conn(), "/health/ready")

    assert liveness_conn.status == 200
    assert liveness_conn.resp_body == "ok"
    assert readiness_conn.status == 503
    assert readiness_conn.resp_body == "ServiceRadar is starting up. Database migrations are still running."
  end
end
