defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEventsTest do
  @moduledoc false

  # async: false because the all-matching resolution test swaps the global
  # :srql_module. The other cases are pure.
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection
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

  test "picking an all-matching modal scope then cancelling leaves the toolbar selection untouched" do
    socket =
      selection_socket(%{
        selected_devices: MapSet.new(["manual-1"]),
        bulk_target_matching_count: 5
      })

    assert {:noreply, socket} =
             IndexEvents.handle_event(
               "bulk_state_scope_change",
               %{"bulk_scope" => %{"scope" => "all_matching"}},
               socket
             )

    assert socket.assigns.bulk_target_scope == "all_matching"
    refute socket.assigns.select_all_matching
    assert socket.assigns.total_matching_count == nil
    assert socket.assigns.selected_devices == MapSet.new(["manual-1"])

    assert {:noreply, socket} = IndexEvents.handle_event("close_bulk_edit_modal", %{}, socket)

    assert socket.assigns.bulk_target_scope == "selected"
    refute socket.assigns.select_all_matching
    assert socket.assigns.total_matching_count == nil
    assert socket.assigns.selected_devices == MapSet.new(["manual-1"])
  end

  test "selected_uids_for_scope resolves all-matching through SRQL and selected through the MapSet" do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.MatchingUIDStub)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      end
    end)

    socket =
      selection_socket(%{
        srql: %{query: "in:devices hostname:%host01%"},
        selected_devices: MapSet.new(["manual-1", "manual-2"])
      })

    assert Selection.selected_uids_for_scope(socket, "selected") == ["manual-1", "manual-2"]
    assert Selection.selected_uids_for_scope(socket, "all_matching") == ["matching-1", "matching-2"]
  end

  test "scope-aware validation preserves the 10k cap and the unknown-size guard" do
    assert :ok =
             Selection.validate_device_selection_for_scope(
               selection_socket(%{selected_devices: MapSet.new(["a"])}),
               "selected"
             )

    assert {:error, "Select at least one device first."} =
             Selection.validate_device_selection_for_scope(selection_socket(), "selected")

    assert {:error, "Unable to determine selection size. Please try again."} =
             Selection.validate_device_selection_for_scope(
               selection_socket(%{bulk_target_matching_count: nil}),
               "all_matching"
             )

    assert {:error, "Too many devices selected. Narrow your filters and try again."} =
             Selection.validate_device_selection_for_scope(
               selection_socket(%{bulk_target_matching_count: 10_001}),
               "all_matching"
             )

    assert :ok =
             Selection.validate_device_selection_for_scope(
               selection_socket(%{bulk_target_matching_count: 10_000}),
               "all_matching"
             )
  end

  defp selection_socket(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          current_scope: nil,
          srql: %{query: ""},
          selected_devices: MapSet.new(),
          select_all_matching: false,
          total_matching_count: nil,
          show_bulk_edit_modal: true,
          bulk_edit_form: nil,
          bulk_scope_form: nil,
          bulk_state_form: nil,
          bulk_target_scope: "selected",
          bulk_target_matching_count: nil
        },
        Map.new(overrides)
      )

    %Socket{assigns: assigns}
  end

  defmodule MatchingUIDStub do
    @moduledoc false

    def query(_query, _opts) do
      {:ok,
       %{
         "results" => [%{"uid" => "matching-1"}, %{"uid" => "matching-2"}],
         "pagination" => %{}
       }}
    end
  end
end
