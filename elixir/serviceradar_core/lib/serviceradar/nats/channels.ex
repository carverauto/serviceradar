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
  - `events.alert` - Alert events
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

      # Event channels
      device_events: "events.device",
      alert_events: "events.alert",
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
