defmodule ServiceRadarWebNGWeb.DeviceLive.IndexPathTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath

  @moduletag :db_free

  test "list_path omits page 1 and keeps later pages plus cursor" do
    assert IndexPath.list_path(query: "in:devices", page: 1) == "/devices?q=in%3Adevices"

    path = IndexPath.list_path(query: "in:devices", page: 3, cursor: "abc")
    assert path =~ ~r{^/devices\?}
    assert path =~ "q=in%3Adevices"
    assert path =~ "page=3"
    assert path =~ "cursor=abc"
  end

  test "list_path drops leftover cursor when returning to page 1" do
    path = IndexPath.list_path(query: "in:devices", page: 1, cursor: "cursor-page-1")
    assert path == "/devices?q=in%3Adevices"
    refute path =~ "cursor="
    refute path =~ "page="

    path = IndexPath.list_path(query: "in:devices", page: "1", cursor: "cursor-page-1")
    assert path == "/devices?q=in%3Adevices"
  end

  test "show_path carries a sanitized return_to" do
    path =
      IndexPath.show_path("alma-test01",
        tab: "interfaces",
        return_to: "/devices?page=3"
      )

    assert path =~ ~r{^/devices/alma-test01\?}
    assert path =~ "tab=interfaces"
    assert path =~ "return_to="
    assert path =~ URI.encode_www_form("/devices?page=3")
  end

  test "sanitize only allows the devices list path" do
    assert IndexPath.sanitize("/devices?page=4&cursor=xyz") == "/devices?page=4&cursor=xyz"
    assert IndexPath.sanitize("https://evil.example/devices?page=2") == "/devices?page=2"
    assert IndexPath.sanitize("/settings") == "/devices"
    assert IndexPath.sanitize("/devices/alma-test01") == "/devices"
    assert IndexPath.sanitize(nil) == "/devices"
  end

  test "from_uri keeps the list query from a full request URL" do
    assert IndexPath.from_uri("http://localhost:4000/devices?page=5&q=in:devices") ==
             "/devices?page=5&q=in:devices"
  end
end
