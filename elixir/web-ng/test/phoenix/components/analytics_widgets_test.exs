defmodule ServiceRadarWebNGWeb.Components.AnalyticsWidgetsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AnalyticsLive.Index

  @moduletag :db_free

  test "high utilization renders CPU links and disk mounts from both tag encodings" do
    for tags <- [%{"mount_point" => "/data"}, ~s({"mount_point":"/data"})] do
      html =
        render_component(&Index.high_utilization_widget/1,
          loading: false,
          data: %{
            disk_services: [%{"device_id" => "host01.example.com", "value" => 95, "tags" => tags}],
            disk_critical: 1,
            total_disk_mounts: 1
          }
        )

      document = Floki.parse_fragment!(html)
      assert Floki.find(document, ~s(span[title="/data"])) |> Floki.text() == "/data"

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
