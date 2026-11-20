defmodule ServiceRadarWebNGWeb.ServiceLive.ChecksTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Router
  alias ServiceRadarWebNGWeb.ServiceLive.Checks
  alias ServiceRadarWebNGWeb.ServiceLive.Index.View, as: ServiceIndexView

  @moduletag :db_free

  @user_uuid "00000000-0000-4000-8000-000000000901"

  defmodule StubChecksSRQL do
    @moduledoc false

    def query(query, opts) do
      if pid = Application.get_env(:serviceradar_web_ng, :service_checks_srql_test_pid) do
        send(pid, {:service_checks_srql_query, query, opts})
      end

      cond do
        String.contains?(query, "stats:") ->
          {:ok,
           %{
             "results" => [
               %{"status" => "healthy", "total" => 12},
               %{"status" => "degraded", "total" => 3},
               %{"status" => "down", "total" => 1},
               %{"status" => "unknown", "total" => 2}
             ],
             "pagination" => %{}
           }}

        String.contains?(query, "verdict:none_matched") ->
          {:ok, %{"results" => [], "pagination" => %{}}}

        true ->
          {:ok,
           %{
             "results" => [
               %{
                 "id" => "00000000-0000-4000-8000-000000000911",
                 "check_id" => "00000000-0000-4000-8000-000000000910",
                 "check_slug" => "checkout-api-health",
                 "check_name" => "Synthetic Checkout API Health",
                 "state" => "enabled",
                 "target_key" => "singleton",
                 "target_kind" => "singleton",
                 "verdict" => "ok",
                 "status" => "healthy",
                 "summary" => "GET https://api.example.com/healthz returned 200 in 42ms",
                 "node_snapshots" => %{
                   "http_1" => %{"status_code" => 200, "latency_ms" => 42}
                 },
                 "evaluated_at" => "2026-11-18T12:00:00Z",
                 "changed_at" => "2026-11-18T11:30:00Z"
               },
               %{
                 "id" => "00000000-0000-4000-8000-000000000912",
                 "check_id" => "00000000-0000-4000-8000-000000000910",
                 "check_slug" => "storage-entitlement-utilization",
                 "check_name" => "Storage Entitlement Utilization",
                 "state" => "enabled",
                 "target_key" => "device:sr:synthetic-edge-01",
                 "target_kind" => "device",
                 "device_uid" => "sr:synthetic-edge-01",
                 "verdict" => "cap_exceeded",
                 "status" => "down",
                 "summary" => "Storage entitlement exceeded 95% threshold",
                 "node_snapshots" => %{
                   "posture_1" => %{"utilization_pct" => 97.4}
                 },
                 "evaluated_at" => "2026-11-18T12:05:00Z",
                 "changed_at" => "2026-11-18T12:05:00Z"
               }
             ],
             "pagination" => %{"next_cursor" => "cursor-next-1", "prev_cursor" => nil}
           }}
      end
    end
  end

  setup do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    prev_srql = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, StubChecksSRQL)
    Application.put_env(:serviceradar_web_ng, :service_checks_srql_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :service_checks_srql_test_pid)

      if prev_srql do
        Application.put_env(:serviceradar_web_ng, :srql_module, prev_srql)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    :ok
  end

  describe "router wiring and RBAC" do
    test "resolves /services/checks to ServiceLive.Checks" do
      assert %{phoenix_live_view: {Checks, :index, _, _}} =
               Phoenix.Router.route_info(Router, "GET", "/services/checks", "localhost")
    end

    test "denies users lacking declarative_checks.* permissions" do
      unpermitted = scope_with_permissions(["devices.view"])

      assert {:ok, redirected} = Checks.mount(%{}, %{}, base_socket(unpermitted))
      assert {:live, :redirect, %{to: "/services"}} = redirected.redirected
      assert Phoenix.Flash.get(redirected.assigns.flash, :error) =~ "Not authorized"
    end

    test "disconnected mount and handle_params execute zero SRQL queries" do
      viewer = scope_with_permissions(["declarative_checks.view"])

      assert {:ok, mounted} = Checks.mount(%{}, %{}, base_socket(viewer))

      assert {:noreply, after_params} =
               Checks.handle_params(
                 %{"q" => "in:declarative_check_results limit:50"},
                 "https://example.test/services/checks?q=in%3Adeclarative_check_results+limit%3A50",
                 mounted
               )

      refute_received {:service_checks_srql_query, _, _}
      assert after_params.assigns.srql.loading == true
      assert render_checks(after_params) =~ "Loading check results..."
    end
  end

  describe "Check Results Explorer rendering and interactions" do
    test "renders KPI cards, quick filter pills, live results table, slug links, and expandable output details" do
      viewer = scope_with_permissions(["declarative_checks.view"])
      query = "in:declarative_check_results limit:50"

      socket = mount_connected(viewer, %{"q" => query})

      assert_received {:service_checks_srql_query, ^query, %{limit: 50}}

      assert_received {:service_checks_srql_query, "in:declarative_check_results stats:count() as total by status", _}

      assert socket.assigns.status_summary == %{
               "healthy" => 12,
               "degraded" => 3,
               "down" => 1,
               "unknown" => 2
             }

      html = render_checks(socket)
      assert html =~ "check-results-kpi-cards"
      assert html =~ "check-results-kpi-healthy"
      assert html =~ "check-results-kpi-degraded"
      assert html =~ "check-results-kpi-down"
      assert html =~ "check-results-kpi-unknown"
      assert html =~ "check-results-pill-all"
      assert html =~ "check-results-pill-failing"
      assert html =~ "check-results-pill-healthy"
      assert html =~ "check-results-table"
      assert html =~ "/settings/declarative-checks/checkout-api-health"
      assert html =~ "/settings/declarative-checks/storage-entitlement-utilization"
      assert html =~ "device:sr:synthetic-edge-01"
      assert html =~ "cap_exceeded"
      assert html =~ ~s(data-status="healthy")
      assert html =~ ~s(data-status="down")
      assert html =~ "2026-11-18T12:00:00Z"
      assert html =~ "cursor-next-1"
      refute html =~ "check-result-details-0"

      {:noreply, expanded} =
        Checks.handle_event(
          "toggle_row_details",
          %{"row_key" => "00000000-0000-4000-8000-000000000912"},
          socket
        )

      expanded_html = render_checks(expanded)
      assert expanded_html =~ "check-result-details-1"
      assert expanded_html =~ "Storage entitlement exceeded 95% threshold"
      assert expanded_html =~ "/devices/sr%3Asynthetic-edge-01"
      assert expanded_html =~ "97.4"

      {:noreply, collapsed} =
        Checks.handle_event(
          "toggle_row_details",
          %{"row_key" => "00000000-0000-4000-8000-000000000912"},
          expanded
        )

      refute render_checks(collapsed) =~ "check-result-details-1"
    end

    test "renders stats cards and summary table for stats: queries and empty callout when zero rows match" do
      viewer = scope_with_permissions(["declarative_checks.view"])
      stats_query = "in:declarative_check_results stats:count() as total by status"

      stats_socket = mount_connected(viewer, %{"q" => stats_query})
      assert stats_socket.assigns.stats_mode?

      stats_html = render_checks(stats_socket)
      assert stats_html =~ "check-results-stats-cards"
      assert stats_html =~ "check-results-stats-table"
      assert stats_html =~ ~r/>\s*12\s*</

      empty_query = "in:declarative_check_results verdict:none_matched limit:50"

      {:noreply, empty_socket} =
        Checks.handle_params(
          %{"q" => empty_query},
          "https://example.test/services/checks?q=#{URI.encode_www_form(empty_query)}",
          stats_socket
        )

      assert render_checks(empty_socket) =~ "check-results-empty"
    end

    test "srql_submit patches /services/checks for declarative check aliases and srql_paginate advances page" do
      viewer = scope_with_permissions(["declarative_checks.view"])
      socket = mount_connected(viewer, %{})

      {:noreply, patched} =
        Checks.handle_event(
          "srql_submit",
          %{"q" => "in:declarative_verdicts status:degraded limit:25"},
          socket
        )

      assert {:live, :patch, %{to: patch_to}} = patched.redirected
      patch_uri = URI.parse(patch_to)
      assert patch_uri.path == "/services/checks"

      assert URI.decode_query(patch_uri.query || "")["q"] ==
               "in:declarative_verdicts status:degraded limit:25"

      {:noreply, navigated} =
        Checks.handle_event("srql_submit", %{"q" => "in:devices limit:20"}, socket)

      assert {:live, :redirect, %{to: nav_to}} = navigated.redirected
      assert URI.parse(nav_to).path == "/devices"

      {:noreply, paginated} =
        Checks.handle_event(
          "srql_paginate",
          %{"cursor" => "cursor-next-1", "page" => "2"},
          socket
        )

      assert paginated.assigns.pagination_page == 2
    end

    test "/services view renders navigation link to /services/checks" do
      viewer = scope_with_permissions(["declarative_checks.view"])

      html =
        %{
          __changed__: %{},
          flash: %{},
          current_scope: viewer,
          srql: %{enabled: true, query: "in:services limit:50"},
          plugin_source: :empty,
          tab_loading: false,
          summary: %{
            total: 0,
            available: 0,
            unavailable: 0,
            by_check: %{},
            check_count: 0,
            last_updated: nil
          },
          streams: %{service_cards: []}
        }
        |> ServiceIndexView.render()
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "services-tab-check-results"
      assert html =~ ~s(href="/services/checks")
      assert html =~ "Check Results"
    end
  end

  defp mount_connected(scope, params) do
    socket = assign(base_socket(scope), :force_connected_load?, true)
    {:ok, mounted} = Checks.mount(%{}, %{}, socket)

    uri =
      case Map.get(params, "q") do
        q when is_binary(q) and q != "" ->
          "https://example.test/services/checks?q=#{URI.encode_www_form(q)}"

        _ ->
          "https://example.test/services/checks"
      end

    {:noreply, after_params} = Checks.handle_params(params, uri, mounted)
    after_params
  end

  defp base_socket(scope) do
    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      router: Router,
      view: Checks,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: :index,
        current_scope: scope
      }
    }
  end

  defp render_checks(%Socket{} = socket) do
    socket.assigns
    |> Checks.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp scope_with_permissions(perms) do
    %Scope{
      user: %{id: @user_uuid, email: "operator@example.com", timezone: "Etc/UTC"},
      permissions: MapSet.new(perms)
    }
  end
end
