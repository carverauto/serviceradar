defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  @moduledoc """
  Attributed flows on an installation without the StarRocks warehouse.

  Flow attribution reads are warehouse-only: `in:attributed_flows` answers
  `{:error, :starrocks_required}` when StarRocks is disabled, and the page must
  render its honest empty state rather than crash or fall back to CNPG flow
  rows. Each test seeds a CNPG flow row (inside the sandbox) as a negative
  control that must never appear.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadarWebNG.AshTestHelpers

  @moduletag :web_ng_shared_fixture_db

  @repo ServiceRadar.Repo

  # Endpoints of the CNPG-only negative-control rows.
  @cnpg_attributed_endpoint "192.0.2.41:24001"
  @cnpg_unmatched_endpoint "192.0.2.43:24003"

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()
    seed_cnpg_flow_rows!()

    %{conn: log_in_user(conn, user)}
  end

  test "default view reports no attributed flows without the warehouse", %{conn: conn} do
    {view, _html, log} = live_settled(conn, ~p"/observability/flows/attributed")

    assert log =~ "Attributed flow SRQL rows query failed: :starrocks_required"
    assert log =~ "Attributed flow SRQL summary query failed: :starrocks_required"
    assert has_element?(view, "div", "No attributed flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_attributed_endpoint)
    refute has_element?(view, "#attributed-flows button")
  end

  test "unmatched filter shows its empty state, not CNPG rows", %{conn: conn} do
    {view, _html, log} = live_settled(conn, ~p"/observability/flows/attributed?#{%{filter: "unmatched"}}")

    assert log =~ ":starrocks_required"
    assert has_element?(view, "div", "No unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_unmatched_endpoint)
  end

  test "stat cards still switch filters without losing LiveView context", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed")
    settle(view)

    view
    |> element("button[phx-value-filter='unmatched']", "Unmatched")
    |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "unmatched", page: 1, per_page: 50}}")
    settle(view)
    assert has_element?(view, "div", "No unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_unmatched_endpoint)

    view
    |> element("button[phx-value-filter='all']", "Rows")
    |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "all", page: 1, per_page: 50}}")
    settle(view)
    assert has_element?(view, "div", "No attributed or unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows button")
  end

  test "live toggle can be disabled and re-enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed")
    settle(view)

    assert has_element?(view, "button[phx-click='toggle_live']", "Off")

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert has_element?(view, "button[phx-click='toggle_live']", "On")

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert has_element?(view, "button[phx-click='toggle_live']", "Off")
  end

  test "live toggle from a later page returns to the first page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{per_page: 1}}")
    settle(view)

    render_click(view, "goto_page", %{"page" => "2"})
    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 2, per_page: 1}}")
    settle(view)

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 1, per_page: 1}}")

    settle(view)
    assert has_element?(view, "button[phx-click='toggle_live']", "On")
    assert has_element?(view, "div", "Page 1 of 1.")
    refute has_element?(view, "#attributed-flows button")
  end

  test "all rows view renders no protocol rows from CNPG", %{conn: conn} do
    {view, _html, log} = live_settled(conn, ~p"/observability/flows/attributed?#{%{filter: "all"}}")

    assert log =~ ":starrocks_required"
    assert has_element?(view, "div", "No attributed or unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_attributed_endpoint)
    refute has_element?(view, "#attributed-flows", @cnpg_unmatched_endpoint)
    refute has_element?(view, "#attributed-flows button")
  end

  # Mounts the page and waits for its async flow load (start_async) to finish,
  # returning the rendered page and the warnings logged meanwhile. The capture
  # spans the mount because the load starts there. render_async/2 raises if the
  # LiveView crashed.
  defp live_settled(conn, path) do
    {{view, html}, log} =
      with_log([level: :warning], fn ->
        {:ok, view, _html} = live(conn, path)
        {view, render_async(view, 10_000)}
      end)

    {view, html, log}
  end

  # Waits for the async load started by the latest navigation; raises if the
  # LiveView crashed.
  defp settle(view), do: render_async(view, 10_000)

  # CNPG flow rows the page must never show: one attributed, one unmatched, one
  # with workload identity. They live in the test's sandbox transaction.
  defp seed_cnpg_flow_rows! do
    now = DateTime.utc_now() |> DateTime.shift(minute: -1) |> DateTime.truncate(:second)

    insert_flow!(now, %{
      src_ip: "192.0.2.41",
      src_port: 24_001,
      dst_ip: "198.51.100.60",
      dst_port: 8443,
      protocol_num: 6,
      protocol_name: "tcp",
      attribution: %{"pid" => "101", "comm" => "fixture-web"},
      agent_id: "fixture-agent-tcp"
    })

    insert_flow!(now, %{
      src_ip: "192.0.2.42",
      src_port: 24_002,
      dst_ip: "198.51.100.61",
      dst_port: 8125,
      protocol_num: 17,
      protocol_name: "udp",
      attribution: %{
        "pid" => "202",
        "comm" => "fixture-metrics",
        "workload_identity" => %{"pod_namespace" => "fixture-system", "pod_name" => "fixture-metrics-01"}
      },
      agent_id: "fixture-agent-udp"
    })

    insert_flow!(now, %{
      src_ip: "192.0.2.43",
      src_port: 24_003,
      dst_ip: "198.51.100.62",
      dst_port: 8080,
      protocol_num: 6,
      protocol_name: "tcp",
      attribution: nil,
      agent_id: "fixture-agent-unmatched"
    })
  end

  defp insert_flow!(time, attrs) do
    payload =
      maybe_put_attribution(
        %{"event_type" => "attributed_flow", "agent_id" => attrs.agent_id, "partition" => "default"},
        attrs.attribution
      )

    SQL.query!(
      @repo,
      """
      INSERT INTO platform.ocsf_network_activity (
        time, src_endpoint_ip, src_endpoint_port, dst_endpoint_ip, dst_endpoint_port,
        protocol_num, protocol_name, bytes_total, packets_total, ocsf_payload, partition, created_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, 1024, 8, $8::jsonb, 'default', $1)
      """,
      [
        time,
        attrs.src_ip,
        attrs.src_port,
        attrs.dst_ip,
        attrs.dst_port,
        attrs.protocol_num,
        attrs.protocol_name,
        payload
      ]
    )
  end

  defp maybe_put_attribution(payload, nil), do: payload
  defp maybe_put_attribution(payload, attribution), do: Map.put(payload, "attribution", attribution)
end
