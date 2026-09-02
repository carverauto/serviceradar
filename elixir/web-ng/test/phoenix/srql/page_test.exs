defmodule ServiceRadarWebNGWeb.SRQL.PageTest.CursorSRQL do
  @moduledoc false

  def query(_query, opts) do
    send(opts[:scope], {:page_test_srql, opts[:cursor], opts[:limit]})

    {:ok,
     %{
       "results" => [%{"id" => "row-2"}],
       "pagination" => %{"next_cursor" => "c2", "prev_cursor" => "c1"}
     }}
  end
end

defmodule ServiceRadarWebNGWeb.SRQL.PageTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog
  alias ServiceRadarWebNGWeb.SRQL.Page

  @moduletag :db_free

  test "shortcut_query translates a bare IPv4 address to a device IP query" do
    assert Page.shortcut_query("192.168.2.10") == ~s(in:devices ip:"192.168.2.10")
  end

  test "shortcut_query translates a bare hostname to a device hostname query" do
    assert Page.shortcut_query("pve04.local") == ~s(in:devices hostname:"pve04.local")
  end

  test "shortcut_query preserves explicit SRQL" do
    assert Page.shortcut_query("in:devices metadata.proxmox_candidate:true") ==
             "in:devices metadata.proxmox_candidate:true"
  end

  test "builder events leave chart mode, accept row filters, and strip them when chart mode resumes" do
    socket = Page.init(%Socket{}, "flows", default_limit: 100)

    socket =
      Page.handle_event(
        socket,
        "srql_builder_change",
        %{"builder" => %{"bucket" => ""}},
        []
      )

    assert Builder.mode(socket.assigns.srql.builder) == :row

    socket =
      Page.handle_event(
        socket,
        "srql_builder_change",
        %{
          "builder" => %{
            "filters" => %{
              "0" => %{"field" => "tag", "op" => "equals", "value" => "edge"}
            }
          }
        },
        []
      )

    assert socket.assigns.srql.draft =~ "tag:edge"
    assert socket.assigns.srql.builder_mode_notice == nil

    socket =
      Page.handle_event(
        socket,
        "srql_builder_change",
        %{"builder" => %{"bucket" => "5m"}},
        []
      )

    assert Builder.mode(socket.assigns.srql.builder) == :downsample
    refute socket.assigns.srql.draft =~ "tag:"

    assert socket.assigns.srql.builder_mode_notice ==
             "Removed 1 filter not available in chart mode: tag"

    socket =
      Page.sync_from_params(
        socket,
        %{"q" => "in:flows time:last_1h cidr:10.0.0.0/8 sort:time:desc limit:100"},
        "https://example.test/observability?tab=netflows",
        default_limit: 100,
        max_limit: 200
      )

    assert socket.assigns.srql.builder_mode_notice == nil
  end

  test "mode transition notice counts duplicate filter rows but lists each field once" do
    socket = Page.init(%Socket{}, "flows", default_limit: 100)

    socket =
      Page.handle_event(
        socket,
        "srql_builder_change",
        %{
          "builder" => %{
            "bucket" => "",
            "filters" => %{
              "0" => %{"field" => "tag", "op" => "equals", "value" => "edge"},
              "1" => %{"field" => "tag", "op" => "equals", "value" => "core"}
            }
          }
        },
        []
      )

    socket =
      Page.handle_event(
        socket,
        "srql_builder_change",
        %{"builder" => %{"bucket" => "5m"}},
        []
      )

    assert socket.assigns.srql.builder_mode_notice ==
             "Removed 2 filters not available in chart mode: tag"
  end

  test "stats queries remain unchanged on the unsupported freeform builder path" do
    query = ~s|in:flows time:last_24h stats:"count() as total" limit:100|

    socket =
      %Socket{}
      |> Page.init("flows", default_limit: 100)
      |> Page.sync_from_params(
        %{"q" => query},
        "https://example.test/observability?tab=netflows",
        default_limit: 100,
        max_limit: 200
      )

    assert socket.assigns.srql.query == query
    assert socket.assigns.srql.draft == query
    refute socket.assigns.srql.builder_supported
    refute socket.assigns.srql.builder_sync
  end

  test "mode-invalid chart queries remain unchanged on the desynchronized freeform path" do
    query =
      "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total series:app " <>
        "tag:edge limit:100"

    socket =
      %Socket{}
      |> Page.init("flows", default_limit: 100)
      |> Page.sync_from_params(
        %{"q" => query},
        "https://example.test/observability?tab=netflows",
        default_limit: 100,
        max_limit: 200
      )

    assert socket.assigns.srql.query == query
    assert socket.assigns.srql.draft == query
    refute socket.assigns.srql.builder_supported
    refute socket.assigns.srql.builder_sync
  end

  test "sync_from_params applies URL query to draft before data load" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    socket =
      Page.sync_from_params(
        socket,
        %{
          "q" => ~s(in:logs device_id:"sr:device-1" time:last_24h sort:timestamp:desc),
          "limit" => "50"
        },
        "https://example.test/observability?tab=logs",
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.srql.draft ==
             ~s(in:logs device_id:"sr:device-1" time:last_24h sort:timestamp:desc)

    assert socket.assigns.srql.query == socket.assigns.srql.draft
    assert socket.assigns.srql.loading
    # Legacy URL limit= still accepted when SRQL has no limit:N
    assert socket.assigns.limit == 50
  end

  test "sync_from_params prefers SRQL limit:N over URL limit=" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    socket =
      Page.sync_from_params(
        socket,
        %{
          "q" => "in:logs time:last_24h sort:timestamp:desc limit:40",
          "limit" => "50"
        },
        "https://example.test/observability?tab=logs",
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.limit == 40
  end

  test "sync_from_params uses default when neither SRQL nor URL provides limit" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    socket =
      Page.sync_from_params(
        socket,
        %{"q" => "in:logs time:last_24h sort:timestamp:desc"},
        "https://example.test/observability?tab=logs",
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.limit == 20
  end

  test "paginate advances session position without requiring URL cursor params" do
    parent = self()
    prev = Application.get_env(:serviceradar_web_ng, :srql_module)

    try do
      Application.put_env(
        :serviceradar_web_ng,
        :srql_module,
        ServiceRadarWebNGWeb.SRQL.PageTest.CursorSRQL
      )

      socket =
        %Socket{}
        |> Phoenix.Component.assign(:current_scope, parent)
        |> Page.init("logs", default_limit: 20)
        |> Page.load_list(
          %{"q" => "in:logs time:last_24h sort:timestamp:desc limit:20"},
          "https://example.test/observability?tab=logs",
          :logs,
          default_limit: 20,
          max_limit: 100
        )

      assert socket.assigns.pagination_page == 1

      socket =
        Page.paginate(socket, %{"cursor" => "c1", "page" => "2"},
          list_assign_key: :logs,
          default_limit: 20,
          max_limit: 100
        )

      assert socket.assigns.pagination_page == 2
      assert [%{"id" => "row-2"}] = socket.assigns.logs
      assert get_in(socket.assigns.srql, [:pagination, "next_cursor"]) == "c2"
      assert_received {:page_test_srql, "c1", 20}
    after
      if prev do
        Application.put_env(:serviceradar_web_ng, :srql_module, prev)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end
  end

  test "sync_from_params bounds explicit logs queries without a time filter" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    socket =
      Page.sync_from_params(
        socket,
        %{"q" => ~s(in:logs message:"time:last_1h inside body" sort:timestamp:desc limit:50)},
        "https://example.test/observability?tab=logs",
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.srql.query ==
             ~s(in:logs message:"time:last_1h inside body" time:last_24h sort:timestamp:desc limit:50)
  end

  test "sync_from_params preserves explicit logs time filters" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    socket =
      Page.sync_from_params(
        socket,
        %{"q" => "in:logs time:last_1h sort:timestamp:desc limit:50"},
        "https://example.test/observability?tab=logs",
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.srql.query == "in:logs time:last_1h sort:timestamp:desc limit:50"
  end

  test "logs default query is bounded to the last 24 hours" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    assert socket.assigns.srql.query =~ "in:logs"
    assert socket.assigns.srql.query =~ "time:last_24h"
    assert socket.assigns.srql.query =~ "limit:20"
  end

  test "route_target_for_query uses the catalog route and route params" do
    assert Page.route_target_for_query("in:bmp_events router_ip:192.0.2.1", "/devices") ==
             {"/observability/bmp", %{}}

    assert Page.route_target_for_query("in:flows src_ip:192.0.2.10", "/devices") ==
             {"/observability/netflows", %{}}

    assert Page.route_target_for_query("in:events severity:Critical", "/devices") ==
             {"/observability/events", %{}}

    assert Page.route_target_for_query("in:logs time:last_1h", "/devices") ==
             {"/observability/logs", %{}}

    assert Page.route_target_for_query("in:wifi_sites site_code:ZZC", "/devices") ==
             {"/devices/wifi", %{}}

    assert Page.route_target_for_query(
             "in:public_endpoints ip:23.138.124.7",
             "/devices"
           ) == {"/inventory/public-endpoints", %{}}
  end

  test "sanitize_query removes stale catalog filters when switching entities" do
    assert Page.sanitize_query("in:bmp_events include_inactive:true router_ip:192.0.2.1 limit:20") ==
             "in:bmp_events router_ip:192.0.2.1 limit:20"

    assert Page.sanitize_query("in:devices metadata.proxmox_candidate:true include_inactive:true") ==
             "in:devices metadata.proxmox_candidate:true include_inactive:true"
  end

  test "every catalog entity has a route" do
    route_less =
      Catalog.entities()
      |> Enum.filter(&(Map.get(&1, :route) in [nil, ""]))
      |> Enum.map(& &1.id)

    assert route_less == []
  end

  test "every catalog route is handled by the router" do
    unroutable =
      Catalog.entities()
      |> Enum.filter(fn entity ->
        route = Map.get(entity, :route)

        is_binary(route) and
          Phoenix.Router.route_info(ServiceRadarWebNGWeb.Router, "GET", route, "localhost") == :error
      end)
      |> Enum.map(&{&1.id, &1.route})

    assert unroutable == []
  end

  test "srql_reset patches the current path with the provided default query" do
    filtered =
      "in:flows time:[2026-08-28T17:38:00.000000Z,2026-08-28T17:41:59.999999Z] sort:time:desc"

    default_query = "in:flows time:last_1h sort:time:desc"

    socket =
      %Socket{}
      |> Page.init("flows", default_limit: 50)
      |> Page.sync_from_params(
        %{
          "q" => filtered,
          "cursor" => "c1",
          "page" => "2",
          "nf" => "encoded",
          "view" => "explorer"
        },
        "https://example.test/observability/netflows?q=#{URI.encode_www_form(filtered)}",
        default_limit: 50,
        max_limit: 200
      )

    socket =
      Page.handle_event(socket, "srql_reset", %{},
        fallback_path: "/observability/netflows",
        extra_params: %{
          "view" => "explorer",
          "nf" => "encoded",
          "cursor" => "c1",
          "page" => "2",
          "q" => filtered
        },
        default_query: default_query
      )

    {path, params} = redirected_query(socket)
    assert path == "/observability/netflows"
    assert params["q"] == default_query
    assert params["view"] == "explorer"
    refute Map.has_key?(params, "cursor")
    refute Map.has_key?(params, "page")
    refute Map.has_key?(params, "nf")
    refute socket.assigns.srql.builder_open
  end

  test "srql_reset without default_query uses the entity builder baseline" do
    filtered = "in:devices hostname:edge-1 include_inactive:true sort:last_seen:desc limit:20"

    socket =
      %Socket{}
      |> Page.init("devices", default_limit: 20)
      |> Page.sync_from_params(
        %{"q" => filtered},
        "https://example.test/devices?q=#{URI.encode_www_form(filtered)}",
        default_limit: 20,
        max_limit: 100
      )

    socket =
      Page.handle_event(socket, "srql_reset", %{}, fallback_path: "/devices")

    {_path, params} = redirected_query(socket)
    baseline = Builder.build(Builder.default_state("devices", 20))
    assert params["q"] == baseline
    assert params["q"] =~ "in:devices"
    refute params["q"] =~ "hostname:edge-1"
  end

  test "empty srql_submit keeps the current query" do
    filtered =
      "in:flows time:[2026-08-28T17:38:00.000000Z,2026-08-28T17:41:59.999999Z] sort:time:desc"

    socket =
      %Socket{}
      |> Page.init("flows", default_limit: 50)
      |> Page.sync_from_params(
        %{"q" => filtered},
        "https://example.test/observability/netflows?q=#{URI.encode_www_form(filtered)}",
        default_limit: 50,
        max_limit: 200
      )

    socket =
      Page.handle_event(socket, "srql_submit", %{"q" => ""}, fallback_path: "/observability/netflows")

    {_path, params} = redirected_query(socket)
    assert params["q"] == filtered
  end

  defp redirected_query(%Socket{redirected: {:live, :patch, %{to: to}}}) do
    uri = URI.parse(to)
    {uri.path, URI.decode_query(uri.query || "")}
  end
end
