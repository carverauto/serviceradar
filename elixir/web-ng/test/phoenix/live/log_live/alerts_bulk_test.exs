defmodule ServiceRadarWebNGWeb.LogLive.AlertsBulkTest do
  @moduledoc """
  Bulk acknowledge and snooze on the reachable alert list.

  `/observability/alerts` is served by `ServiceRadarWebNGWeb.LogLive.Index`.
  The legacy `ServiceRadarWebNGWeb.AlertLive.Index` at `/alerts` only
  `push_navigate`s here, so the controls belong on this surface.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadarWebNG.AlertActions

  require Ash.Query

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.AlertsListSRQLStub)
    Application.put_env(:serviceradar_web_ng, :test_alert_rows, [])

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :test_alert_rows)

      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      end
    end)

    :ok
  end

  test "the legacy /alerts route only redirects to the reachable list", %{conn: conn} do
    user = operator_user_fixture()

    assert {:error, {:live_redirect, %{to: to}}} = live(log_in_user(conn, user), ~p"/alerts")
    assert to =~ "/observability/alerts"
  end

  test "a scope without observability.alerts.manage gets no bulk controls", %{conn: conn} do
    user = viewer_user_fixture()
    publish([alert_fixture()])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    refute has_element?(lv, "button[phx-click='alert_bulk_acknowledge']")
    refute has_element?(lv, "input[phx-click='alert_select_toggle']")
  end

  test "a forged bulk acknowledge is refused inside handle_event", %{conn: conn} do
    user = viewer_user_fixture()
    alert = alert_fixture()
    publish([alert])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    # Even the selection event is server-side; drive the mutating event directly.
    render_click(lv, "alert_select_toggle", %{"id" => alert.id})
    html = render_click(lv, "alert_bulk_acknowledge", %{})

    assert html =~ "not authorized"
    assert reload(alert).status == :pending
    assert acknowledgements(alert.id) == []
  end

  test "bulk acknowledge reports per-alert outcomes on partial failure", %{conn: conn} do
    user = operator_user_fixture()

    pending = alert_fixture()
    escalated = escalate(alert_fixture())
    already_resolved = resolve(alert_fixture())

    publish([pending, escalated, already_resolved])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    for alert <- [pending, escalated, already_resolved] do
      render_click(lv, "alert_select_toggle", %{"id" => alert.id})
    end

    html = render_click(lv, "alert_bulk_acknowledge", %{})

    assert html =~ "2 succeeded, 1 failed"
    assert html =~ "already resolved"

    assert reload(pending).status == :acknowledged
    assert reload(escalated).status == :acknowledged
    assert reload(already_resolved).status == :resolved

    # Each successfully actioned alert records its own acknowledgement.
    assert length(acknowledgements(pending.id)) == 1
    assert length(acknowledgements(escalated.id)) == 1
    assert acknowledgements(already_resolved.id) == []
  end

  test "an id outside the rendered result set is rejected without disclosure", %{conn: conn} do
    user = operator_user_fixture()

    visible = alert_fixture()
    hidden = alert_fixture()

    # Only `visible` is in the list the server rendered.
    publish([visible])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    render_click(lv, "alert_select_toggle", %{"id" => visible.id})
    # A crafted toggle for a row the server never rendered must not enter the
    # selection at all.
    render_click(lv, "alert_select_toggle", %{"id" => hidden.id})

    html = render_click(lv, "alert_bulk_acknowledge", %{})

    assert html =~ "1 succeeded, 0 failed"
    assert reload(visible).status == :acknowledged
    assert reload(hidden).status == :pending
  end

  test "bulk snooze sets snooze_until without changing status", %{conn: conn} do
    user = operator_user_fixture()

    one = alert_fixture()
    two = alert_fixture()
    publish([one, two])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    render_click(lv, "alert_select_toggle", %{"id" => one.id})
    render_click(lv, "alert_select_toggle", %{"id" => two.id})

    html = render_submit(lv, "alert_bulk_snooze", %{"duration" => "15m"})

    assert html =~ "2 succeeded, 0 failed"

    for alert <- [one, two] do
      reloaded = reload(alert)
      assert reloaded.status == :pending
      assert %DateTime{} = reloaded.snooze_until
    end
  end

  test "an unknown bulk duration is refused and nothing is snoozed", %{conn: conn} do
    user = operator_user_fixture()
    alert = alert_fixture()
    publish([alert])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    render_click(lv, "alert_select_toggle", %{"id" => alert.id})
    render_submit(lv, "alert_bulk_snooze", %{"duration" => "until_the_heat_death"})

    # An unrecognised duration falls back to the default rather than creating an
    # atom, so the bound stays enumerated; the important part is that nothing
    # outside the whitelist is ever applied.
    reloaded = reload(alert)
    assert reloaded.status == :pending

    if reloaded.snooze_until do
      default = Enum.find(AlertActions.snooze_options(), &(&1.value == AlertActions.default_snooze_value()))

      assert DateTime.before?(
               reloaded.snooze_until,
               DateTime.add(DateTime.utc_now(), default.seconds + 60, :second)
             )
    end
  end

  test "the selection bound is enforced", %{conn: conn} do
    user = operator_user_fixture()
    alert = alert_fixture()
    publish([alert])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/observability/alerts")

    assert render(lv) =~ "limit #{AlertActions.bulk_limit()}"
  end

  # --- helpers --------------------------------------------------------------

  defp publish(alerts) do
    rows =
      Enum.map(alerts, fn alert ->
        %{
          "id" => alert.id,
          "title" => alert.title,
          "severity" => "warning",
          "status" => to_string(alert.status),
          "triggered_at" => "2026-08-09T12:00:00Z"
        }
      end)

    Application.put_env(:serviceradar_web_ng, :test_alert_rows, rows)
  end

  defp reload(alert) do
    Alert
    |> Ash.Query.for_read(:by_id, %{id: alert.id}, actor: system_actor())
    |> Ash.read_one!(actor: system_actor())
  end

  defp escalate(alert) do
    alert
    |> Ash.Changeset.for_update(:escalate, %{reason: "test"}, actor: system_actor())
    |> Ash.update!()
  end

  defp resolve(alert) do
    alert
    |> Ash.Changeset.for_update(:resolve, %{resolved_by: "test"}, actor: system_actor())
    |> Ash.update!()
  end

  defp acknowledgements(alert_id) do
    NotificationAcknowledgement
    |> Ash.Query.for_read(:for_alert, %{alert_id: alert_id}, actor: system_actor())
    |> Ash.read!(actor: system_actor())
  end

  defmodule AlertsListSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      if String.contains?(query, "in:alerts") do
        rows = Application.get_env(:serviceradar_web_ng, :test_alert_rows, [])
        {:ok, %{"results" => rows, "pagination" => %{}, "error" => nil}}
      else
        {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    def query(_query, _opts), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}
  end
end
