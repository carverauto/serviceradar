defmodule ServiceRadarWebNG.FieldSurveyDashboardPlaylistTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.FieldSurveyDashboardPlaylist

  defmodule FloorplanRasterSRQLStub do
    @moduledoc false
    def query(query, opts) do
      send(self(), {:srql_query, query, opts})

      {:ok,
       %{
         "results" => [
           %{
             "entity" => "field_survey_raster",
             "raster_id" => "raster-1",
             "session_id" => "session-1",
             "has_floorplan" => true,
             "generated_at" => DateTime.utc_now()
           }
         ]
       }}
    end
  end

  defmodule MissingFloorplanSRQLStub do
    @moduledoc false
    def query(_query, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "entity" => "field_survey_raster",
             "raster_id" => "raster-2",
             "session_id" => "session-2",
             "has_floorplan" => false
           }
         ]
       }}
    end
  end

  defmodule EmptySRQLStub do
    @moduledoc false
    def query(_query, _opts), do: {:ok, %{"results" => []}}
  end

  setup do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)

    on_exit(fn ->
      if old_srql_module do
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    scope =
      Scope.for_user(%{
        id: "00000000-0000-0000-0000-000000000000",
        email: "system@serviceradar.test",
        role: :system
      })

    {:ok, scope: scope}
  end

  test "preview only accepts FieldSurvey raster SRQL", %{scope: scope} do
    Application.put_env(:serviceradar_web_ng, :srql_module, FloorplanRasterSRQLStub)

    assert {:error, :playlist_query_must_target_field_survey_rasters} =
             FieldSurveyDashboardPlaylist.preview(scope, "in:devices limit:1")

    refute_received {:srql_query, _query, _opts}
  end

  test "preview passes scope through to SRQL and returns a floorplan-backed raster", %{scope: scope} do
    Application.put_env(:serviceradar_web_ng, :srql_module, FloorplanRasterSRQLStub)

    query = "in:field_survey_rasters overlay_type:wifi_rssi has_floorplan:true"

    assert {:ok, %{"raster_id" => "raster-1"}} =
             FieldSurveyDashboardPlaylist.preview(scope, query)

    assert_received {:srql_query, ^query, %{limit: 1, scope: ^scope}}
  end

  test "preview rejects raster rows that do not have a floorplan", %{scope: scope} do
    Application.put_env(:serviceradar_web_ng, :srql_module, MissingFloorplanSRQLStub)

    assert {:error, :no_field_survey_raster_candidate} =
             FieldSurveyDashboardPlaylist.preview(
               scope,
               "in:field_survey_rasters overlay_type:wifi_rssi"
             )
  end

  test "preview rejects empty raster result sets", %{scope: scope} do
    Application.put_env(:serviceradar_web_ng, :srql_module, EmptySRQLStub)

    assert {:error, :no_field_survey_raster_candidate} =
             FieldSurveyDashboardPlaylist.preview(
               scope,
               "in:field_survey_rasters overlay_type:wifi_rssi"
             )
  end

  test "creates, lists, updates, and deletes playlist entries after preview validation", %{scope: scope} do
    Application.put_env(:serviceradar_web_ng, :srql_module, FloorplanRasterSRQLStub)
    label = "Main floor #{System.unique_integer([:positive])}"

    attrs = %{
      label: label,
      srql_query: "in:field_survey_rasters overlay_type:wifi_rssi has_floorplan:true",
      enabled: "true",
      sort_order: "7",
      dwell_seconds: "45",
      max_age_seconds: "3600",
      metadata: ~s({"site":"ORD","floor":"1"})
    }

    assert {:ok, entry} = FieldSurveyDashboardPlaylist.create(scope, attrs)
    assert entry.label == label
    assert entry.enabled
    assert entry.sort_order == 7
    assert entry.metadata == %{"site" => "ORD", "floor" => "1"}

    assert {:ok, entries} = FieldSurveyDashboardPlaylist.list(scope)
    assert Enum.any?(entries, &(&1.id == entry.id))

    assert {:ok, updated} = FieldSurveyDashboardPlaylist.update(scope, entry, %{label: "#{label} updated"})
    assert updated.label == "#{label} updated"

    assert :ok = FieldSurveyDashboardPlaylist.delete(scope, updated)
  end

  test "does not create a playlist entry when the query cannot resolve a floorplan raster", %{scope: scope} do
    Application.put_env(:serviceradar_web_ng, :srql_module, EmptySRQLStub)

    assert {:error, :no_field_survey_raster_candidate} =
             FieldSurveyDashboardPlaylist.create(scope, %{
               label: "No data",
               srql_query: "in:field_survey_rasters overlay_type:wifi_rssi"
             })
  end
end
