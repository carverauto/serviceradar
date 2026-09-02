defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEventsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page

  @moduletag :db_free

  test "srql_reset from the query-bar click payload restores the devices baseline" do
    filtered =
      "in:devices include_inactive:true hostname:%foo% sort:last_seen:desc limit:100"

    socket =
      %Socket{}
      |> Page.init("devices", default_limit: 100)
      |> Page.sync_from_params(
        %{"q" => filtered},
        "https://demo.serviceradar.cloud/devices?q=#{URI.encode_www_form(filtered)}",
        default_limit: 100,
        max_limit: 100
      )

    assert {:noreply, socket} = IndexEvents.handle_event("srql_reset", %{"value" => ""}, socket)
    assert {:live, :patch, %{to: to}} = socket.redirected

    params = to |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()
    assert params["q"] == Builder.build(Builder.default_state("devices", 100))
    refute params["q"] =~ "hostname:"
  end
end
