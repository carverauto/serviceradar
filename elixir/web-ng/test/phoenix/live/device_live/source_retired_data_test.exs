defmodule ServiceRadarWebNGWeb.DeviceLive.SourceRetiredDataTest do
  @moduledoc """
  The `source_retired` mark on the device detail view: when the grace pass deletes the record,
  and how the header and the Status card show it. `DeviceLiveTest` covers the page loading it.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceHeaderComponents
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryComponents
  alias ServiceRadarWebNGWeb.DeviceLive.SourceRetiredData

  @moduletag :db_free

  @uid "sr:retired-test-0001"
  @time_key "sr-retired-test-0001"
  @marked_at ~U[2026-01-10 08:00:00Z]

  describe "schedule/3" do
    test "an enabled pass deletes the record at the end of its grace period" do
      assert %{marked_at: @marked_at, deletes_after: deletes_after, schedule: :scheduled} =
               SourceRetiredData.schedule(@marked_at, {:ok, false}, settings(true, 7))

      assert deletes_after == ~U[2026-01-17 08:00:00Z]

      assert %{deletes_after: ~U[2026-01-13 08:00:00Z], schedule: :scheduled} =
               SourceRetiredData.schedule(@marked_at, {:ok, false}, settings(true, 3))
    end

    test "an open review holds the record, whatever the settings" do
      for settings <- [settings(true, 7), settings(false, 7), {:error, :forbidden}] do
        assert %{marked_at: @marked_at, deletes_after: nil, schedule: :held} =
                 SourceRetiredData.schedule(@marked_at, {:ok, true}, settings)
      end
    end

    test "no pass runs while source retirement is disabled" do
      assert %{deletes_after: nil, schedule: :paused} =
               SourceRetiredData.schedule(@marked_at, {:ok, false}, settings(false, 7))
    end

    test "settings or a hold that cannot be read give no date" do
      for {held, settings} <- [
            {{:ok, false}, {:error, :forbidden}},
            {{:ok, false}, {:ok, nil}},
            {{:error, :timeout}, settings(true, 7)}
          ] do
        assert %{marked_at: @marked_at, deletes_after: nil, schedule: :unknown} =
                 SourceRetiredData.schedule(@marked_at, held, settings)
      end
    end
  end

  describe "the device row" do
    test "the mark is read from source_retired_at" do
      assert SourceRetiredData.marked?(row())
      refute SourceRetiredData.marked?(%{"uid" => @uid})
      refute SourceRetiredData.marked?(%{"uid" => @uid, "source_retired_at" => nil})
      refute SourceRetiredData.marked?(%{"uid" => @uid, "source_retired_at" => "not a time"})
      refute SourceRetiredData.marked?(nil)
    end

    test "an unmarked row loads nothing" do
      assert SourceRetiredData.load(%{"uid" => @uid}, nil) == nil
      assert SourceRetiredData.load(nil, nil) == nil
    end
  end

  describe "the Status card" do
    test "shows when the record was marked and when it is deleted" do
      html = summary(SourceRetiredData.schedule(@marked_at, {:ok, false}, settings(true, 7)))

      assert html =~ "Source Retired:"
      assert occurrences(html, "Deletes After:") == 1
      assert datetime(html, "source-retired-at") == @marked_at
      assert datetime(html, "source-retired-deletes-after") == ~U[2026-01-17 08:00:00Z]
    end

    test "says why there is no deletion time" do
      for {held, settings, text} <- [
            {{:ok, true}, settings(true, 7), "Not while a de-duplication review names it"},
            {{:ok, false}, settings(false, 7), "Not while source retirement is disabled"},
            {{:ok, false}, {:error, :forbidden}, "Depends on the device cleanup settings"}
          ] do
        html = summary(SourceRetiredData.schedule(@marked_at, held, settings))

        assert datetime(html, "source-retired-at") == @marked_at
        assert occurrences(html, "Deletes After:") == 1
        assert html =~ text
        assert datetime(html, "source-retired-deletes-after") == nil
      end
    end

    test "shows nothing for an unmarked record" do
      html = summary(nil)

      refute html =~ "Source Retired:"
      refute html =~ "Deletes After:"
    end
  end

  describe "the header" do
    test "marks a source-retired record" do
      assert header(true) =~ ~s(data-testid="device-source-retired-pill")
      assert header(true) =~ "Source retired"
      refute header(false) =~ ~s(data-testid="device-source-retired-pill")
    end
  end

  defp settings(enabled, grace_days) do
    {:ok,
     %DeviceCleanupSettings{
       source_retirement_enabled: enabled,
       source_retired_grace_days: grace_days
     }}
  end

  defp row do
    %{
      "uid" => @uid,
      "hostname" => "retired-test-01",
      "source_retired_at" => DateTime.to_iso8601(@marked_at)
    }
  end

  defp summary(source_retirement) do
    render_component(&DeviceSummaryComponents.device_summary_section/1,
      device_row: row(),
      source_retirement: source_retirement
    )
  end

  defp header(source_retired) do
    render_component(&DeviceHeaderComponents.device_show_header/1,
      active_tab: "details",
      device_uid: @uid,
      device_display_name: "retired-test-01",
      device_source_retired: source_retired
    )
  end

  defp occurrences(html, text), do: length(String.split(html, text)) - 1

  # The datetime of the Status card's time element named `suffix`, or nil when there is none.
  defp datetime(html, suffix) do
    case html
         |> LazyHTML.from_fragment()
         |> LazyHTML.query("#device-summary-#{@time_key}-#{suffix}")
         |> LazyHTML.attribute("datetime") do
      [value] ->
        {:ok, datetime, 0} = DateTime.from_iso8601(value)
        datetime

      [] ->
        nil
    end
  end
end
