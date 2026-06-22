defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadarWebNG.AshTestHelpers

  @repo ServiceRadar.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    seed_attributed_flow_rows!()
    on_exit(&delete_attributed_flow_rows_unboxed!/0)

    %{conn: log_in_user(conn, user)}
  end

  test "defaults to attributed rows and opens process details", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Attributed Flows"
    html = render_until(view, "10.42.10.12:53844", 5_000)

    assert html =~ "srql-query-bar"
    assert html =~ "Attributed Flow Records"
    assert html =~ "10.42.10.12:53844"
    assert html =~ "198.51.100.20:443"
    assert html =~ "default/nginx-pod"
    assert html =~ "1234"
    assert html =~ "nginx"
    assert html =~ "demo-context / default/nginx-pod"
    refute html =~ "203.0.113.44:62001"

    html = view |> element("#attributed-flows button", "nginx") |> render_click()

    assert html =~ "Flow Details"
    assert html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"
    assert html =~ "worker-1.example.test"
    assert html =~ "edge-api.example.test"
    assert html =~ "agent-flow-test-tcp"
    assert html =~ "Context"
    assert html =~ "demo-context"
    refute html =~ "cluster-demo-1"

    html = view |> element("button[aria-label='Close details']") |> render_click()

    refute html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"
  end

  test "renders unmatched rows through the explicit filter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{filter: "unmatched"}}")
    html = render_until(view, "203.0.113.44:62001", 5_000)

    assert html =~ "Unmatched Flow Records"
    assert html =~ "203.0.113.44:62001"
    assert html =~ "10.42.10.12:22"
    assert html =~ "No process match"
  end

  test "stat cards filter rows without losing LiveView context", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed")
    html = render_until(view, "nginx", 5_000)

    assert html =~ "nginx"
    refute html =~ "203.0.113.44:62001"

    _html =
      view
      |> element("button[phx-value-filter='unmatched']", "Unmatched")
      |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "unmatched", page: 1, per_page: 50}}")
    html = render_until(view, "203.0.113.44:62001", 5_000)
    assert html =~ "Unmatched Flow Records"
    assert html =~ "203.0.113.44:62001"
    refute html =~ "nginx #1234"

    _html =
      view
      |> element("button[phx-value-filter='all']", "Rows")
      |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "all", page: 1, per_page: 50}}")
    html = render_until(view, "nginx", 5_000)
    assert html =~ "All Flow Records"
    assert html =~ "203.0.113.44:62001"
    assert html =~ "nginx"
    assert html =~ "1234"
  end

  test "live toggle can be disabled and re-enabled", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Off"

    html = view |> element("button[phx-click='toggle_live']") |> render_click()

    assert html =~ "On"

    html = view |> element("button[phx-click='toggle_live']") |> render_click()

    assert html =~ "Off"
  end

  test "live toggle from a later page returns to the first page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{per_page: 1}}")
    render_until(view, "icmp-probe", 5_000)

    render_click(view, "goto_page", %{"page" => "2"})
    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 2, per_page: 1}}")
    render_until(view, "dns-client", 5_000)

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 1, per_page: 1}}")

    html = render_until(view, "icmp-probe", 5_000)
    assert html =~ "On"
    assert html =~ "Page 1 of 3"
    assert html =~ "icmp-probe"
    refute html =~ "dns-client"
  end

  test "pagination uses stable patch params and compact grid rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{per_page: 1}}")
    html = render_until(view, "icmp-probe", 5_000)

    assert html =~ "Page 1 of 3"
    assert html =~ "icmp-probe"
    refute html =~ "dns-client"

    render_click(view, "goto_page", %{"page" => "2"})

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 2, per_page: 1}}")
    html = render_until(view, "dns-client", 5_000)
    assert html =~ "Page 2 of 3"
    assert html =~ "dns-client"
    refute html =~ "icmp-probe"

    assert html =~ "lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1.35fr)_minmax(0,1.05fr)_minmax(0,.9fr)_minmax(0,.75fr)]"
    assert html =~ "truncate font-mono text-sm font-medium"
    refute html =~ "<table"
  end

  test "all rows render UDP and ICMP through SRQL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{filter: "all"}}")
    html = render_until(view, "TCP", 5_000)

    assert html =~ "TCP"
    assert html =~ "UDP"
    assert html =~ "ICMP"
    assert html =~ "metallb-system/speaker-bjd9k"
    refute html =~ "nil / metallb-system/speaker-bjd9k"
    assert html =~ "No IOC"
  end

  defp seed_attributed_flow_rows! do
    Sandbox.unboxed_run(@repo, fn ->
      delete_attributed_flow_rows!()

      now =
        DateTime.utc_now()
        |> DateTime.add(-60, :second)
        |> DateTime.truncate(:second)

      now
      |> DateTime.add(30, :second)
      |> insert_flow!(%{
        src_ip: "10.42.10.12",
        src_port: 8,
        dst_ip: "198.51.100.23",
        dst_port: nil,
        protocol_num: 1,
        protocol_name: "icmp",
        bytes: 96,
        packets: 2,
        attribution: %{
          "pid" => "3333",
          "comm" => "icmp-probe",
          "redacted_cmdline" => "/usr/bin/ping args:sha256:fc2b0c61",
          "uid" => "1000",
          "container_id" => "container-icmp"
        },
        agent_id: "agent-flow-test-icmp"
      })

      now
      |> DateTime.add(20, :second)
      |> insert_flow!(%{
        src_ip: "10.42.10.12",
        src_port: 53_211,
        dst_ip: "198.51.100.23",
        dst_port: 53,
        protocol_num: 17,
        protocol_name: "udp",
        bytes: 2_048,
        packets: 8,
        attribution: %{
          "pid" => "2222",
          "comm" => "dns-client",
          "redacted_cmdline" => "/usr/bin/dig args:sha256:765d0bcf",
          "uid" => "1000",
          "container_id" => "container-dns",
          "workload_identity" => %{
            "cluster_name" => "nil",
            "pod_namespace" => "metallb-system",
            "pod_name" => "speaker-bjd9k",
            "container_name" => "speaker",
            "image" => "quay.io/metallb/speaker:v0.15.2"
          }
        },
        agent_id: "agent-flow-test-udp"
      })

      now
      |> DateTime.add(10, :second)
      |> insert_flow!(%{
        src_ip: "10.42.10.12",
        src_port: 53_844,
        dst_ip: "198.51.100.20",
        dst_port: 443,
        protocol_num: 6,
        protocol_name: "tcp",
        bytes: 1_536,
        packets: 12,
        attribution: %{
          "pid" => "1234",
          "comm" => "nginx",
          "redacted_cmdline" => "/usr/sbin/nginx args:sha256:31f0e4c8",
          "uid" => "1000",
          "container_id" => "container-nginx",
          "workload_identity" => %{
            "context_name" => "demo-context",
            "cluster_id" => "cluster-demo-1",
            "cluster_name" => "demo-k3s",
            "pod_namespace" => "default",
            "pod_name" => "nginx-pod",
            "container_name" => "nginx",
            "image" => "nginx:latest"
          }
        },
        agent_id: "agent-flow-test-tcp"
      })

      now
      |> DateTime.add(5, :second)
      |> insert_flow!(%{
        src_ip: "203.0.113.44",
        src_port: 62_001,
        dst_ip: "10.42.10.12",
        dst_port: 22,
        protocol_num: 6,
        protocol_name: "tcp",
        bytes: 512,
        packets: 4,
        attribution: nil,
        agent_id: "agent-flow-test-unmatched"
      })

      upsert_rdns!("10.42.10.12", "worker-1.example.test", now)
      upsert_rdns!("198.51.100.20", "edge-api.example.test", now)
      upsert_rdns!("198.51.100.23", "dns-sinkhole.example.test", now)
      upsert_threat!("198.51.100.23", now)
    end)
  end

  defp delete_attributed_flow_rows_unboxed! do
    Sandbox.unboxed_run(@repo, fn ->
      delete_attributed_flow_rows!()
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

  defp insert_flow!(time, attrs) do
    payload =
      maybe_put_attribution(
        %{
          "event_type" => "attributed_flow",
          "agent_id" => attrs.agent_id,
          "partition" => "default",
          "test_suite" => "attributed_live_test"
        },
        attrs.attribution
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
      [
        time,
        attrs.src_ip,
        attrs.src_port,
        attrs.dst_ip,
        attrs.dst_port,
        attrs.protocol_num,
        attrs.protocol_name,
        attrs.bytes,
        attrs.packets,
        payload
      ]
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

  defp render_until(view, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    render_until(view, expected, deadline, nil)
  end

  defp render_until(view, expected, deadline, last_html) do
    html = render(view)

    cond do
      html =~ expected ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected rendered LiveView to include #{inspect(expected)}; last render:\n#{html || last_html}")

      true ->
        Process.sleep(50)
        render_until(view, expected, deadline, html)
    end
  end
end
