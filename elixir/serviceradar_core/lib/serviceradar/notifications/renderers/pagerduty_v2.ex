defmodule ServiceRadar.Notifications.Renderers.PagerdutyV2 do
  @moduledoc """
  `:pagerduty_v2` - a PagerDuty Events API v2 event.

  ## `dedup_key` is the notification dedupe key, and that is the whole point

  PagerDuty correlates a `trigger` and its later `resolve` by `dedup_key` alone.
  Emit a fresh key per dispatch and every renotify opens a NEW incident, the
  resolve closes nothing, and an on-call engineer wakes to a pile of duplicate
  pages that no longer clear themselves - which is precisely the failure the
  platform's dedupe key exists to prevent.

  So `dedup_key` here is `Content.dedupe_key`, the same
  `NotificationDelivery.dedupe_key` derived from the incident identity
  `{rule_id, group_key}` (design D6), unchanged between the firing and the
  resolution event. It is not derived from the delivery id, the attempt, or the
  escalation step, all of which differ across the events that must correlate.

  ## What is deliberately absent

  `routing_key` is the PagerDuty integration secret. It is NOT rendered here: it
  is resolved by the transport through `ServiceRadar.Credentials.SecretBroker`
  and merged at send time, so it never appears in a rendered payload, in a
  payload digest, or in a log line.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @summary_limit 1024

  # PagerDuty accepts exactly four severities. Anything unrecognised maps to
  # "error" rather than being dropped: a page that arrives with the wrong
  # severity is recoverable, a 400 that loses it is not.
  @severities %{
    "critical" => "critical",
    "crit" => "critical",
    "fatal" => "critical",
    "emergency" => "critical",
    "p1" => "critical",
    "high" => "error",
    "error" => "error",
    "major" => "error",
    "p2" => "error",
    "medium" => "warning",
    "warning" => "warning",
    "warn" => "warning",
    "minor" => "warning",
    "p3" => "warning",
    "low" => "info",
    "info" => "info",
    "informational" => "info",
    "debug" => "info",
    "p4" => "info",
    "p5" => "info"
  }
  @default_severity "error"

  @event_actions %{trigger: "trigger", resolve: "resolve"}

  @impl true
  def payload_format, do: :pagerduty_v2

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    compact(%{
      "event_action" => event_action(content.event_action),
      "dedup_key" => presence(content.dedupe_key),
      "client" => "ServiceRadar",
      "client_url" => presence(content.alert_url),
      "payload" => payload(content),
      "links" => links(content)
    })
  end

  defp event_action(action), do: Map.get(@event_actions, action, "trigger")

  defp payload(content) do
    compact(%{
      "summary" => truncate(Content.summary(content), @summary_limit),
      "severity" => severity(content.severity),
      "source" => presence(content.source) || "serviceradar",
      "timestamp" => presence(content.timestamp),
      "class" => presence(content.alert_class),
      "group" => presence(content.dedupe_key),
      "custom_details" => custom_details(content)
    })
  end

  defp severity(value) do
    case presence(value) do
      nil -> @default_severity
      severity -> Map.get(@severities, String.downcase(severity), @default_severity)
    end
  end

  defp custom_details(content) do
    compact(%{
      "body" => presence(content.body),
      "alert_id" => presence(content.alert_id),
      "alert_class" => presence(content.alert_class),
      "dedupe_key" => presence(content.dedupe_key),
      "raw_severity" => presence(content.severity)
    })
  end

  defp links(content) do
    action_links =
      content
      |> Content.action_links()
      |> Enum.map(fn %{label: label, url: url} -> %{"href" => url, "text" => label} end)

    case presence(content.alert_url) do
      nil -> action_links
      url -> [%{"href" => url, "text" => "View in ServiceRadar"} | action_links]
    end
  end
end
