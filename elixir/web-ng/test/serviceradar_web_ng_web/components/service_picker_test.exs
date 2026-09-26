defmodule ServiceRadarWebNGWeb.Components.ServicePickerTest do
  @moduledoc """
  Every picker event re-checks the pane's view permission before it touches
  the catalog or the URL. The LiveView delegates `service_picker_*` events
  here unchanged, so this is the boundary that decides.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Components.ServicePicker

  @moduletag :db_free

  defp socket(permissions, picker \\ ServicePicker.initial_state()) do
    %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: %Scope{user: nil, permissions: MapSet.new(permissions)},
        service_picker: picker
      }
    }
  end

  defp context(tab), do: %{tab: tab, query: "in:otel_trace_summaries time:last_1h", params: %{}}

  test "a caller without trace access cannot open the traces picker" do
    denied =
      ServicePicker.handle_event("service_picker_open", %{}, socket(["observability.logs.view"]), context("traces"))

    refute denied.assigns.service_picker.open?
    assert denied.assigns.flash["error"] =~ "permission"

    allowed =
      ServicePicker.handle_event("service_picker_open", %{}, socket(["observability.traces.view"]), context("traces"))

    assert allowed.assigns.service_picker.open?
    assert allowed.assigns.service_picker.tab == "traces"
    assert allowed.assigns.flash == %{}
  end

  test "a caller without trace access cannot apply a selection to the traces pane" do
    open = %{ServicePicker.initial_state() | open?: true, tab: "traces", selected: ["svc-0001"]}

    denied =
      ServicePicker.handle_event(
        "service_picker_apply",
        %{},
        socket(["observability.logs.view"], open),
        context("traces")
      )

    assert is_nil(denied.redirected)

    allowed =
      ServicePicker.handle_event(
        "service_picker_apply",
        %{},
        socket(["observability.traces.view"], open),
        context("traces")
      )

    assert {:live, :patch, %{to: to}} = allowed.redirected
    assert URI.decode_query(URI.parse(to).query)["q"] =~ ~s(service_name:"svc-0001")
  end

  test "selection is capped at 20 and says so instead of dropping silently" do
    full = %{
      ServicePicker.initial_state()
      | open?: true,
        tab: "logs",
        selected: Enum.map(1..20, &"svc-#{&1}")
    }

    socket =
      ServicePicker.handle_event(
        "service_picker_toggle",
        %{"name" => "svc-0021"},
        socket(["observability.logs.view"], full),
        context("logs")
      )

    assert length(socket.assigns.service_picker.selected) == 20
    refute "svc-0021" in socket.assigns.service_picker.selected
    assert socket.assigns.service_picker.notice =~ "at most 20"
  end

  test "a stale search result is dropped and the latest one is kept" do
    picker = %{ServicePicker.initial_state() | open?: true, tab: "logs", token: 2, loading?: true}
    socket = socket(["observability.logs.view"], picker)

    stale = ServicePicker.handle_async({:ok, {1, {:ok, ["svc-old"], 1}}}, socket)
    assert stale.assigns.service_picker.results == []

    latest = ServicePicker.handle_async({:ok, {2, {:ok, ["svc-0001"], 7}}}, socket)
    assert latest.assigns.service_picker.results == ["svc-0001"]
    assert latest.assigns.service_picker.total == 7
    refute latest.assigns.service_picker.loading?
  end
end
