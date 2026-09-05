defmodule ServiceRadarWebNGWeb.AlertLive.ShowTest do
  @moduledoc """
  Acknowledgement controls on the alert detail LiveView.

  The half that matters is the negative path: a scope without
  `observability.alerts.manage` must be refused when the mutating event is sent
  DIRECTLY to the LiveView, not merely denied a rendered button.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadar.Notifications.NotificationDelivery

  require Ash.Query

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.AlertShowSRQLStub)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      end
    end)

    :ok
  end

  describe "authorization" do
    test "a scope without observability.alerts.manage gets no controls", %{conn: conn} do
      user = viewer_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      refute has_element?(lv, "button[phx-click='alert_acknowledge']")
      refute has_element?(lv, "button[phx-click='alert_resolve']")
      refute has_element?(lv, "form[phx-submit='alert_snooze']")
    end

    test "a forged acknowledge event is refused inside handle_event", %{conn: conn} do
      user = viewer_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      html = render_click(lv, "alert_acknowledge", %{})

      assert html =~ "not authorized"
      assert reload(alert).status == :pending
      assert acknowledgements(alert.id) == []
    end

    test "a forged snooze event is refused inside handle_event", %{conn: conn} do
      user = viewer_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      html = render_click(lv, "alert_snooze", %{"duration" => "1h"})

      assert html =~ "not authorized"

      reloaded = reload(alert)
      assert is_nil(reloaded.snooze_until)
      assert reloaded.status == :pending
    end

    test "a forged resolve event is refused inside handle_event", %{conn: conn} do
      user = viewer_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      render_click(lv, "alert_resolve", %{})

      assert reload(alert).status == :pending
    end

    test "an operator holding the permission gets the controls", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert has_element?(lv, "button[phx-click='alert_acknowledge']")
      assert has_element?(lv, "button[phx-click='alert_resolve']")
      assert has_element?(lv, "form[phx-submit='alert_snooze']")
    end
  end

  describe "acknowledge" do
    test "acknowledges an ESCALATED alert and attributes it to the platform user", %{conn: conn} do
      user = operator_user_fixture()
      alert = %{severity: :critical} |> alert_fixture() |> escalate()

      assert alert.status == :escalated

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      render_click(lv, "alert_acknowledge", %{})

      reloaded = reload(alert)
      assert reloaded.status == :acknowledged
      assert reloaded.acknowledged_by_user_id == user.id
      assert reloaded.acknowledged_by == to_string(user.email)
      assert %DateTime{} = reloaded.acknowledged_at
    end

    test "records a NotificationAcknowledgement as a platform user from the UI", %{conn: conn} do
      user = operator_user_fixture()
      alert = escalate(alert_fixture())

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      render_click(lv, "alert_acknowledge", %{})

      assert [row] = acknowledgements(alert.id)
      assert row.action == :acknowledge
      assert row.actor_kind == :platform_user
      assert row.actor_user_id == user.id
      assert row.source == :ui
    end

    test "acknowledging clears an active snooze", %{conn: conn} do
      user = operator_user_fixture()
      alert = snooze(alert_fixture(), 3_600)

      assert reload(alert).snooze_until

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      render_click(lv, "alert_acknowledge", %{})

      reloaded = reload(alert)
      assert reloaded.status == :acknowledged
      assert is_nil(reloaded.snooze_until)
    end

    test "a resolved alert renders acknowledge disabled rather than failing on click", %{conn: conn} do
      user = operator_user_fixture()
      alert = resolve(alert_fixture())

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert has_element?(lv, "button[phx-click='alert_acknowledge'][disabled]")

      # And the event is refused server-side too, not only visually disabled.
      render_click(lv, "alert_acknowledge", %{})
      assert reload(alert).status == :resolved
    end
  end

  describe "snooze" do
    test "sets snooze_until without changing status", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      before = DateTime.utc_now()
      render_submit(lv, "alert_snooze", %{"duration" => "1h"})

      reloaded = reload(alert)

      # Snooze is NOT a state-machine state.
      assert reloaded.status == :pending
      assert %DateTime{} = reloaded.snooze_until
      assert DateTime.after?(reloaded.snooze_until, DateTime.add(before, 3_500, :second))
      assert DateTime.before?(reloaded.snooze_until, DateTime.add(before, 3_700, :second))
    end

    test "renders the derived snoozed badge rather than a snoozed status", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      html = render_submit(lv, "alert_snooze", %{"duration" => "1h"})

      assert html =~ "Snoozed until"
      assert has_element?(lv, "button[phx-click='alert_unsnooze']")
    end

    test "records a snooze acknowledgement carrying snooze_until", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      render_submit(lv, "alert_snooze", %{"duration" => "15m"})

      assert [row] = acknowledgements(alert.id)
      assert row.action == :snooze
      assert row.source == :ui
      assert %DateTime{} = row.snooze_until
    end

    test "an unknown duration is refused and nothing is snoozed", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      html = render_submit(lv, "alert_snooze", %{"duration" => "forever"})

      assert html =~ "valid snooze duration"
      assert is_nil(reload(alert).snooze_until)
    end

    test "clearing the snooze resumes dispatch", %{conn: conn} do
      user = operator_user_fixture()
      alert = snooze(alert_fixture(), 3_600)

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      render_click(lv, "alert_unsnooze", %{})

      assert is_nil(reload(alert).snooze_until)
    end
  end

  describe "acknowledgement attribution" do
    test "distinguishes an external principal from a platform user", %{conn: conn} do
      user = operator_user_fixture()

      alert =
        alert_fixture()
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{acknowledged_by: "slack:U123"},
          actor: system_actor()
        )
        |> Ash.update!()

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert html =~ "External principal"
      assert html =~ "slack:U123"
      refute html =~ "Platform user"
    end
  end

  describe "notification history" do
    @tag :web_ng_shared_fixture_db
    test "renders trigger, lifecycle, and notification instants in the authenticated timezone", %{conn: conn} do
      user =
        then(operator_user_fixture(), fn user ->
          Ash.update!(user, %{timezone: "America/Chicago"},
            action: :update_timezone_preference,
            actor: user
          )
        end)

      alert = alert_fixture()
      next_attempt_at = ~U[2026-08-30 18:30:00.000000Z]
      delivery = retry_delivery(alert, next_attempt_at)

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert has_element?(
               lv,
               ~s(time#alert-triggered-time[datetime="2026-08-09T12:00:00Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-delivery-#{delivery.id}-recorded-time[datetime="2026-08-30T18:00:00.000000Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-delivery-#{delivery.id}-next-attempt-time[datetime="2026-08-30T18:30:00.000000Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-incident-first-seen-time[datetime="2026-08-30T17:00:00Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-incident-last-seen-time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-context-event-time[datetime="2026-08-30T18:15:00Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(#alert-stream time[datetime="2026-08-09T12:00:00Z"][data-user-time-zone="America/Chicago"])
             )

      render_submit(lv, "alert_snooze", %{"duration" => "1h"})
      snoozed = reload(alert)
      snooze_iso = DateTime.to_iso8601(snoozed.snooze_until)

      assert has_element?(
               lv,
               ~s(time#alert-snooze-until-time[datetime="#{snooze_iso}"][data-user-time-zone="America/Chicago"])
             )

      render_click(lv, "alert_acknowledge", %{})
      acknowledged = reload(alert)
      acknowledged_iso = DateTime.to_iso8601(acknowledged.acknowledged_at)

      assert has_element?(
               lv,
               ~s(time#alert-acknowledged-time[datetime="#{acknowledged_iso}"][data-user-time-zone="America/Chicago"])
             )
    end

    test "renders suppressed deliveries with their reason", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      suppression(alert, :silence)
      suppression(alert, :no_matching_route)

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert html =~ "Suppressed"
      assert html =~ "Matched an active silence"
      assert html =~ "No enabled route matched this alert"
    end

    test "test deliveries are distinguished and excluded from the counts", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      suppression(alert, :silence)
      test_dispatch(alert)
      test_dispatch(alert)
      test_dispatch(alert)

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert html =~ "Test send"
      assert html =~ "1 recorded"
      assert html =~ "3 test (not counted)"
    end

    test "an alert with no delivery history says so", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert html =~ "No notification was recorded for this alert"
    end

    test "links into the delivery log filtered to this alert", %{conn: conn} do
      user = operator_user_fixture()
      alert = alert_fixture()

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      assert has_element?(lv, "a[href*='/settings/notifications/deliveries'][href*='#{alert.id}']")
    end

    test "a scope without notifications.deliveries.view gets no history panel", %{conn: conn} do
      user = viewer_user_fixture()
      alert = alert_fixture()

      suppression(alert, :silence)

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/alerts/#{alert.id}")

      refute html =~ "Matched an active silence"
    end
  end

  describe "anomaly finding presentation" do
    @tag :web_ng_shared_fixture_db
    test "names the metric and identity instead of the canned anomaly title", %{conn: conn} do
      user =
        then(operator_user_fixture(), fn user ->
          Ash.update!(user, %{timezone: "America/Chicago"},
            action: :update_timezone_preference,
            actor: user
          )
        end)

      {:ok, lv, html} = live(log_in_user(conn, user), ~p"/alerts/anomaly-alert-1")

      assert html =~ "Anomaly · ifHCInOctets · host01.example.com"
      refute html =~ ">Anomaly Finding<"
      assert html =~ "ifIndex 4"

      # Alerts.triggered_at is timestamp(0) without time zone. SRQL can hand the
      # LiveView an offset-less ISO string; user_time will not hook that shape,
      # so the stream used to render a hyphen next to the severity dots.
      assert has_element?(
               lv,
               ~s(time#alert-triggered-time[datetime="2026-09-04T22:02:56Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-incident-first-seen-time[datetime="2026-09-04T21:57:56Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(time#alert-incident-last-seen-time[datetime="2026-09-04T22:02:56Z"][data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               lv,
               ~s(#alert-stream time[datetime="2026-09-04T22:02:56Z"][data-user-time-zone="America/Chicago"])
             )
    end
  end

  # --- helpers --------------------------------------------------------------

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

  defp snooze(alert, seconds) do
    alert
    |> Ash.Changeset.for_update(
      :snooze,
      %{snooze_until: DateTime.add(DateTime.utc_now(), seconds, :second)},
      actor: system_actor()
    )
    |> Ash.update!()
  end

  defp acknowledgements(alert_id) do
    NotificationAcknowledgement
    |> Ash.Query.for_read(:for_alert, %{alert_id: alert_id}, actor: system_actor())
    |> Ash.read!(actor: system_actor())
  end

  defp suppression(alert, reason) do
    NotificationDelivery
    |> Ash.Changeset.for_create(
      :record_suppression,
      %{
        alert_id: alert.id,
        alert_snapshot: %{"title" => alert.title, "severity" => "warning"},
        suppression_reason: reason
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp test_dispatch(alert) do
    NotificationDelivery
    |> Ash.Changeset.for_create(
      :record_test_dispatch,
      %{
        alert_id: alert.id,
        alert_snapshot: %{"title" => "test send", "severity" => "info"}
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp retry_delivery(alert, next_attempt_at) do
    NotificationDelivery
    |> Ash.Changeset.for_create(
      :record_dispatch,
      %{
        alert_id: alert.id,
        alert_snapshot: %{"title" => alert.title, "severity" => "warning"},
        next_attempt_at: next_attempt_at,
        queued_at: ~U[2026-08-30 18:00:00.000000Z]
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defmodule AlertShowSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      case Regex.run(~r/id:"([^"]+)"/, query) do
        [_, id] -> {:ok, %{"results" => [alert_row(id)], "pagination" => %{}, "error" => nil}}
        _ -> {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    def query(_query, _opts), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp alert_row("anomaly-alert-1") do
      series_key =
        "v2|partition=#{hex("default")}|identity=#{hex("host01.example.com")}|metric=#{hex("ifHCInOctets")}|if_index=#{hex("4")}"

      %{
        "id" => "anomaly-alert-1",
        "title" => "Anomaly Finding",
        "description" => "Causal prediction finding detected",
        "severity" => "critical",
        "status" => "resolved",
        "source_type" => "event",
        "device_uid" => "sr:00000000-0000-4000-8000-000000000001",
        "triggered_at" => "2026-09-04T22:02:56",
        "timestamp" => "2026-09-04T22:02:56",
        "created_at" => "2026-09-04T22:02:56",
        "metadata" => %{
          "incident_rule_id" => "rule-anomaly-1",
          "incident_rule_name" => "causal_prediction_health_finding",
          "incident_group_key" => "device=sr:00000000-0000-4000-8000-000000000001|anomaly.series_key=#{series_key}",
          "incident_group_values" => %{
            "device" => "sr:00000000-0000-4000-8000-000000000001",
            "anomaly.series_key" => series_key
          },
          "incident_first_seen_at" => "2026-09-04T21:57:56",
          "incident_last_seen_at" => "2026-09-04T22:02:56",
          "incident_diagnostics" => %{
            "rule_name" => "causal_prediction_health_finding",
            "group_key" => "device=sr:00000000-0000-4000-8000-000000000001|anomaly.series_key=#{series_key}",
            "group_values" => %{
              "device" => "sr:00000000-0000-4000-8000-000000000001",
              "anomaly.series_key" => series_key
            },
            "first_seen_at" => "2026-09-04T21:57:56",
            "last_seen_at" => "2026-09-04T22:02:56",
            "window_count" => 1,
            "threshold" => 1,
            "window_seconds" => 300
          }
        }
      }
    end

    defp alert_row(id) do
      %{
        "id" => id,
        "title" => "Interface flapping",
        "description" => "Interface flapped 12 times",
        "severity" => "warning",
        "status" => "pending",
        "source_type" => "device",
        "event_time" => "2026-08-30T18:15:00Z",
        "metadata" => %{
          "incident_rule_id" => "rule-1",
          "incident_diagnostics" => %{
            "first_seen_at" => "2026-08-30T17:00:00Z",
            "last_seen_at" => "2026-08-30T18:00:00Z"
          }
        },
        "triggered_at" => "2026-08-09T12:00:00"
      }
    end

    defp hex(value), do: Base.encode16(to_string(value), case: :lower)
  end
end
