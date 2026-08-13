defmodule ServiceRadarWebNGWeb.Settings.NotificationsEditorsTest do
  @moduledoc """
  The authoring paths of `/settings/notifications`, driven end to end as an admin:
  create and edit a channel, run a test send, author a route, and create then
  cancel a silence.

  These are the positive halves of the surface. The negative halves live in
  `notifications_live_test.exs` (controls absent for a read-only operator) and
  `notifications_authorization_test.exs` (every gated event refused when forged),
  so nothing here re-asserts authorization; it asserts that an operator who DOES
  hold the permission gets a stored row that matches what they typed.

  Test send is exercised through the outbound URL guard rather than a live
  destination: the guard runs before any socket is opened, so the assertion is
  real and the suite makes no network request.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.NotificationsFixtures

  require Ash.Query

  setup %{conn: conn} do
    provider = NotificationsFixtures.provider_fixture("webhook")
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{conn: log_in_user(conn, user), user: user, provider: provider}
  end

  describe "channel create" do
    test "the New channel control opens the editor", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      html = lv |> element("button[phx-click='new_channel']") |> render_click()

      assert html =~ "phx-submit=\"save_channel\""
      assert html =~ "Provider configuration"
    end

    test "saves a channel with the configuration that was typed", %{
      conn: conn,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      lv |> element("button[phx-click='new_channel']") |> render_click()

      html =
        render_click(lv, "save_channel", %{
          "channel" => %{
            "name" => "NOC webhook",
            "description" => "Primary receiver",
            "provider_id" => to_string(provider.id),
            "execution_route" => "control_plane",
            "max_attempts" => "5"
          },
          "config" => %{"url" => "https://hooks.example.com/noc"}
        })

      assert html =~ "Channel saved"
      # The editor closes on a successful save; a form still on the page would
      # mean the operator cannot tell the save happened.
      refute html =~ "phx-submit=\"save_channel\""

      channel = channel_named("NOC webhook")

      assert channel.description == "Primary receiver"
      assert channel.provider_id == provider.id
      assert channel.execution_route == :control_plane
      assert channel.max_attempts == 5
      assert channel.config["url"] == "https://hooks.example.com/noc"
      assert channel.enabled
    end

    test "saves a channel when LiveView unused-input keys are in the config", %{
      conn: conn,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      lv |> element("button[phx-click='new_channel']") |> render_click()

      html =
        render_click(lv, "save_channel", %{
          "channel" => %{
            "name" => "NOC webhook unused",
            "provider_id" => to_string(provider.id),
            "execution_route" => "control_plane",
            "max_attempts" => "3"
          },
          "config" => %{
            "url" => "https://hooks.example.com/unused",
            "_unused_url" => "",
            "_unused_method" => ""
          }
        })

      assert html =~ "Channel saved"

      channel = channel_named("NOC webhook unused")

      assert channel.config["url"] == "https://hooks.example.com/unused"
      refute Map.has_key?(channel.config, "_unused_url")
    end

    test "a rejected save reports why and stores nothing", %{conn: conn, provider: provider} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      before = length(NotificationsFixtures.read_all(NotificationChannel))

      html =
        render_click(lv, "save_channel", %{
          "channel" => %{
            "name" => "Missing URL",
            "provider_id" => to_string(provider.id),
            "execution_route" => "control_plane",
            "max_attempts" => "3"
          },
          "config" => %{}
        })

      assert html =~ "Could not save the channel"
      assert length(NotificationsFixtures.read_all(NotificationChannel)) == before
    end
  end

  describe "channel edit" do
    setup %{provider: provider} do
      %{channel: NotificationsFixtures.channel_fixture(%{provider: provider, name: "Pager hook"})}
    end

    test "loads the stored values into the editor", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      html = render_click(lv, "edit_channel", %{"id" => to_string(channel.id)})

      assert html =~ "phx-submit=\"save_channel\""
      assert html =~ "Pager hook"
      assert html =~ channel.config["url"]
    end

    test "saves an edit without creating a second channel", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      before = length(NotificationsFixtures.read_all(NotificationChannel))

      render_click(lv, "edit_channel", %{"id" => to_string(channel.id)})

      html =
        render_click(lv, "save_channel", %{
          "channel" => %{
            "name" => "Pager hook (renamed)",
            "provider_id" => to_string(channel.provider_id),
            "execution_route" => "control_plane",
            "max_attempts" => "7"
          },
          "config" => %{"url" => channel.config["url"]}
        })

      assert html =~ "Channel saved"

      reloaded = reload_channel(channel.id)

      assert reloaded.name == "Pager hook (renamed)"
      assert reloaded.max_attempts == 7
      assert length(NotificationsFixtures.read_all(NotificationChannel)) == before
    end
  end

  describe "test send" do
    test "refuses a non-public destination before any request is made", %{
      conn: conn,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      lv |> element("button[phx-click='new_channel']") |> render_click()

      render_click(lv, "validate_channel", %{
        "channel" => %{"name" => "Loopback", "provider_id" => to_string(provider.id)},
        "config" => %{"url" => "https://127.0.0.1/hook"}
      })

      html = lv |> element("button[phx-click='test_channel']") |> render_click()

      assert html =~ "Outbound URL refused"

      # The detail names the configuration key it came from, so an operator with
      # more than one URL field knows which one was rejected, AND names the rule
      # that refused it rather than an atom. `TestSend.url_rejection/1` previously
      # matched on four atoms nothing returns, so every host refusal fell through
      # to a generic `(:disallowed_host)` - which is exactly the "leaves an operator
      # guessing" outcome that function exists to prevent.
      assert html =~ "url: the host is not allowed"
      refute html =~ "rejected by the outbound URL policy"
    end

    test "reports a rejection for a URL that is not HTTPS", %{conn: conn, provider: provider} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      lv |> element("button[phx-click='new_channel']") |> render_click()

      render_click(lv, "validate_channel", %{
        "channel" => %{"name" => "Plaintext", "provider_id" => to_string(provider.id)},
        "config" => %{"url" => "http://hooks.example.com/plain"}
      })

      html = render_click(lv, "test_channel", %{})

      assert html =~ "Outbound URL refused"
      assert html =~ "url: only https:// URLs are allowed"
      refute html =~ "rejected by the outbound URL policy"
    end

    test "a typed Discord webhook is a test secret, not a missing credential ref", %{
      conn: conn
    } do
      provider = NotificationsFixtures.provider_fixture("discord")
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      lv |> element("button[phx-click='new_channel']") |> render_click()

      render_click(lv, "validate_channel", %{
        "channel" => %{"name" => "Farm discord", "provider_id" => to_string(provider.id)},
        "config" => %{
          "webhook_url" => "https://127.0.0.1/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
        }
      })

      html = render_click(lv, "test_channel", %{})

      refute html =~ "is required and must be a stored credential reference"
      assert html =~ "Outbound URL refused"
      assert html =~ "webhook_url: the host is not allowed"
    end

    test "a test send from an unsaved form persists no channel", %{conn: conn, provider: provider} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/channels")

      before = length(NotificationsFixtures.read_all(NotificationChannel))

      lv |> element("button[phx-click='new_channel']") |> render_click()

      render_click(lv, "validate_channel", %{
        "channel" => %{"name" => "Never saved", "provider_id" => to_string(provider.id)},
        "config" => %{"url" => "https://127.0.0.1/hook"}
      })

      render_click(lv, "test_channel", %{})

      assert length(NotificationsFixtures.read_all(NotificationChannel)) == before
    end
  end

  describe "route authoring" do
    setup do
      %{policy: NotificationsFixtures.escalation_policy_fixture(%{name: "Pager policy"})}
    end

    test "stores the predicate the builder rows describe", %{conn: conn, policy: policy} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/routes")

      lv |> element("button[phx-click='new_route']") |> render_click()

      html =
        render_click(lv, "save_route", %{
          "route" => %{
            "name" => "Critical to pager",
            "priority" => "10",
            "escalation_policy_id" => to_string(policy.id),
            "combinator" => "all",
            "group_wait_seconds" => "0",
            "continue" => "false",
            "rows" => %{
              "0" => %{"field" => "alert.severity", "operator" => "equals", "value" => "critical"}
            }
          }
        })

      assert html =~ "Route saved"

      route = route_named("Critical to pager")

      assert route.priority == 10
      assert route.escalation_policy_id == policy.id

      assert route.match_expression == %{
               "all" => [%{"field" => "alert.severity", "equals" => "critical"}]
             }

      assert route.enabled
    end

    test "a field outside the allow-list is refused with an actionable message", %{
      conn: conn,
      policy: policy
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/routes")

      before = length(NotificationsFixtures.read_all(NotificationRoute))

      lv |> element("button[phx-click='new_route']") |> render_click()

      html =
        render_click(lv, "save_route", %{
          "route" => %{
            "name" => "Bogus field",
            "priority" => "20",
            "escalation_policy_id" => to_string(policy.id),
            "combinator" => "all",
            "group_wait_seconds" => "0",
            "rows" => %{
              "0" => %{"field" => "alert.secret_column", "operator" => "equals", "value" => "x"}
            }
          }
        })

      assert html =~ "is not a matchable field"
      assert length(NotificationsFixtures.read_all(NotificationRoute)) == before
    end

    test "toggling a route off is an auditable act that keeps the row", %{
      conn: conn,
      policy: policy
    } do
      route = NotificationsFixtures.route_fixture(%{escalation_policy_id: policy.id})

      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/routes")

      render_click(lv, "toggle_route", %{"id" => to_string(route.id)})

      refute reload_route(route.id).enabled
    end
  end

  describe "silences" do
    test "creates a silence attributed to the authenticated user", %{conn: conn, user: user} do
      other = AccountsFixtures.user_fixture(%{role: :viewer})
      now = DateTime.utc_now()

      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/silences")

      lv |> element("button[phx-click='new_silence']") |> render_click()

      html =
        render_click(lv, "save_silence", %{
          "silence" => %{
            "name" => "DB maintenance",
            "comment" => "Planned failover",
            "combinator" => "all",
            "starts_at" => local_input(now),
            "ends_at" => local_input(DateTime.add(now, 3600, :second)),
            # A crafted creator id must be ignored: the creator is taken from
            # the authenticated scope, never from the form.
            "created_by_user_id" => to_string(other.id),
            "rows" => %{
              "0" => %{"field" => "alert.severity", "operator" => "equals", "value" => "warning"}
            }
          }
        })

      assert html =~ "Silence saved"

      silence = silence_named("DB maintenance")

      assert silence.comment == "Planned failover"

      assert silence.matchers == %{
               "all" => [%{"field" => "alert.severity", "equals" => "warning"}]
             }

      assert silence.created_by_user_id == user.id
      refute silence.created_by_user_id == other.id
      assert silence.state == :scheduled
    end

    test "a silence with no justification is refused", %{conn: conn} do
      now = DateTime.utc_now()
      before = length(NotificationsFixtures.read_all(NotificationSilence))

      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/silences")

      lv |> element("button[phx-click='new_silence']") |> render_click()

      render_click(lv, "save_silence", %{
        "silence" => %{
          "name" => "No reason given",
          "comment" => "",
          "combinator" => "all",
          "starts_at" => local_input(now),
          "ends_at" => local_input(DateTime.add(now, 3600, :second)),
          "rows" => %{
            "0" => %{"field" => "alert.severity", "operator" => "equals", "value" => "warning"}
          }
        }
      })

      assert length(NotificationsFixtures.read_all(NotificationSilence)) == before
    end

    test "cancelling a silence stops suppression and keeps the audit row", %{conn: conn} do
      silence = NotificationsFixtures.silence_fixture(%{name: "Cancel me"})

      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/silences")

      confirmation = render_click(lv, "confirm_cancel_silence", %{"id" => to_string(silence.id)})
      assert confirmation =~ "Cancel silence"

      html = render_click(lv, "cancel_silence", %{"id" => to_string(silence.id)})

      assert html =~ "Silence cancelled"
      assert reload_silence(silence.id).state == :cancelled

      # Cancelling is auditable, so the row stays listed rather than vanishing.
      assert html =~ "Cancel me"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp local_input(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

  defp channel_named(name) do
    NotificationChannel
    |> NotificationsFixtures.read_all()
    |> Enum.find(&(&1.name == name))
    |> tap(&refute(is_nil(&1), "no channel named #{name}"))
  end

  defp route_named(name) do
    NotificationRoute
    |> NotificationsFixtures.read_all()
    |> Enum.find(&(&1.name == name))
    |> tap(&refute(is_nil(&1), "no route named #{name}"))
  end

  defp silence_named(name) do
    NotificationSilence
    |> NotificationsFixtures.read_all()
    |> Enum.find(&(&1.name == name))
    |> tap(&refute(is_nil(&1), "no silence named #{name}"))
  end

  defp reload_channel(id) do
    NotificationChannel |> NotificationsFixtures.read_all() |> Enum.find(&(&1.id == id))
  end

  defp reload_route(id) do
    NotificationRoute |> NotificationsFixtures.read_all() |> Enum.find(&(&1.id == id))
  end

  defp reload_silence(id) do
    NotificationSilence |> NotificationsFixtures.read_all() |> Enum.find(&(&1.id == id))
  end
end
