defmodule ServiceRadarWebNGWeb.Settings.NotificationsAuthorizationTest do
  @moduledoc """
  Every gated event on `/settings/notifications`, forged at a mounted LiveView by
  a user who does not hold the permission it requires.

  A hidden button is not authorization. `notifications_live_test.exs` proves the
  controls are absent for a read-only operator; this file proves the events are
  refused when the DOM is bypassed entirely, across the WHOLE event surface
  rather than a sample, and that the notification tables are unchanged
  afterwards.

  The under-privileged actor is a `:helpdesk` user, chosen because the shipped
  role defaults grant it exactly one of the nine `notifications.*` keys -
  `notifications.deliveries.view`. It can therefore MOUNT the surface, which a
  viewer cannot (a viewer is redirected away and can forge nothing), while
  holding none of the five permissions that gate a mutation.

  Every forged event names a REAL row created in `setup`. That is what makes the
  sweep a trap rather than a tautology: if the gate were removed, `disable_channel`
  would disable an existing channel and `cancel_silence` would cancel an existing
  silence, and the before/after snapshot would catch it.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.NotificationsFixtures
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Access, as: NotificationsAccess

  @refusal "not authorized"

  # The gated event surface, grouped by the permission each group requires. The
  # groups are compared against the module's own declaration in
  # "the sweep covers every declared event", so an event added to the LiveView
  # without a test here fails rather than silently going untested.
  @channel_manage_events ~w(
    new_channel
    edit_channel
    cancel_channel_form
    validate_channel
    save_channel
    confirm_disable_channel
    disable_channel
    enable_channel
  )

  @test_send_events ~w(test_channel)

  @route_manage_events ~w(
    new_route
    edit_route
    cancel_route_form
    validate_route
    save_route
    toggle_route
    move_route
    add_predicate_row
    remove_predicate_row
    new_policy
    edit_policy
    cancel_policy_form
    validate_policy
    save_policy
    add_step
    remove_step
    move_step
  )

  @silence_manage_events ~w(
    new_silence
    edit_silence
    cancel_silence_form
    validate_silence
    save_silence
    confirm_cancel_silence
    cancel_silence
  )

  @provider_manage_events ~w(
    confirm_disable_provider
    disable_provider
    enable_provider
    new_provider_upload
    replace_provider_definition
    cancel_provider_upload
    validate_provider_upload
    save_provider_upload
    show_provider_versions
    close_provider_versions
    confirm_rollback_provider
    rollback_provider
  )

  # Not mutations, but still gated: a helpdesk user holds neither
  # `notifications.channels.view` nor `notifications.routes.view`, and
  # `preview_routing` runs the routing engine over recent alerts.
  @read_gated_events ~w(dismiss_confirmation preview_routing)

  # The four events a helpdesk user DOES hold, through
  # `notifications.deliveries.view`. They are the positive control below.
  @permitted_events ~w(filter_deliveries clear_delivery_filters show_delivery close_delivery)

  @gated_events @channel_manage_events ++
                  @test_send_events ++
                  @route_manage_events ++
                  @silence_manage_events ++
                  @provider_manage_events ++ @read_gated_events

  setup %{conn: conn} do
    provider = NotificationsFixtures.provider_fixture("webhook")
    channel = NotificationsFixtures.channel_fixture(%{provider: provider})
    policy = NotificationsFixtures.escalation_policy_fixture()
    route = NotificationsFixtures.route_fixture(%{escalation_policy_id: policy.id})
    silence = NotificationsFixtures.silence_fixture()

    user = AccountsFixtures.user_fixture(%{role: :helpdesk})

    %{
      conn: log_in_user(conn, user),
      user: user,
      fixtures: %{
        provider: provider,
        channel: channel,
        policy: policy,
        route: route,
        silence: silence
      }
    }
  end

  describe "the helpdesk scope" do
    test "reaches the surface but holds no mutating permission", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/notifications/deliveries")

      assert html =~ "Delivery Log"
      refute html =~ "New channel"
      refute html =~ "phx-click=\"new_route\""
      refute html =~ "phx-click=\"new_silence\""
    end

    test "sees only the delivery log tab", %{user: user} do
      scope = %Scope{
        user: user,
        permissions: ServiceRadarWebNG.RBAC.permissions_for_scope(%Scope{user: user})
      }

      ids = scope |> NotificationsAccess.visible_tabs() |> Enum.map(& &1.id)

      assert ids == ["deliveries"]
    end
  end

  describe "forged events" do
    test "every channel-management event is refused", context do
      assert_all_refused(context, @channel_manage_events)
    end

    test "the test-send event is refused", context do
      assert_all_refused(context, @test_send_events)
    end

    test "every route and escalation event is refused", context do
      assert_all_refused(context, @route_manage_events)
    end

    test "every silence event is refused", context do
      assert_all_refused(context, @silence_manage_events)
    end

    test "every provider event is refused", context do
      assert_all_refused(context, @provider_manage_events)
    end

    test "the read-scoped events outside the delivery log are refused", context do
      assert_all_refused(context, @read_gated_events)
    end

    test "no editor, confirmation, or test result is ever opened by the sweep", context do
      %{conn: conn, fixtures: fixtures} = context
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/deliveries")

      html =
        Enum.reduce(@gated_events, nil, fn event, _acc ->
          render_click(lv, event, params_for(event, fixtures))
        end)

      # A refused event must not have reached a handler, so none of the editors
      # a handler opens may be in the DOM.
      for form <- ~w(save_channel save_route save_policy save_silence save_provider_upload) do
        refute html =~ "phx-submit=\"#{form}\"",
               "the #{form} editor was opened by a refused event"
      end

      refute html =~ "phx-click=\"dismiss_confirmation\"",
             "a confirmation dialog was opened by a refused event"
    end

    test "the whole sweep leaves every notification row untouched", context do
      %{conn: conn, fixtures: fixtures} = context
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/deliveries")

      before = snapshot()

      for event <- @gated_events do
        html = render_click(lv, event, params_for(event, fixtures))
        assert html =~ @refusal, "#{event} was not refused"
      end

      assert snapshot() == before
    end
  end

  describe "positive control" do
    test "the delivery log events the helpdesk scope does hold are not refused", %{conn: conn} do
      # Without this, "everything was refused" would also be satisfied by a
      # LiveView that refuses every event for every user.
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/deliveries")

      html = render_click(lv, "filter_deliveries", %{"state" => "failed", "window" => "24h"})

      refute html =~ @refusal

      path = assert_patch(lv)
      assert path =~ "state=failed"
    end
  end

  describe "coverage" do
    test "the sweep covers every declared event" do
      declared = declared_events()
      covered = MapSet.new(@gated_events ++ @permitted_events)

      assert MapSet.equal?(declared, covered),
             """
             The declared event map and this test's event list disagree.
             Declared but not swept: #{inspect(MapSet.to_list(MapSet.difference(declared, covered)))}
             Swept but not declared: #{inspect(MapSet.to_list(MapSet.difference(covered, declared)))}
             """
    end

    test "every swept event is genuinely declared and genuinely gated" do
      for event <- @gated_events do
        assert NotificationsAccess.permission_for_event(event),
               "#{event} is not a declared event, so refusing it proves nothing"
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp assert_all_refused(%{conn: conn, fixtures: fixtures}, events) do
    {:ok, lv, _html} = live(conn, ~p"/settings/notifications/deliveries")

    for event <- events do
      html = render_click(lv, event, params_for(event, fixtures))

      assert html =~ @refusal,
             "#{event} was not refused for a scope lacking #{NotificationsAccess.permission_for_event(event)}"
    end
  end

  # Real ids, real form payloads. A refusal only means something if the handler
  # behind it would have done real work.
  defp params_for(event, f) when event in ~w(edit_channel confirm_disable_channel disable_channel enable_channel) do
    %{"id" => to_string(f.channel.id)}
  end

  defp params_for(event, f) when event in ~w(validate_channel save_channel) do
    %{
      "channel" => %{
        "name" => "forged channel",
        "provider_id" => to_string(f.provider.id),
        "execution_route" => "control_plane",
        "max_attempts" => "3"
      },
      "config" => %{"url" => "https://hooks.example.com/forged"}
    }
  end

  defp params_for(event, f) when event in ~w(edit_route toggle_route) do
    %{"id" => to_string(f.route.id)}
  end

  defp params_for("move_route", f), do: %{"id" => to_string(f.route.id), "direction" => "up"}

  defp params_for(event, f) when event in ~w(validate_route save_route) do
    %{
      "route" => %{
        "name" => "forged route",
        "priority" => "1",
        "escalation_policy_id" => to_string(f.policy.id),
        "combinator" => "all",
        "group_wait_seconds" => "0",
        "continue" => "false",
        "rows" => %{"0" => %{"field" => "alert.severity", "operator" => "equals", "value" => "critical"}}
      }
    }
  end

  defp params_for("edit_policy", f), do: %{"id" => to_string(f.policy.id)}

  defp params_for(event, f) when event in ~w(validate_policy save_policy) do
    %{
      "policy" => %{
        "name" => "forged policy",
        "repeat_count" => "0",
        "steps" => %{
          "0" => %{
            "delay_seconds" => "0",
            "channel_ids" => [to_string(f.channel.id)]
          }
        }
      }
    }
  end

  defp params_for(event, _f) when event in ~w(remove_predicate_row remove_step) do
    %{"index" => "0"}
  end

  defp params_for("move_step", _f), do: %{"index" => "0", "direction" => "down"}

  defp params_for(event, f) when event in ~w(edit_silence confirm_cancel_silence cancel_silence) do
    %{"id" => to_string(f.silence.id)}
  end

  defp params_for(event, _f) when event in ~w(validate_silence save_silence) do
    now = DateTime.utc_now()

    %{
      "silence" => %{
        "name" => "forged silence",
        "comment" => "forged",
        "combinator" => "all",
        "starts_at" => local_input(now),
        "ends_at" => local_input(DateTime.add(now, 3600, :second)),
        "rows" => %{"0" => %{"field" => "alert.severity", "operator" => "equals", "value" => "warning"}}
      }
    }
  end

  defp params_for(event, f)
       when event in ~w(confirm_disable_provider disable_provider enable_provider replace_provider_definition show_provider_versions) do
    %{"id" => to_string(f.provider.id)}
  end

  defp params_for(event, f) when event in ~w(confirm_rollback_provider rollback_provider) do
    %{"id" => to_string(f.provider.id), "version" => "1"}
  end

  # A document that WOULD create a provider if the gate let it through. A forged
  # upload carrying nothing provable would make the refusal meaningless.
  defp params_for(event, _f) when event in ~w(validate_provider_upload save_provider_upload) do
    %{
      "provider" => %{
        "document" => """
        schema_version: 1
        key: forged_pager
        display_name: Forged Pager
        capabilities: [send, test]
        payload_formats: [markdown]
        config_schema:
          type: object
          properties:
            webhook_url:
              type: string
        request:
          method: POST
          url: "{{ config.webhook_url }}"
          headers:
            Content-Type: application/json
          body_format: json
          body:
            text: "{{ alert.title }}"
        success:
          status: [200]
        failure:
          retryable_status: [500]
        """
      }
    }
  end

  defp params_for(_event, _f), do: %{}

  defp local_input(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

  # Read back with the system actor, not the viewer's scope: a scope-scoped read
  # would return the same empty list whether the row survived or not.
  defp snapshot do
    %{
      channels:
        NotificationChannel
        |> NotificationsFixtures.read_all()
        |> Enum.map(&Map.take(&1, [:id, :name, :enabled, :config, :execution_route, :max_attempts]))
        |> Enum.sort_by(& &1.id),
      routes:
        NotificationRoute
        |> NotificationsFixtures.read_all()
        |> Enum.map(&Map.take(&1, [:id, :name, :enabled, :priority, :match_expression]))
        |> Enum.sort_by(& &1.id),
      policies:
        NotificationEscalationPolicy
        |> NotificationsFixtures.read_all()
        |> Enum.map(&Map.take(&1, [:id, :name, :enabled, :repeat_count]))
        |> Enum.sort_by(& &1.id),
      silences:
        NotificationSilence
        |> NotificationsFixtures.read_all()
        |> Enum.map(&Map.take(&1, [:id, :name, :state, :starts_at, :ends_at, :matchers]))
        |> Enum.sort_by(& &1.id),
      providers:
        NotificationProvider
        |> NotificationsFixtures.read_all()
        |> Enum.map(&Map.take(&1, [:id, :provider_key, :status, :definition_version, :definition]))
        |> Enum.sort_by(& &1.id)
    }
  end

  # The declared event map is a private module attribute, so it is read from the
  # module's own source. Deriving it is the point: a hard-coded list here would
  # go stale the moment an event is added, which is exactly the regression this
  # test exists to catch.
  defp declared_events do
    ~r/^\s*"([a-z_]+)"\s*=>\s*@[a-z_]+,?\s*$/m
    |> Regex.scan(File.read!(access_source()))
    |> MapSet.new(fn [_line, event] -> event end)
  end

  defp access_source do
    compiled =
      :compile |> NotificationsAccess.module_info() |> Keyword.get(:source) |> to_string()

    fallback =
      Path.expand(
        "../../../../lib/serviceradar_web_ng_web/live/settings/notifications_live/access.ex",
        __DIR__
      )

    cond do
      File.regular?(compiled) -> compiled
      File.regular?(fallback) -> fallback
      true -> flunk("cannot locate the Access module source at #{compiled} or #{fallback}")
    end
  end
end
