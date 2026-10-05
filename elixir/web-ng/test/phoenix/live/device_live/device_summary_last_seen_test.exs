defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryLastSeenTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryComponents

  @moduletag :db_free

  test "Last Seen distinguishes successful sweeps from inventory refreshes" do
    inventory_time = "1999-04-03T12:00:00Z"
    success_time = "1999-04-01T09:00:00Z"

    cases = [
      {%{
         "sweep_last_available_at" => success_time,
         "sweep_consecutive_failures" => "4"
       }, false, success_time},
      {%{
         "sweep_last_available_at" => success_time,
         "sweep_consecutive_failures" => 0
       }, false, success_time},
      {%{"sweep_last_available_at" => success_time}, false, success_time},
      {%{"sweep_consecutive_failures" => "4"}, false, nil},
      {%{
         "sweep_last_available_at" => "not-a-timestamp",
         "sweep_consecutive_failures" => "4"
       }, false, nil},
      {%{}, false, inventory_time},
      {nil, false, inventory_time},
      {%{
         "sweep_last_available_at" => success_time,
         "sweep_consecutive_failures" => "4"
       }, true, inventory_time}
    ]

    for {metadata, agent?, expected} <- cases do
      html =
        render_component(&DeviceSummaryComponents.device_summary_section/1,
          device_row: %{
            "uid" => "last-seen-example",
            "hostname" => "host01.example.com",
            "ip" => "192.0.2.41",
            "last_seen_time" => inventory_time,
            "agent_device" => agent?,
            "metadata" => metadata
          }
        )

      document = LazyHTML.from_fragment(html)

      row_tree =
        document
        |> LazyHTML.query("div")
        |> LazyHTML.to_tree(skip_whitespace_nodes: true)
        |> Enum.find(fn {"div", _, children} ->
          Enum.any?(children, fn
            {"span", _, ["Last Seen:"]} -> true
            _ -> false
          end)
        end)

      assert row_tree, "Last Seen row is missing"
      row = LazyHTML.from_tree([row_tree])
      times = row |> LazyHTML.query("time") |> LazyHTML.attribute("datetime")

      if expected do
        assert times == [expected], "unexpected Last Seen for #{inspect(metadata)}"
      else
        assert times == []
        assert LazyHTML.text(row) =~ "Unknown"
        refute LazyHTML.text(row) =~ inventory_time
      end
    end
  end
end
