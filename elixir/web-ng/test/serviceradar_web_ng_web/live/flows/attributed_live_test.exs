defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadarWebNG.AshTestHelpers

  @repo ServiceRadar.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    seed_attributed_flow_rows!()
    on_exit(&delete_attributed_flow_rows!/0)

    %{conn: log_in_user(conn, user)}
  end

  test "defaults to attributed rows and opens process details", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Attributed Flows"
    html = render(view)

    assert html =~ "srql-query-bar"
    assert html =~ "Attributed Flow Records"
    assert html =~ "10.42.10.12:53844"
    assert html =~ "198.51.100.20:443"
    assert html =~ "agent-flow-test-tcp"
    assert html =~ "default/nginx-pod"
    assert html =~ "1234"
    assert html =~ "nginx"
    refute html =~ "203.0.113.44:62001"

    html = view |> element("#attributed-flows button", "nginx") |> render_click()

    assert html =~ "Flow Details"
    assert html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"

    html = view |> element("button[aria-label='Close details']") |> render_click()

    refute html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"
  end

  test "renders unmatched rows through the explicit filter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{filter: "unmatched"}}")
    html = render(view)

    assert html =~ "Unmatched Flow Records"
    assert html =~ "203.0.113.44:62001"
    assert html =~ "10.42.10.12:22"
    assert html =~ "No process match"
  end

  test "stat cards filter rows without losing LiveView context", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed")
    html = render(view)

    assert html =~ "nginx"
    refute html =~ "203.0.113.44:62001"

    html =
      view
      |> element("button[phx-value-filter='unmatched']", "Unmatched")
      |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "unmatched", page: 1, per_page: 50}}")
    assert html =~ "Unmatched Flow Records"
    assert html =~ "203.0.113.44:62001"
    refute html =~ "nginx #1234"

    html =
      view
      |> element("button[phx-value-filter='all']", "Rows")
      |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "all", page: 1, per_page: 50}}")
    assert html =~ "All Flow Records"
    assert html =~ "203.0.113.44:62001"
    assert html =~ "nginx #1234"
  end

  test "live toggle can be disabled and re-enabled", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Off"

    html = view |> element("button[phx-click='toggle_live']") |> render_click()

    assert html =~ "On"

    html = view |> element("button[phx-click='toggle_live']") |> render_click()

    assert html =~ "Off"
  end

  test "pagination uses stable patch params and compact grid rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{per_page: 1}}")
    html = render(view)

    assert html =~ "Page 1 of 3"
    assert html =~ "icmp-probe"
    refute html =~ "dns-client"

    html = render_click(view, "goto_page", %{"page" => "2"})

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 2, per_page: 1}}")
    assert html =~ "Page 2 of 3"
    assert html =~ "dns-client"
    refute html =~ "icmp-probe"

    assert html =~ "lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1.35fr)_minmax(0,1.05fr)_minmax(0,.9fr)_minmax(0,.75fr)]"
    assert html =~ "truncate font-mono text-sm font-medium"
    refute html =~ "<table"
  end

  test "all rows render UDP and ICMP through SRQL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{filter: "all"}}")
    html = render(view)

    assert html =~ "TCP"
    assert html =~ "UDP"
    assert html =~ "ICMP"
    assert html =~ "No IOC"
  end

  defp seed_attributed_flow_rows! do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(@repo, fn ->
      delete_attributed_flow_rows!()

      now = DateTime.truncate(DateTime.utc_now(), :second)

      now
      |> DateTime.add(30, :second)
      |> insert_flow!(
        "10.42.10.12",
        8,
        "198.51.100.23",
        nil,
        1,
        "icmp",
        96,
        2,
        %{
          "pid" => "3333",
          "comm" => "icmp-probe",
          "redacted_cmdline" => "/usr/bin/ping args:sha256:fc2b0c61",
          "uid" => "1000",
          "container_id" => "container-icmp"
        },
        "agent-flow-test-icmp"
      )

      now
      |> DateTime.add(20, :second)
      |> insert_flow!(
        "10.42.10.12",
        53_211,
        "198.51.100.23",
        53,
        17,
        "udp",
        2_048,
        8,
        %{
          "pid" => "2222",
          "comm" => "dns-client",
          "redacted_cmdline" => "/usr/bin/dig args:sha256:765d0bcf",
          "uid" => "1000",
          "container_id" => "container-dns"
        },
        "agent-flow-test-udp"
      )

      now
      |> DateTime.add(10, :second)
      |> insert_flow!(
        "10.42.10.12",
        53_844,
        "198.51.100.20",
        443,
        6,
        "tcp",
        1_536,
        12,
        %{
          "pid" => "1234",
          "comm" => "nginx",
          "redacted_cmdline" => "/usr/sbin/nginx args:sha256:31f0e4c8",
          "uid" => "1000",
          "container_id" => "container-nginx",
          "workload_identity" => %{
            "pod_namespace" => "default",
            "pod_name" => "nginx-pod",
            "container_name" => "nginx",
            "image" => "nginx:latest"
          }
        },
        "agent-flow-test-tcp"
      )

      now
      |> DateTime.add(5, :second)
      |> insert_flow!(
        "203.0.113.44",
        62_001,
        "10.42.10.12",
        22,
        6,
        "tcp",
        512,
        4,
        nil,
        "agent-flow-test-unmatched"
      )

      upsert_rdns!("10.42.10.12", "worker-1.example.test", now)
      upsert_rdns!("198.51.100.20", "edge-api.example.test", now)
      upsert_rdns!("198.51.100.23", "dns-sinkhole.example.test", now)
      upsert_threat!("198.51.100.23", now)
    end)
  end

  defp delete_attributed_flow_rows! do
    SQL.query!(
      @repo,
      """
      DELETE FROM platform.ocsf_network_activity
      WHERE ocsf_payload ->> 'test_suite' = 'attributed_live_test'
         OR ocsf_payload::text LIKE '%attributed_live_test%'
      """,
      []
    )
  end

  defp insert_flow!(
         time,
         src_ip,
         src_port,
         dst_ip,
         dst_port,
         protocol_num,
         protocol_name,
         bytes,
         packets,
         attribution,
         agent_id
       ) do
    payload =
      maybe_put_attribution(
        %{
          "event_type" => "attributed_flow",
          "agent_id" => agent_id,
          "partition" => "default",
          "test_suite" => "attributed_live_test"
        },
        attribution
      )

    SQL.query!(
      @repo,
      """
      INSERT INTO platform.ocsf_network_activity (
        time,
        src_endpoint_ip,
        src_endpoint_port,
        dst_endpoint_ip,
        dst_endpoint_port,
        protocol_num,
        protocol_name,
        bytes_total,
        packets_total,
        ocsf_payload,
        partition,
        created_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, 'default', $1)
      """,
      [time, src_ip, src_port, dst_ip, dst_port, protocol_num, protocol_name, bytes, packets, payload]
    )
  end

  defp maybe_put_attribution(payload, nil), do: payload
  defp maybe_put_attribution(payload, attribution), do: Map.put(payload, "attribution", attribution)

  defp upsert_rdns!(ip, hostname, now) do
    SQL.query!(
      @repo,
      """
      INSERT INTO platform.ip_rdns_cache (
        ip,
        hostname,
        status,
        looked_up_at,
        expires_at,
        inserted_at,
        updated_at
      )
      VALUES ($1, $2, 'ok', $3, $4, $3, $3)
      ON CONFLICT (ip) DO UPDATE SET
        hostname = EXCLUDED.hostname,
        status = EXCLUDED.status,
        looked_up_at = EXCLUDED.looked_up_at,
        expires_at = EXCLUDED.expires_at,
        updated_at = EXCLUDED.updated_at
      """,
      [ip, hostname, now, DateTime.add(now, 3600, :second)]
    )
  end

  defp upsert_threat!(ip, now) do
    SQL.query!(
      @repo,
      """
      INSERT INTO platform.ip_threat_intel_cache (
        ip,
        matched,
        match_count,
        max_severity,
        sources,
        looked_up_at,
        expires_at,
        inserted_at,
        updated_at
      )
      VALUES ($1, true, 2, 5, $2, $3, $4, $3, $3)
      ON CONFLICT (ip) DO UPDATE SET
        matched = EXCLUDED.matched,
        match_count = EXCLUDED.match_count,
        max_severity = EXCLUDED.max_severity,
        sources = EXCLUDED.sources,
        looked_up_at = EXCLUDED.looked_up_at,
        expires_at = EXCLUDED.expires_at,
        updated_at = EXCLUDED.updated_at
      """,
      [ip, ["alienvault_otx"], now, DateTime.add(now, 3600, :second)]
    )
  end
end
