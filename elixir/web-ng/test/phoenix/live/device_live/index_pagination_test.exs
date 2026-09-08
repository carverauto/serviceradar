defmodule ServiceRadarWebNGWeb.DeviceLive.IndexPaginationTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath
  alias ServiceRadarWebNGWeb.DeviceLive.IndexRefresh
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @moduletag :db_free

  defmodule CursorSRQL do
    @moduledoc false

    def query(_query, opts) do
      send(opts[:scope], {:index_pagination_srql, opts[:cursor], opts[:limit]})

      case opts[:cursor] do
        "cursor-page-2" ->
          {:ok,
           %{
             "results" => [%{"uid" => "device-page-2", "hostname" => "host-page-2"}],
             "pagination" => %{"prev_cursor" => "cursor-page-1"}
           }}

        "cursor-page-1" ->
          {:ok,
           %{
             "results" => [%{"uid" => "device-page-1", "hostname" => "host-page-1"}],
             "pagination" => %{"next_cursor" => "cursor-page-2"}
           }}

        _ ->
          {:ok,
           %{
             "results" => [%{"uid" => "device-page-1", "hostname" => "host-page-1"}],
             "pagination" => %{"next_cursor" => "cursor-page-2"}
           }}
      end
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, CursorSRQL)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    :ok
  end

  test "prev from page 2 reloads the list head instead of keeping page 2" do
    socket = load_devices(%{"q" => "in:devices", "page" => "2", "cursor" => "cursor-page-2"})
    assert socket.assigns.pagination_page == 2
    assert [%{"uid" => "device-page-2"}] = socket.assigns.devices

    path =
      IndexPath.list_path(
        query: "in:devices",
        page: "1",
        cursor: "cursor-page-1"
      )

    # handle_params reuses the LiveView socket, so pagination_page from page 2
    # is still assigned when the patched URL is applied.
    socket =
      SRQLPage.load_list(socket, path_params(path), "/devices", :devices,
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.pagination_page == 1
    assert [%{"uid" => "device-page-1"}] = socket.assigns.devices
  end

  test "pubsub refresh keeps the current page and keyset cursor" do
    params = %{"q" => "in:devices", "page" => "2", "cursor" => "cursor-page-2"}

    socket =
      params
      |> load_devices()
      |> IndexRefresh.remember_list_params(params, "/devices")
      |> IndexRefresh.refresh_devices(preserve_async_data?: true)

    assert socket.assigns.last_params["page"] == "2"
    assert socket.assigns.last_params["cursor"] == "cursor-page-2"
    assert socket.assigns.pagination_page == 2
    assert [%{"uid" => "device-page-2"}] = socket.assigns.devices
    assert_received {:index_pagination_srql, "cursor-page-2", 20}
  end

  defp load_devices(params) do
    %Socket{}
    |> Phoenix.Component.assign(:current_scope, self())
    |> Phoenix.Component.assign(:live_action, :index)
    |> Phoenix.Component.assign(:device_stats_loaded, false)
    |> SRQLPage.init("devices", default_limit: 20)
    |> SRQLPage.load_list(params, "/devices", :devices, default_limit: 20, max_limit: 100)
  end

  defp path_params(path) do
    case URI.parse(path).query do
      query when is_binary(query) and query != "" -> URI.decode_query(query)
      _ -> %{}
    end
  end
end
