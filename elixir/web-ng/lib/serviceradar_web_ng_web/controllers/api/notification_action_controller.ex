defmodule ServiceRadarWebNGWeb.Api.NotificationActionController do
  @moduledoc """
  The page an operator lands on when they click `Acknowledge`, `Snooze 1h`, or
  `Resolve` inside a notification (design D7 Phase 1, tasks 1.6.3 - 1.6.5).

  It owns no policy of its own. `ServiceRadar.Notifications.ActionToken` decides
  whether a presented capability is real and
  `ServiceRadar.Notifications.ActionRedemption` decides what a real one does;
  everything here is transport, presentation, and the two protections that only
  exist at the HTTP edge - the interstitial and the per-IP limit.

  ## The GET does not act. Ever.

  Corporate mail scanners, link previewers, and chat unfurlers issue a request
  for every URL in a message before a human sees it. A GET that acknowledged
  would let a spam filter silently acknowledge every alert the platform sends,
  and the operator would never learn the page had been fetched.

  So `show/2` renders a confirmation interstitial and performs no state change:
  it calls `ActionToken.verify/2`, which is a read, and never `consume/2` or
  `ActionRedemption.redeem/2`. The human's form submission is what redeems, in
  `create/2`. That split is the whole reason this endpoint is two actions
  instead of one.

  ## Unauthenticated by design

  There is no session and no platform user behind a link click: the capability
  IS the authorisation, scoped to one delivery and one action, single use, and
  three days long. The route therefore sits outside every auth pipeline, which
  puts three obligations on this controller:

    * **Say nothing a bearer has not already proved.** A failed verification
      renders one of exactly two answers, from
      `ActionToken.public_reason/1`: `:expired` (reachable only after the digest
      verified, so it tells a real bearer nothing new) or `:invalid` (everything
      else - unknown selector, wrong secret, malformed token, pruned alert -
      collapsed into one page so the endpoint cannot enumerate deliveries).
      A success page names the alert's title, severity, and time, and nothing
      else about it.
    * **Stay out of caches and indexes.** The URL contains a live credential, so
      the response is `no-store`, `X-Robots-Tag: noindex`, and `no-referrer` -
      the last so a click on "Open in ServiceRadar" does not hand the token to
      the next page in a `Referer` header.
    * **Cost something to guess.** The router applies a per-IP limit to the
      scope, and every failure is recorded as a `:policy_denied` security event
      carrying the client IP and the public reason - never the token or its
      selector, which would put a credential in the audit log.

  There is no CSRF token on the interstitial form and that is deliberate: an
  attacker who could forge the submission would need the capability token to
  address it, and holding the token they could simply POST it themselves. A
  hidden form field would add a session cookie dependency to a page that is
  routinely opened from a mail client, and buy nothing.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.ActionRedemption
  alias ServiceRadar.Notifications.ActionToken
  alias ServiceRadar.Security.Events
  alias ServiceRadarWebNGWeb.ClientIP

  plug :put_capability_page_headers

  @doc """
  Renders the confirmation interstitial. Performs no state change.
  """
  def show(conn, %{"token" => token}) do
    case ActionToken.verify(token, actor: actor()) do
      {:ok, :active, record} ->
        conn
        |> assign(:submit_path, conn.request_path)
        |> assign(:action, record.action)
        |> assign(:snooze_seconds, Map.get(record, :snooze_seconds))
        |> assign(:alert, alert_summary(record.alert_id))
        |> render(:interstitial)

      # A capability that is already spent is a receipt, not a credential. Saying
      # so is truthful and still changes nothing.
      {:ok, :already_consumed, record} ->
        render_outcome(conn, :replayed, record.action, nil, record.alert_id)

      {:error, reason} ->
        render_failure(conn, reason)
    end
  end

  @doc """
  Redeems the capability. This is the only action that changes anything.
  """
  def create(conn, %{"token" => token}) do
    case ActionRedemption.redeem(token, actor: actor()) do
      {:ok, outcome} ->
        render_outcome(
          conn,
          outcome.status,
          outcome.action,
          outcome.snooze_until,
          outcome.alert_id
        )

      # Reachable only for a bearer whose digest already verified, so it is not
      # an enumeration oracle - but the alert's status is still more than this
      # page owes anyone, so the answer names the outcome and not the state.
      {:error, {:alert_not_actionable, _status}} ->
        render_outcome(conn, :not_actionable, nil, nil, nil)

      {:error, reason} ->
        render_failure(conn, reason)
    end
  end

  # --- rendering ------------------------------------------------------------

  # The result page reports the instant a snooze runs to, never a duration
  # recomputed from the wall clock. `DateTime.diff/3` against `utc_now/0` returns
  # 3599 for an hour that has already been running for a millisecond, and
  # "snoozed for 59 minutes" reads as a bug in the platform.
  defp render_outcome(conn, outcome, action, snooze_until, alert_id) do
    conn
    |> assign(:outcome, outcome)
    |> assign(:action, action)
    |> assign(:snooze_until, snooze_until)
    |> assign(:alert, alert_summary(alert_id))
    |> render(:result)
  end

  # One template, one reason, whatever the cause. `public_reason/1` is what keeps
  # "no such selector" and "wrong secret" indistinguishable here.
  defp render_failure(conn, reason) do
    public_reason = ActionToken.public_reason(reason)
    record_failure(conn, public_reason)

    conn
    |> put_status(failure_status(public_reason))
    |> assign(:reason, public_reason)
    |> render(:failure)
  end

  defp failure_status(:expired), do: :gone
  defp failure_status(_reason), do: :not_found

  # --- alert summary --------------------------------------------------------

  # Title, severity, and time. Nothing else about the alert reaches an
  # unauthenticated page, so a leaked link does not become a read API.
  defp alert_summary(nil), do: nil

  defp alert_summary(alert_id) do
    case Alert.get_by_id(alert_id, actor: actor()) do
      {:ok, %{} = alert} ->
        %{
          id: alert.id,
          title: alert.title,
          severity: alert.severity,
          triggered_at: alert.triggered_at
        }

      _other ->
        nil
    end
  end

  # --- audit ----------------------------------------------------------------

  # The token and its selector are deliberately absent: an audit row is not a
  # place to write a credential, and the client IP plus the public reason is what
  # a responder needs to spot a link being guessed at.
  #
  # `:route` is the literal scope and NOT `conn.request_path`, which every other
  # caller of `Events.record/1` passes - here the path IS the credential.
  defp record_failure(conn, public_reason) do
    Events.record(%{
      kind: :policy_denied,
      severity: :warning,
      ip: ClientIP.get(conn),
      route: "/api/notifications/actions",
      details: %{
        "surface" => "notification_action_link",
        "reason" => Atom.to_string(public_reason),
        "method" => conn.method
      }
    })
  rescue
    # Recording an audit row must never be what breaks the request path.
    _error -> :ok
  end

  # --- headers --------------------------------------------------------------

  defp put_capability_page_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-robots-tag", "noindex, nofollow, noarchive")
    # Overrides the pipeline default. The URL is a credential; no other origin,
    # and no other page on this one, needs it in a `Referer`.
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp actor, do: SystemActor.system(:notification_action_link)
end
