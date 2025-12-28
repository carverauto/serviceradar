defmodule ServiceRadar.NATS.Channels do
  @moduledoc """
  NATS channel management with multi-tenant support.

  All NATS channels in multi-tenant deployments are prefixed with the
  tenant slug to ensure message isolation between tenants.

  ## Channel Format

  Single-tenant: `pollers.heartbeat`
  Multi-tenant: `<tenant_slug>.pollers.heartbeat`

  ## Standard Channels

  - `<tenant>.pollers.heartbeat` - Poller heartbeat messages
  - `<tenant>.pollers.status` - Poller status updates
  - `<tenant>.agents.heartbeat` - Agent heartbeat messages
  - `<tenant>.agents.status` - Agent status updates
  - `<tenant>.metrics.ingest` - Metrics ingestion
  - `<tenant>.events.device` - Device events
  - `<tenant>.events.alert` - Alert events

  ## Usage

  ```elixir
  # In a tenant-aware context
  channel = Channels.build("pollers.heartbeat", tenant_slug: "acme-corp")
  # => "acme-corp.pollers.heartbeat"

  # Subscribe with tenant filter
  Channels.subscribe("pollers.>", tenant_slug: "acme-corp")
  # Subscribes to "acme-corp.pollers.>"

  # Parse tenant from channel
  {:ok, "acme-corp", "pollers.heartbeat"} = Channels.parse("acme-corp.pollers.heartbeat")
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

      iex> Channels.build("pollers.heartbeat", tenant_slug: "acme-corp")
      "acme-corp.pollers.heartbeat"

      iex> Channels.build("pollers.heartbeat", tenant_slug: nil)
      "pollers.heartbeat"
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

      iex> Channels.parse("acme-corp.pollers.heartbeat")
      {:ok, "acme-corp", "pollers.heartbeat"}

      iex> Channels.parse("pollers.heartbeat")
      {:ok, nil, "pollers.heartbeat"}
  """
  @spec parse(channel()) :: {:ok, tenant_slug() | nil, String.t()} | {:error, :invalid_channel}
  def parse(channel) when is_binary(channel) do
    # Standard channels start with known prefixes
    known_prefixes = ~w(pollers agents checkers metrics events alerts devices)

    parts = String.split(channel, ".", parts: 2)

    case parts do
      [maybe_tenant, rest] ->
        first_segment = String.split(rest, ".") |> List.first()

        if first_segment in known_prefixes do
          # Looks like: tenant.pollers.heartbeat
          {:ok, maybe_tenant, rest}
        else
          # Looks like: pollers.heartbeat (no tenant)
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

      iex> Channels.subscription_pattern("pollers.*", tenant_slug: "acme-corp")
      "acme-corp.pollers.*"

      iex> Channels.subscription_pattern("pollers.>", tenant_slug: "acme-corp")
      "acme-corp.pollers.>"
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

      iex> Channels.all_tenants_pattern("pollers.heartbeat")
      "*.pollers.heartbeat"
  """
  @spec all_tenants_pattern(String.t()) :: String.t()
  def all_tenants_pattern(base_channel) do
    "*.#{base_channel}"
  end

  @doc """
  Validates that a channel matches the expected tenant.

  Use this to verify that incoming messages are from the claimed tenant.

  ## Examples

      iex> Channels.validate_tenant("acme-corp.pollers.heartbeat", "acme-corp")
      :ok

      iex> Channels.validate_tenant("evil-corp.pollers.heartbeat", "acme-corp")
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
      # Poller channels
      poller_heartbeat: "pollers.heartbeat",
      poller_status: "pollers.status",
      poller_tasks: "pollers.tasks",
      poller_results: "pollers.results",

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

      iex> Channels.standard(:poller_heartbeat, tenant_slug: "acme-corp")
      "acme-corp.pollers.heartbeat"
  """
  @spec standard(atom(), keyword()) :: channel()
  def standard(channel_key, opts \\ []) do
    base = Map.fetch!(standard_channels(), channel_key)
    build(base, opts)
  end
end
