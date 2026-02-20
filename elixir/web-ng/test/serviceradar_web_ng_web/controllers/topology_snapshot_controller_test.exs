defmodule ServiceRadarWebNGWeb.TopologySnapshotControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  setup :register_and_log_in_user

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    previous_gate_env = System.get_env("SERVICERADAR_MIGRATIONS_GATE")
    System.put_env("SERVICERADAR_MIGRATIONS_GATE", "false")

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)

      if is_nil(previous_gate_env) do
        System.delete_env("SERVICERADAR_MIGRATIONS_GATE")
      else
        System.put_env("SERVICERADAR_MIGRATIONS_GATE", previous_gate_env)
      end
    end)

    :ok
  end

  test "show returns binary snapshot and metadata headers when enabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    conn = get(conn, ~p"/topology/snapshot/latest")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/octet-stream"
    assert get_resp_header(conn, "x-sr-god-view-schema") != []
    assert get_resp_header(conn, "x-sr-god-view-revision") != []
    assert get_resp_header(conn, "x-sr-god-view-generated-at") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-root-bytes") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-affected-bytes") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-healthy-bytes") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-unknown-bytes") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-root-count") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-affected-count") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-healthy-count") != []
    assert get_resp_header(conn, "x-sr-god-view-bitmap-unknown-count") != []
    assert binary_part(conn.resp_body, 0, 6) == "ARROW1"
    assert binary_part(conn.resp_body, byte_size(conn.resp_body) - 6, 6) == "ARROW1"
  end

  test "show returns build failure payload when budget guard drops snapshot", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    original_budget = Application.get_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms)
    Application.put_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms, -1)

    on_exit(fn ->
      if is_nil(original_budget) do
        Application.delete_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms)
      else
        Application.put_env(:serviceradar_web_ng, :god_view_snapshot_budget_ms, original_budget)
      end
    end)

    conn = get(conn, ~p"/topology/snapshot/latest")
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 500
    assert body["error"] == "snapshot_build_failed"
    assert body["reason"] =~ "real_time_budget_exceeded"
  end
end
