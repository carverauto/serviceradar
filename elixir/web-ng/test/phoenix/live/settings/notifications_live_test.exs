defmodule ServiceRadarWebNGWeb.Settings.NotificationsLiveTest do
  @moduledoc """
  End-to-end authorization and tab behaviour for `/settings/notifications`.

  The decisive test here is the forged-event one: the operator role holds
  `notifications.channels.view` but not `notifications.channels.manage`, so the
  mutation controls are not rendered - and pushing `save_channel` straight at the
  mounted LiveView, bypassing the DOM entirely, must still change nothing.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.NotificationsFixtures

  require Ash.Query

  defp log_in_role(conn, role) do
    user = AccountsFixtures.user_fixture(%{role: role})
    {log_in_user(conn, user), user}
  end

  defp channel_count do
    NotificationChannel
    |> Ash.Query.for_read(:read)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, channels} -> length(channels)
      {:error, _reason} -> 0
    end
  end

  describe "access" do
    test "a scope with no notification permissions is redirected away", %{conn: conn} do
      {conn, _user} = log_in_role(conn, :viewer)

      assert {:error, {redirect, %{to: to}}} = live(conn, ~p"/settings/notifications/channels")
      assert redirect in [:redirect, :live_redirect]
      assert to == ~p"/settings/profile"
    end

    test "an operator reaches the surface and lands on Channels", %{conn: conn} do
      {conn, _user} = log_in_role(conn, :operator)

      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/channels")

      assert html =~ "Notifications"
      assert html =~ "Channels"
    end

    test "the bare path renders the first permitted tab", %{conn: conn} do
      {conn, _user} = log_in_role(conn, :operator)

      {:ok, _lv, html} = live(conn, ~p"/settings/notifications")

      assert html =~ "Channels"
    end

    test "a deep link to a tab renders that tab", %{conn: conn} do
      {conn, _user} = log_in_role(conn, :admin)

      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/deliveries")

      assert html =~ "Delivery Log"
      assert html =~ "why was I not paged"
    end

    test "an unknown tab segment falls back to a permitted tab", %{conn: conn} do
      {conn, _user} = log_in_role(conn, :operator)
      crafted = "not-a-tab-#{System.unique_integer([:positive])}"

      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/#{crafted}")

      assert html =~ "Channels"
    end
  end

  describe "user timezone boundary" do
    @tag :web_ng_shared_fixture_db
    test "persisted profile timezone reaches timestamp-bearing silence rows", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{role: :admin})

      user =
        Ash.update!(user, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: user
        )

      starts_at = ~U[2030-08-09 12:00:00.000000Z]
      ends_at = ~U[2030-08-09 14:00:00.000000Z]

      silence =
        NotificationsFixtures.silence_fixture(%{
          name: "Chicago maintenance",
          starts_at: starts_at,
          ends_at: ends_at
        })

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/settings/notifications/silences")

      assert has_element?(
               view,
               ~s(time#notification-silence-#{silence.id}-starts-at[datetime="2030-08-09T12:00:00.000000Z"])
             )

      assert has_element?(
               view,
               ~s(time#notification-silence-#{silence.id}-starts-at[data-user-time-zone="America/Chicago"])
             )

      assert has_element?(
               view,
               ~s(time#notification-silence-#{silence.id}-ends-at[datetime="2030-08-09T14:00:00.000000Z"])
             )

      assert has_element?(
               view,
               ~s(time#notification-silence-#{silence.id}-ends-at[data-user-time-zone="America/Chicago"])
             )
    end
  end

  describe "read-only operator" do
    setup %{conn: conn} do
      {conn, user} = log_in_role(conn, :operator)
      %{conn: conn, user: user}
    end

    test "mutation controls are not rendered", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/channels")

      refute html =~ "New channel"
      refute html =~ "phx-click=\"edit_channel\""
      refute html =~ "Send test"
    end

    test "a forged save_channel event changes nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      before = channel_count()

      html =
        render_click(lv, "save_channel", %{
          "channel" => %{
            "name" => "forged",
            "provider_id" => Ecto.UUID.generate(),
            "execution_route" => "control_plane",
            "max_attempts" => "3"
          },
          "config" => %{}
        })

      assert html =~ "not authorized"
      assert channel_count() == before
    end

    test "a forged test_channel event performs no egress", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      html = render_click(lv, "test_channel", %{})

      assert html =~ "not authorized"
    end

    test "a forged disable_provider event is refused", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      html = render_click(lv, "disable_provider", %{"id" => Ecto.UUID.generate()})

      assert html =~ "not authorized"
    end
  end

  describe "admin" do
    setup %{conn: conn} do
      {conn, user} = log_in_role(conn, :admin)
      %{conn: conn, user: user}
    end

    test "every tab is offered", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/channels")

      for label <- ["Channels", "Routes and Escalation", "Silences", "Providers", "Delivery Log"] do
        assert html =~ label
      end
    end

    test "channel mutation controls are rendered", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/channels")

      assert html =~ "New channel"
    end

    test "the delivery log filters are reflected in the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/deliveries")

      lv
      |> element("form[phx-change=\"filter_deliveries\"]")
      |> render_change(%{
        "state" => "suppressed",
        "suppression_reason" => "no_matching_route",
        "window" => "24h"
      })

      path = assert_patch(lv)

      assert path =~ "/settings/notifications/deliveries?"
      assert path =~ "state=suppressed"
      assert path =~ "suppression_reason=no_matching_route"
    end

    test "clearing the filters returns to the unfiltered log", %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/settings/notifications/deliveries?#{%{"state" => "failed"}}")

      render_click(lv, "clear_delivery_filters", %{})

      assert assert_patch(lv) == ~p"/settings/notifications/deliveries"
    end
  end
end
