defmodule ServiceRadarWebNGWeb.Components.AnalyticsWidgetsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AnalyticsLive.Index

  @moduletag :db_free

  test "high utilization renders CPU links, device identities and both disk tag encodings" do
    for tags <- [%{"mount_point" => "/data"}, ~s({"mount_point":"/data"})] do
      html =
        render_component(&Index.high_utilization_widget/1,
          loading: false,
          data: %{
            cpu_services: [%{"device_id" => "cpu01.example.com", "value" => 95}],
            memory_services: [%{"device_id" => "memory01.example.com", "value" => 95}],
            disk_services: [%{"device_id" => "host01.example.com", "value" => 95, "tags" => tags}],
            disk_critical: 1,
            total_disk_mounts: 1
          }
        )

      document = Floki.parse_fragment!(html)
      assert Floki.find(document, ~s(span[title="/data"])) |> Floki.text() == "/data"

      for host <- ~w(cpu01.example.com memory01.example.com host01.example.com) do
        assert Floki.find(document, ~s([title="#{host}"])) |> Floki.text() == host
      end

      queries =
        document
        |> Floki.find("a[href]")
        |> Floki.attribute("href")
        |> Enum.map(&URI.parse/1)
        |> Enum.filter(&(&1.path == "/dashboard"))
        |> Enum.map(&URI.decode_query(&1.query)["q"])

      assert length(queries) == 2
      assert Enum.all?(queries, &String.contains?(&1, ~s(metric_type:"sysmon.cpu")))
      assert Enum.any?(queries, &String.ends_with?(&1, "limit:100"))
    end
  end
end
