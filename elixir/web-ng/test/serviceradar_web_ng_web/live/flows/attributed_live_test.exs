defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  @moduledoc """
  Attributed flows on an installation without the StarRocks warehouse, and the
  threat-intel context the page adds to warehouse rows.

  Flow attribution reads are warehouse-only: `in:attributed_flows` answers
  `{:error, :starrocks_required}` when StarRocks is disabled, and the page must
  render its honest empty state rather than crash. The `threat intel` tests
  stand in for the warehouse with `WarehouseSRQL`, because the IOC badge is
  computed from the live CNPG current-match cache after the rows arrive.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadarWebNG.AshTestHelpers

  @moduletag :web_ng_shared_fixture_db

  # Endpoints used as negative-control assertions.
  @cnpg_attributed_endpoint "192.0.2.41:24001"
  @cnpg_unmatched_endpoint "192.0.2.43:24003"

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

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

  describe "threat intel" do
    setup do
      previous = Application.get_env(:serviceradar_web_ng, :srql_module)
      Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.WarehouseSRQL)
      Application.put_env(:serviceradar_web_ng, __MODULE__.WarehouseSRQL, self())

      on_exit(fn ->
        Application.delete_env(:serviceradar_web_ng, __MODULE__.WarehouseSRQL)

        if previous,
          do: Application.put_env(:serviceradar_web_ng, :srql_module, previous),
          else: Application.delete_env(:serviceradar_web_ng, :srql_module)
      end)

      seed_cache!(__MODULE__.WarehouseSRQL.matched_ip(), matched: true, match_count: 2)
      seed_cache!(__MODULE__.WarehouseSRQL.unmatched_ip(), matched: false, match_count: 0)
      :ok
    end

    test "badges a flow whose endpoint is a current IOC match", %{conn: conn} do
      {view, _html, _log} = live_settled(conn, ~p"/observability/flows/attributed")

      assert has_element?(view, "#attributed-flows button", "IOC 2")
      assert has_element?(view, "#attributed-flows button", "No IOC")
    end

    test "IOC filter narrows rows and summary to current matches", %{conn: conn} do
      {view, _html, _log} = live_settled(conn, ~p"/observability/flows/attributed")
      flush_queries()

      view |> element("#attributed-ioc-filter") |> render_click()
      path = assert_patch(view)
      assert URI.decode_query(URI.parse(path).query)["q"] =~ "threat_matched:true"
      settle(view)

      queries = flush_queries()
      assert Enum.any?(queries, &(&1 =~ "stats:" and &1 =~ "threat_matched:true"))
      assert Enum.any?(queries, &(not (&1 =~ "stats:") and &1 =~ "threat_matched:true"))
      assert has_element?(view, "#attributed-ioc-filter[aria-pressed='true']")
    end
  end

  defp flush_queries(acc \\ []) do
    receive do
      {:warehouse_srql_query, query} -> flush_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seed_cache!(ip, attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    IpThreatIntelCache
    |> Ash.Changeset.for_create(:upsert, %{
      ip: ip,
      matched: Keyword.fetch!(attrs, :matched),
      match_count: Keyword.fetch!(attrs, :match_count),
      max_severity: 3,
      sources: ["synthetic_feed"],
      looked_up_at: now,
      expires_at: DateTime.shift(now, hour: 1)
    })
    |> Ash.create!(actor: SystemActor.system(:attributed_live_test))
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

  defmodule WarehouseSRQL do
    @moduledoc false
    # One IOC-matched and one unmatched attributed flow, as the warehouse returns them.

    def matched_ip, do: "192.0.2.77"
    def unmatched_ip, do: "198.51.100.78"

    def query(query, _opts) do
      case Application.get_env(:serviceradar_web_ng, __MODULE__) do
        pid when is_pid(pid) -> send(pid, {:warehouse_srql_query, query})
        _ -> :ok
      end

      if query =~ "stats:" do
        {:ok, %{"results" => [%{"attribution_status" => "attributed", "total" => 2, "total_bytes" => 3000}]}}
      else
        {:ok, %{"results" => [flow(matched_ip(), 4100), flow(unmatched_ip(), 4200)], "pagination" => %{}}}
      end
    end

    defp flow(src_ip, src_port) do
      %{
        "time" => "2026-01-01T00:00:00Z",
        "src_endpoint_ip" => src_ip,
        "src_endpoint_port" => src_port,
        "dst_endpoint_ip" => "203.0.113.9",
        "dst_endpoint_port" => 443,
        "protocol_num" => 6,
        "bytes_total" => 1500,
        "packets_total" => 3,
        "pid" => 4242,
        "comm" => "synthetic-proc",
        "attribution_status" => "attributed"
      }
    end
  end
end
