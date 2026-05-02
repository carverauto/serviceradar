defmodule ServiceRadarWebNGWeb.Plugs.RequireMigrationsTest do
  use ExUnit.Case, async: false
  use Phoenix.ConnTest

  alias ServiceRadarWebNGWeb.Plugs.RequireMigrations

  @cache_key {RequireMigrations, :status}

  setup do
    marker_path_env = System.get_env("SERVICERADAR_MIGRATIONS_MARKER_PATH")

    on_exit(fn -> :persistent_term.erase(@cache_key) end)

    on_exit(fn ->
      case marker_path_env do
        nil -> System.delete_env("SERVICERADAR_MIGRATIONS_MARKER_PATH")
        value -> System.put_env("SERVICERADAR_MIGRATIONS_MARKER_PATH", value)
      end
    end)

    :ok
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
end
