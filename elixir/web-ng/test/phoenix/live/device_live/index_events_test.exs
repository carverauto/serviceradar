defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEventsTest do
  @moduledoc false

  # async: false because the all-matching resolution test swaps the global
  # :srql_module. The other cases are pure.
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
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

  test "closing the bulk delete modal returns Stop on first error to off" do
    socket =
      selection_socket(%{
        show_bulk_delete_modal: true,
        bulk_delete_stop_on_error: true,
        bulk_delete_error_form: nil
      })

    assert {:noreply, socket} = IndexEvents.handle_event("close_bulk_delete_modal", %{}, socket)

    refute socket.assigns.show_bulk_delete_modal
    refute socket.assigns.bulk_delete_stop_on_error
    assert socket.assigns.bulk_delete_error_form.params == %{"stop_on_error" => "false"}
  end

  test "selected_uids_for_scope resolves all-matching through SRQL and selected through the MapSet" do
    with_matching_uids(:two, fn ->
      socket =
        selection_socket(%{
          srql: %{query: "in:devices hostname:%host01%"},
          selected_devices: MapSet.new(["manual-1", "manual-2"])
        })

      assert Selection.selected_uids_for_scope(socket, "selected") ==
               {:ok, ["manual-1", "manual-2"]}

      assert Selection.selected_uids_for_scope(socket, "all_matching") ==
               {:ok, ["matching-1", "matching-2"]}
    end)
  end

  test "all-matching selection walks every page, including past the old 10k stop" do
    with_matching_uids(:paged, fn ->
      socket = selection_socket(%{srql: %{query: "in:devices hostname:%host01% sort:last_seen:desc"}})

      assert {:ok, uids} = Selection.selected_uids_for_scope(socket, "all_matching")
      assert length(uids) == 10_001
      assert List.first(uids) == "uid-1"
      assert List.last(uids) == "last"

      assert_received {:matching_query, query, nil}
      assert query == "in:devices hostname:%host01% window_scan:true sort:uid:asc limit:1000"
      assert_received {:matching_query, _query, "p2"}
    end)
  end

  test "a full match page without a new cursor is an error, not a partial selection" do
    with_matching_uids(:stuck_full_page, fn ->
      socket = selection_socket(%{srql: %{query: "in:devices"}})

      assert {:error, :selection_page_did_not_advance} =
               Selection.selected_uids_for_scope(socket, "all_matching")
    end)
  end

  test "a failed match page is returned instead of the uids gathered so far" do
    with_matching_uids(:error, fn ->
      socket = selection_socket(%{srql: %{query: "in:devices"}})

      assert {:error, :db_down} = Selection.selected_uids_for_scope(socket, "all_matching")
    end)
  end

  test "a failed batch does not stop the remaining batches" do
    uids = Enum.map(1..401, &"uid-#{&1}")

    assert {:ok, summary} =
             Helpers.each_uid_batch(uids, fn
               ["uid-201" | _] -> {:error, "middle"}
               batch -> {:ok, length(batch)}
             end)

    assert summary.applied == 201
    assert summary.failed == 200
    assert summary.total == 401
    assert summary.errors == ["middle"]
  end

  test "stop on first error halts and reports how many were already applied" do
    uids = Enum.map(1..401, &"uid-#{&1}")

    assert {:error, summary} =
             Helpers.each_uid_batch(
               uids,
               fn
                 ["uid-201" | _] -> {:error, "middle"}
                 _batch -> :ok
               end,
               on_error: :halt
             )

    assert summary.applied == 200
    assert summary.failed == 200
    assert summary.total == 401

    assert Helpers.batch_failure_message({:error, summary}) ==
             "Stopped after updating 200 of 401 device(s): middle"
  end

  test "a non-summary error reason becomes a flash string" do
    assert Helpers.batch_failure_message({:error, %RuntimeError{message: "db timeout"}}) ==
             "db timeout"

    assert Helpers.batch_failure_message({:error, %{code: 1}}) == "%{code: 1}"

    assert Helpers.batch_failure_message({:error, {:unexpected_page, 3}}) ==
             "{:unexpected_page, 3}"

    assert Helpers.batch_failure_message({:error, :selection_page_did_not_advance}) ==
             ":selection_page_did_not_advance"
  end

  test "scope-aware validation accepts any known selection size" do
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

    assert :ok =
             Selection.validate_device_selection_for_scope(
               selection_socket(%{bulk_target_matching_count: 50_000}),
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

  defp with_matching_uids(mode, fun) do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.MatchingUIDStub)
    Process.put(:matching_uid_mode, mode)

    try do
      fun.()
    after
      Process.delete(:matching_uid_mode)

      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      end
    end
  end

  defmodule MatchingUIDStub do
    @moduledoc false

    def query(query, opts) do
      send(self(), {:matching_query, query, Map.get(opts, :cursor)})

      case Process.get(:matching_uid_mode, :two) do
        :two ->
          {:ok,
           %{
             "results" => [%{"uid" => "matching-1"}, %{"uid" => "matching-2"}],
             "pagination" => %{}
           }}

        :paged ->
          case Map.get(opts, :cursor) do
            "p2" ->
              {:ok, %{"results" => [%{"uid" => "last"}], "pagination" => %{}}}

            _ ->
              rows = for n <- 1..10_000, do: %{"uid" => "uid-#{n}"}
              {:ok, %{"results" => rows, "pagination" => %{"next_cursor" => "p2"}}}
          end

        :stuck_full_page ->
          rows = for n <- 1..1_000, do: %{"uid" => "uid-#{n}"}
          {:ok, %{"results" => rows, "pagination" => %{}}}

        :error ->
          {:error, :db_down}
      end
    end
  end
end
