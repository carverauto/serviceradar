defmodule ServiceRadarWebNGWeb.Plugs.RequireMigrationsTest do
  use ExUnit.Case, async: false
  use Phoenix.ConnTest

  alias ServiceRadarWebNGWeb.Plugs.RequireMigrations

  @cache_key {RequireMigrations, :status}

  setup do
    on_exit(fn -> :persistent_term.erase(@cache_key) end)
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
end
