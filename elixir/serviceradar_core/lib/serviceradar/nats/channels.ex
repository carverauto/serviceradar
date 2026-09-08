defmodule ServiceRadar.NATS.Channels do
  @moduledoc """
  NATS channel management for single-deployment instances.

  Channels are unprefixed because each deployment is isolated at the NATS
  account level.

  ## Standard Channels

  - `gateways.heartbeat` - Gateway heartbeat messages
  - `gateways.status` - Gateway status updates
  - `agents.heartbeat` - Agent heartbeat messages
  - `agents.status` - Agent status updates
  - `metrics.ingest` - Metrics ingestion
  - `events.device` - Device events

  ## There is deliberately no alert subject here

  `alert_events: "events.alert"` used to be declared in `standard_channels/0`
  with zero producers and zero consumers, and it is deliberately gone rather
  than wired up.

  Notification delivery is decided in
  `ServiceRadar.Notifications` - routed, deduplicated, suppressed, redacted, and
  recorded as a `NotificationDelivery` row - and the way an alert reaches a
  message bus is the built-in `:stream` provider, which traverses that same
  path (design D10, `openspec/changes/add-notification-platform/design.md`).
  Publishing alerts onto a bare subject from anywhere else would be a second,
  unaudited egress: no suppression, no delivery record, and nothing able to
  answer "why was I not paged?".

  The `:stream` provider's durable half gets its own JetStream subject
  namespace, its own stream with a durable cursor, and matching per-CN publish
  and subscribe entries in `helm/serviceradar/templates/nats.yaml` (new subject
  namespaces are DENIED at the broker by default). Reviving `events.alert` in
  anticipation of that would only have to be rewritten against those
  allowlists.
  """

  @type channel :: String.t()

  @doc """
  Builds a channel name.
  """
  @spec build(String.t()) :: channel()
  def build(base_channel) when is_binary(base_channel), do: base_channel

  @doc """
  Standard channel names for common operations.
  """
  @spec standard_channels() :: map()
  def standard_channels do
    %{
      # Gateway channels
      gateway_heartbeat: "gateways.heartbeat",
      gateway_status: "gateways.status",
      gateway_tasks: "gateways.tasks",
      gateway_results: "gateways.results",

      # Agent channels
      agent_heartbeat: "agents.heartbeat",
      agent_status: "agents.status",
      agent_events: "agents.events",

      # Checker channels
      checker_heartbeat: "checkers.heartbeat",
      checker_results: "checkers.results",

      # Metrics channels
      metrics_ingest: "metrics.ingest",
      metrics_batch: "metrics.batch",

      # Event channels. Alerts are deliberately absent; see the moduledoc.
      device_events: "events.device",
      config_events: "events.config"
    }
  end

  @doc """
  Returns a standard channel for a given key.

  ## Examples

      iex> Channels.standard(:gateway_heartbeat)
      "gateways.heartbeat"
  """
  @spec standard(atom()) :: channel()
  def standard(channel_key) do
    Map.fetch!(standard_channels(), channel_key)
  end
end
