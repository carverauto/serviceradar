defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompareTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: ServiceRadarWebNG.Accounts.Scope.for_user(user)
    }
  end

  test "today versus yesterday compares against yesterday's full day and links timeline buckets", %{conn: conn} do
    now = DateTime.utc_now()
    today_start = start_of_utc_day(now)
    yesterday_start = DateTime.add(today_start, -1, :day)

    {:ok, _view, html} = live(conn, ~p"/diagnostics/mtr/compare")

    assert html =~ "Today so far"
    assert html =~ "Yesterday full day"
    assert html =~ "#{format_time(yesterday_start)} to #{format_time(today_start)}"
    assert html =~ "Full-day baseline"
    assert html =~ "Compare same hours"
    assert html =~ "Deltas include different amounts of time"

    assert html =~ ~s(role="listitem")
    assert html =~ ~s(href="/diagnostics/mtr?)
    assert html =~ "sr-mtr-clickable-card"
    assert html =~ "sr-mtr-metric-link"
    assert html =~ "q=in%3Amtr_traces"
    assert html =~ "traces, 0 reached, 0 failed"
    assert html =~ "Destination Latency"
    assert html =~ "Destination Loss"
    refute html =~ "Last-Hop Latency"
    refute html =~ "Avg Hop Loss"
  end

  test "same-hours preset labels elapsed-aligned daily comparison", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/diagnostics/mtr/compare?preset=today_vs_yesterday_elapsed")

    assert html =~ "Today so far"
    assert html =~ "Yesterday same hours"
    assert html =~ "Elapsed-aligned comparison"
    assert html =~ "deltas are normalized by elapsed time"
    refute html =~ "Compare same hours"
  end

  test "aggregate cards and rows link to backing MTR evidence", %{conn: conn} do
    trace_id =
      insert_mtr_trace!("agent-ui", "203.0.113.55", ~U[2026-05-07 01:00:00Z],
        hops: [{"10.0.0.1", 10_000, 0.0}, {"203.0.113.55", 20_000, 0.0}]
      )

    insert_mtr_trace!("agent-ui", "203.0.113.55", ~U[2026-05-06 01:00:00Z],
      hops: [{"10.0.0.9", 10_000, 0.0}, {"203.0.113.55", 20_000, 0.0}]
    )

    {:ok, _view, html} =
      live(
        conn,
        ~p"/diagnostics/mtr/compare?mode=window&preset=custom&a_start=2026-05-07T00:00:00Z&a_end=2026-05-07T06:00:00Z&b_start=2026-05-06T00:00:00Z&b_end=2026-05-06T06:00:00Z"
      )

    assert html =~ "sr-mtr-clickable-card"
    assert html =~ "sr-mtr-metric-link"
    assert html =~ "Inspect representative trace"
    assert html =~ ~s(href="/diagnostics/mtr/#{trace_id}")
    assert html =~ "Compare only agent-ui"
    assert html =~ "View Window A traces for agent-ui"
    assert html =~ "View Window B traces for agent-ui"
  end

  test "window cards render unavailable destination values and deltas as dashes", %{conn: conn} do
    target = "203.0.113.77"

    insert_mtr_trace!("agent-unavailable", target, ~U[2026-05-07 01:00:00Z],
      target_reached: false,
      total_hops: 2,
      hops: [{"10.0.0.1", 900_000, 0.0}, {"10.0.0.2", 900_000, 0.0}]
    )

    insert_mtr_trace!("agent-unavailable", target, ~U[2026-05-06 01:00:00Z],
      target_reached: true,
      total_hops: 1,
      hops: [{target, 10_000, 0.0}]
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/diagnostics/mtr/compare?mode=window&preset=custom&a_start=2026-05-07T00:00:00Z&a_end=2026-05-07T06:00:00Z&b_start=2026-05-06T00:00:00Z&b_end=2026-05-06T06:00:00Z&target=#{target}"
      )

    for card_id <- ["mtr-compare-destination-latency", "mtr-compare-destination-loss"] do
      assert has_element?(view, "##{card_id} .sr-mtr-value", "-")
      assert has_element?(view, "##{card_id} .sr-mtr-metric-delta", "-")
    end
  end

  defp start_of_utc_day(%DateTime{} = dt) do
    dt
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp insert_mtr_trace!(agent_id, target_ip, timestamp, opts) do
    id = Ecto.UUID.generate()
    db_id = dump_uuid!(id)
    hops = Keyword.get(opts, :hops, [])

    ServiceRadar.Repo.insert_all("mtr_traces", [
      %{
        id: db_id,
        time: timestamp,
        agent_id: agent_id,
        gateway_id: "gateway-test",
        check_id: "check-#{id}",
        check_name: "MTR #{target_ip}",
        device_id: nil,
        target: target_ip,
        target_ip: target_ip,
        target_reached: Keyword.get(opts, :target_reached, true),
        total_hops: Keyword.get(opts, :total_hops, length(hops)),
        protocol: Keyword.get(opts, :protocol, "icmp"),
        ip_version: 4,
        packet_size: 64,
        partition: "default",
        error: nil,
        created_at: timestamp
      }
    ])

    insert_mtr_hops!(id, timestamp, hops)

    id
  end

  defp insert_mtr_hops!(_trace_id, _timestamp, []), do: :ok

  defp insert_mtr_hops!(trace_id, timestamp, hops) do
    trace_db_id = dump_uuid!(trace_id)

    rows =
      hops
      |> Enum.with_index(1)
      |> Enum.map(fn {{addr, avg_us, loss_pct}, hop_number} ->
        %{
          id: dump_uuid!(Ecto.UUID.generate()),
          time: timestamp,
          trace_id: trace_db_id,
          hop_number: hop_number,
          addr: addr,
          hostname: nil,
          ecmp_addrs: [],
          asn: nil,
          asn_org: nil,
          mpls_labels: %{},
          sent: 10,
          received: if(loss_pct >= 100.0, do: 0, else: 10),
          loss_pct: loss_pct,
          last_us: avg_us,
          avg_us: avg_us,
          min_us: avg_us,
          max_us: avg_us,
          stddev_us: 0,
          jitter_us: 0,
          jitter_worst_us: 0,
          jitter_interarrival_us: 0,
          created_at: timestamp
        }
      end)

    ServiceRadar.Repo.insert_all("mtr_hops", rows)
    :ok
  end

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> uuid
    end
  end
end
