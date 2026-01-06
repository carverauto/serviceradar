defmodule ServiceRadar.NATS.Channels do
  @moduledoc """
  NATS channel management with multi-tenant support.

  All NATS channels in multi-tenant deployments are prefixed with the
  tenant slug to ensure message isolation between tenants.

  ## Channel Format

  Single-tenant: `gateways.heartbeat`
  Multi-tenant: `<tenant_slug>.gateways.heartbeat`

  ## Standard Channels

  - `<tenant>.gateways.heartbeat` - Gateway heartbeat messages
  - `<tenant>.gateways.status` - Gateway status updates
  - `<tenant>.agents.heartbeat` - Agent heartbeat messages
  - `<tenant>.agents.status` - Agent status updates
  - `<tenant>.metrics.ingest` - Metrics ingestion
  - `<tenant>.events.device` - Device events
  - `<tenant>.events.alert` - Alert events

  ## Usage

  ```elixir
  # In a tenant-aware context
  channel = Channels.build("gateways.heartbeat", tenant_slug: "acme-corp")
  # => "acme-corp.gateways.heartbeat"

  # Subscribe with tenant filter
  Channels.subscribe("gateways.>", tenant_slug: "acme-corp")
  # Subscribes to "acme-corp.gateways.>"

  # Parse tenant from channel
  {:ok, "acme-corp", "gateways.heartbeat"} = Channels.parse("acme-corp.gateways.heartbeat")
  ```

  ## Security

  - Edge components can only publish/subscribe to their tenant's channels
  - Core services can access all tenant channels with proper authorization
  - Tenant slug is validated against the client certificate
  """

  @type channel :: String.t()
  @type tenant_slug :: String.t()

  @doc """
  Builds a tenant-prefixed channel name.

  ## Options

    * `:tenant_slug` - Tenant slug to prefix (required for multi-tenant)
    * `:prefix_separator` - Separator between tenant and channel (default: ".")

  ## Examples

      iex> Channels.build("gateways.heartbeat", tenant_slug: "acme-corp")
      "acme-corp.gateways.heartbeat"

      iex> Channels.build("gateways.heartbeat", tenant_slug: nil)
      "gateways.heartbeat"
  """
  @spec build(String.t(), keyword()) :: channel()
  def build(base_channel, opts \\ []) do
    tenant_slug = Keyword.get(opts, :tenant_slug)
    separator = Keyword.get(opts, :prefix_separator, ".")

    case tenant_slug do
      nil -> base_channel
      "" -> base_channel
      slug -> "#{slug}#{separator}#{base_channel}"
    end
  end

  @doc """
  Parses a channel name into tenant slug and base channel.

  ## Examples

      iex> Channels.parse("acme-corp.gateways.heartbeat")
      {:ok, "acme-corp", "gateways.heartbeat"}

      iex> Channels.parse("gateways.heartbeat")
      {:ok, nil, "gateways.heartbeat"}
  """
  @spec parse(channel()) :: {:ok, tenant_slug() | nil, String.t()} | {:error, :invalid_channel}
  def parse(channel) when is_binary(channel) do
    # Standard channels start with known prefixes
    known_prefixes = ~w(gateways agents checkers metrics events alerts devices)

    parts = String.split(channel, ".", parts: 2)

    case parts do
      [maybe_tenant, rest] ->
        first_segment = String.split(rest, ".") |> List.first()

        if first_segment in known_prefixes do
          # Looks like: tenant.gateways.heartbeat
          {:ok, maybe_tenant, rest}
        else
          # Looks like: gateways.heartbeat (no tenant)
          {:ok, nil, channel}
        end

      [_single] ->
        {:ok, nil, channel}

      _ ->
        {:error, :invalid_channel}
    end
  end

  @doc """
  Returns a NATS subscription pattern for a tenant.

  Use this when subscribing to all messages for a specific channel type
  within a tenant.

  ## Examples

      iex> Channels.subscription_pattern("gateways.*", tenant_slug: "acme-corp")
      "acme-corp.gateways.*"

      iex> Channels.subscription_pattern("gateways.>", tenant_slug: "acme-corp")
      "acme-corp.gateways.>"
  """
  @spec subscription_pattern(String.t(), keyword()) :: String.t()
  def subscription_pattern(pattern, opts) do
    build(pattern, opts)
  end

  @doc """
  Returns a subscription pattern for all tenants (core/admin use only).

  WARNING: This should only be used by core services that need to
  process messages from all tenants. Edge components should never
  use this pattern.

  ## Examples

      iex> Channels.all_tenants_pattern("gateways.heartbeat")
      "*.gateways.heartbeat"
  """
  @spec all_tenants_pattern(String.t()) :: String.t()
  def all_tenants_pattern(base_channel) do
    "*.#{base_channel}"
  end

  @doc """
  Validates that a channel matches the expected tenant.

  Use this to verify that incoming messages are from the claimed tenant.

  ## Examples

      iex> Channels.validate_tenant("acme-corp.gateways.heartbeat", "acme-corp")
      :ok

      iex> Channels.validate_tenant("evil-corp.gateways.heartbeat", "acme-corp")
      {:error, :tenant_mismatch}
  """
  @spec validate_tenant(channel(), tenant_slug()) :: :ok | {:error, :tenant_mismatch}
  def validate_tenant(channel, expected_tenant) do
    case parse(channel) do
      {:ok, ^expected_tenant, _} -> :ok
      {:ok, nil, _} when is_nil(expected_tenant) -> :ok
      {:ok, _, _} -> {:error, :tenant_mismatch}
      error -> error
    end
  end

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
  Returns a standard channel for a given key, with optional tenant prefix.

  ## Examples

      iex> Channels.standard(:gateway_heartbeat, tenant_slug: "acme-corp")
      "acme-corp.gateways.heartbeat"
  """
  @spec standard(atom(), keyword()) :: channel()
  def standard(channel_key, opts \\ []) do
    base = Map.fetch!(standard_channels(), channel_key)
    build(base, opts)
  end
end
