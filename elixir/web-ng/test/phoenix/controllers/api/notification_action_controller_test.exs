defmodule ServiceRadarWebNGWeb.Api.NotificationActionControllerTest do
  @moduledoc """
  The unauthenticated action-link endpoint, against real rows (task 1.6.3).

  The engine suites already prove the credential scheme and the redemption
  outcomes. What only an HTTP test can prove is the property the endpoint exists
  to hold: a GET is inert. Mail scanners and link previewers fetch every URL in a
  message before a human sees one, so if the GET acted, a spam filter would
  acknowledge the fleet - silently, and with no way to tell afterwards.

  So the first test here does not assert on the page. It asserts that after a
  GET the alert has not moved, no acknowledgement row exists, and the capability
  is still unspent.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.ActionLinks
  alias ServiceRadar.Notifications.ActionToken
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadar.Notifications.NotificationActionToken
  alias ServiceRadar.Notifications.NotificationDelivery

  @base "https://serviceradar.test"
  @provider %{provider_type: :native}
  @title "Device tonka01 is unreachable"

  setup do
    actor = SystemActor.system(:notification_action_controller_test)
    alert = create_alert!(actor)
    delivery = create_delivery!(alert, actor)
    links = issue!(delivery, actor)

    {:ok, actor: actor, alert: alert, delivery: delivery, links: links}
  end

  describe "GET is inert" do
    test "changes nothing at all", %{conn: conn, actor: actor, alert: alert, links: links} do
      minted = minted!(links, :acknowledge)

      conn = get(conn, path_for(minted))

      assert html_response(conn, 200)

      # The three things a GET that acted would have moved.
      assert %{status: :pending, acknowledged_at: nil} = reload!(alert, actor)
      assert acknowledgements(alert.id, actor) == []
      assert %{consumed_at: nil} = token_row!(minted.selector, actor)
    end

    test "renders a confirmation form that POSTs, not a completed action", %{
      conn: conn,
      links: links
    } do
      minted = minted!(links, :acknowledge)
      path = path_for(minted)

      body = conn |> get(path) |> html_response(200)

      assert body =~ "Acknowledge this alert?"
      assert body =~ ~s(method="post")
      assert body =~ path
      refute body =~ "Alert acknowledged"
    end

    test "names the alert and the action, and nothing else about the alert", %{
      conn: conn,
      links: links
    } do
      body = conn |> get(path_for(minted!(links, :snooze))) |> html_response(200)

      assert body =~ @title
      assert body =~ "Critical"
      assert body =~ "Snooze this alert for 1 hour?"

      # The description is the nearest thing to an alert internal that a leaked
      # link must not turn into a read API.
      refute body =~ "ICMP probe failed"
    end

    test "each action link renders its own action", %{conn: conn, links: links} do
      for {action, heading} <- [
            {:acknowledge, "Acknowledge this alert?"},
            {:snooze, "Snooze this alert for 1 hour?"},
            {:resolve, "Resolve this alert?"}
          ] do
        body = conn |> get(path_for(minted!(links, action))) |> html_response(200)
        assert body =~ heading
      end
    end
  end

  describe "POST redeems" do
    test "applies the action, moves the alert, and writes one audit row", %{
      conn: conn,
      actor: actor,
      alert: alert,
      delivery: delivery,
      links: links
    } do
      minted = minted!(links, :acknowledge)

      body = conn |> post(path_for(minted)) |> html_response(200)
      assert body =~ "Alert acknowledged"

      reloaded = reload!(alert, actor)
      assert reloaded.status == :acknowledged
      assert reloaded.acknowledged_at

      assert [acknowledgement] = acknowledgements(alert.id, actor)
      assert acknowledgement.action == :acknowledge
      assert acknowledgement.actor_kind == :external_principal
      assert acknowledgement.source == :action_link
      assert acknowledgement.external_principal == "action_link:" <> delivery.id

      # Single use is a property of the row, not of the request.
      assert %{consumed_at: %DateTime{}} = token_row!(minted.selector, actor)
    end

    test "snooze applies the duration bound into the token, not one from the URL", %{
      conn: conn,
      actor: actor,
      alert: alert,
      links: links
    } do
      minted = minted!(links, :snooze)

      body = conn |> post(path_for(minted) <> "?snooze_seconds=99999") |> html_response(200)
      assert body =~ "Alert snoozed until"

      reloaded = reload!(alert, actor)
      assert reloaded.status == :pending
      assert DateTime.diff(reloaded.snooze_until, DateTime.utc_now(), :second) in 3500..3600
    end

    test "replaying the same token changes nothing a second time", %{
      conn: conn,
      actor: actor,
      alert: alert,
      links: links
    } do
      minted = minted!(links, :acknowledge)
      path = path_for(minted)

      assert build_conn() |> post(path) |> html_response(200) =~ "Alert acknowledged"
      first = reload!(alert, actor)

      body = conn |> post(path) |> html_response(200)
      assert body =~ "This link has already been used"

      second = reload!(alert, actor)
      assert second.acknowledged_at == first.acknowledged_at
      assert length(acknowledgements(alert.id, actor)) == 1
    end

    test "a GET after redemption reports the replay rather than acting again", %{
      conn: conn,
      actor: actor,
      alert: alert,
      links: links
    } do
      minted = minted!(links, :acknowledge)
      path = path_for(minted)

      assert build_conn() |> post(path) |> html_response(200)

      body = conn |> get(path) |> html_response(200)
      assert body =~ "This link has already been used"
      assert length(acknowledgements(alert.id, actor)) == 1
    end

    test "a second, distinct capability for an already-acknowledged alert is audited", %{
      conn: conn,
      actor: actor,
      alert: alert,
      delivery: delivery,
      links: links
    } do
      assert build_conn() |> post(path_for(minted!(links, :acknowledge))) |> html_response(200)

      # The fan-out case: a different delivery of the same alert, clicked second.
      other = issue!(create_delivery!(alert, actor), actor)

      body = conn |> post(path_for(minted!(other, :acknowledge))) |> html_response(200)
      assert body =~ "Already acknowledged"

      principals = alert.id |> acknowledgements(actor) |> Enum.map(& &1.external_principal)
      assert length(principals) == 2
      assert ("action_link:" <> delivery.id) in principals
    end

    test "an alert the action cannot move reports no change and burns nothing", %{
      conn: conn,
      actor: actor,
      alert: alert,
      links: links
    } do
      resolve!(alert, actor)
      minted = minted!(links, :acknowledge)

      body = conn |> post(path_for(minted)) |> html_response(200)
      assert body =~ "Nothing was changed"

      assert reload!(alert, actor).status == :resolved
      assert acknowledgements(alert.id, actor) == []
      assert %{consumed_at: nil} = token_row!(minted.selector, actor)
    end
  end

  describe "failures say only what a bearer already proved" do
    test "an unknown token and a malformed one render the same page", %{conn: conn} do
      unknown = "srn1." <> String.duplicate("a", 16) <> "." <> String.duplicate("b", 43)

      unknown_conn = get(build_conn(), "/api/notifications/actions/" <> unknown)
      malformed_conn = get(conn, "/api/notifications/actions/not-a-token")

      assert unknown_conn.status == 404
      assert malformed_conn.status == 404
      assert unknown_conn.resp_body == malformed_conn.resp_body
      assert unknown_conn.resp_body =~ "This link is not valid"
    end

    test "a wrong secret for a real selector is indistinguishable from an unknown one", %{
      conn: conn,
      links: links
    } do
      minted = minted!(links, :acknowledge)
      [_version, selector, _secret] = String.split(minted.token, ".")
      forged = "srn1." <> selector <> "." <> String.duplicate("b", 43)
      unknown = "srn1." <> String.duplicate("a", 16) <> "." <> String.duplicate("b", 43)

      forged_conn = get(conn, "/api/notifications/actions/" <> forged)
      unknown_conn = get(build_conn(), "/api/notifications/actions/" <> unknown)

      assert forged_conn.status == 404
      assert forged_conn.resp_body == unknown_conn.resp_body

      # Nothing about the real capability leaks through the failure.
      refute forged_conn.resp_body =~ @title
      refute forged_conn.resp_body =~ "Acknowledge"
    end

    test "an expired capability says so, and only that", %{
      conn: conn,
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      minted = expired_token!(delivery, actor)

      response = conn |> get(path_for(minted)) |> html_response(410)

      assert response =~ "This link has expired"
      refute response =~ @title
      assert acknowledgements(alert.id, actor) == []
    end

    test "POSTing an expired capability applies nothing", %{
      conn: conn,
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      minted = expired_token!(delivery, actor)

      assert conn |> post(path_for(minted)) |> html_response(410) =~ "This link has expired"
      assert reload!(alert, actor).status == :pending
      assert acknowledgements(alert.id, actor) == []
    end

    test "a forged token neither acts nor 500s on POST", %{conn: conn, actor: actor, alert: alert} do
      forged = "srn1." <> String.duplicate("a", 16) <> "." <> String.duplicate("b", 43)

      conn = post(conn, "/api/notifications/actions/" <> forged)

      assert conn.status == 404
      assert reload!(alert, actor).status == :pending
      assert acknowledgements(alert.id, actor) == []
    end
  end

  describe "the page keeps the credential in the URL out of caches and logs" do
    test "success, interstitial, and failure all carry the same protective headers", %{
      conn: conn,
      links: links
    } do
      minted = minted!(links, :acknowledge)

      responses = [
        get(build_conn(), path_for(minted)),
        post(build_conn(), path_for(minted)),
        get(conn, "/api/notifications/actions/not-a-token")
      ]

      for response <- responses do
        assert get_resp_header(response, "x-robots-tag") == ["noindex, nofollow, noarchive"]
        assert get_resp_header(response, "referrer-policy") == ["no-referrer"]

        assert [cache_control] = get_resp_header(response, "cache-control")
        assert cache_control =~ "no-store"
      end
    end

    test "the endpoint is reachable with no session and no authorization header", %{links: links} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> delete_req_header("authorization")
        |> get(path_for(minted!(links, :acknowledge)))

      assert html_response(conn, 200) =~ "Acknowledge this alert?"
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp create_alert!(actor) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: @title,
        description: "ICMP probe failed three consecutive times",
        severity: :critical,
        source_type: :service_check,
        source_id: "notification-action-controller-fixture"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_delivery!(alert, actor) do
    now = DateTime.utc_now()

    NotificationDelivery
    |> Ash.Changeset.for_create(
      :record_dispatch,
      %{
        alert_id: alert.id,
        alert_snapshot: %{"id" => alert.id, "title" => alert.title},
        dedupe_key: "notification-action-" <> Ash.UUID.generate(),
        max_attempts: 3,
        queued_at: now,
        next_attempt_at: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp issue!(delivery, actor) do
    {:ok, links} = ActionLinks.issue(delivery, @provider, actor: actor, base_url: @base)
    links
  end

  defp expired_token!(delivery, actor) do
    {:ok, minted} =
      ActionToken.mint(
        %{delivery_id: delivery.id, alert_id: delivery.alert_id, action: :acknowledge},
        now: DateTime.add(DateTime.utc_now(), -7200, :second),
        ttl_seconds: 60
      )

    {:ok, _record} = ActionToken.create(minted, actor: actor)
    minted
  end

  defp resolve!(alert, actor) do
    alert
    |> Ash.Changeset.for_update(:resolve, %{resolved_by: "test"}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  # --- helpers --------------------------------------------------------------

  defp minted!(links, action) do
    Enum.find(links.minted, &(&1.action == action)) ||
      flunk("no #{action} capability was minted")
  end

  defp path_for(minted), do: ActionLinks.action_path(minted.token)

  defp reload!(alert, actor) do
    {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
    reloaded
  end

  defp acknowledgements(alert_id, actor) do
    {:ok, rows} = NotificationAcknowledgement.list_for_alert(alert_id, actor: actor)
    rows
  end

  defp token_row!(selector, actor) do
    {:ok, row} = NotificationActionToken.get_by_selector(selector, actor: actor)
    row
  end
end
