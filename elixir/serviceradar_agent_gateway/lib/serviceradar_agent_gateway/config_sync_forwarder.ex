defmodule ServiceRadarAgentGateway.ConfigSyncForwarder do
  @moduledoc """
  Forwards agent config-distribution state (config acks, reported committed
  versions, and config pushes) to core for persistence, and fetches an agent's
  current config from core for delivery on its control stream.

  The gateway has no database access, so persistence happens on a core node via
  the same `ServiceRadar.Edge.AgentGatewaySync` RPC surface used for agent
  hello/heartbeat sync. Core stores the state on the agent record and evaluates
  config-wedge health from it (see `ServiceRadar.Infrastructure.StateMonitor`).

  The RPC is injectable via the `:config_sync_rpc` application env (a 2-arity
  fun taking the AgentGatewaySync function name and args) so session tests can
  capture forwarded payloads without a core node.
  """

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadarAgentGateway.CoreNodeForwarder

  require Logger

  @rpc_timeout 5_000
  # Config generation runs on core; match the poll path's budget for it.
  @config_rpc_timeout 60_000

  @doc """
  Persists a control-stream config ack on core.

  Sectioned acks carry per-section apply statuses; acks without section
  statuses come from legacy agents and are forwarded without section detail so
  core records them as whole-version acks.
  """
  @spec record_config_ack(String.t(), Monitoring.ConfigAck.t()) :: :ok | {:error, term()}
  def record_config_ack(agent_id, %Monitoring.ConfigAck{} = ack) do
    attrs = %{
      config_version: ack.config_version,
      acked_at: unix_datetime(ack.timestamp),
      section_statuses: section_statuses(ack.section_statuses)
    }

    core_call(:record_config_ack, [agent_id, attrs])
  end

  @doc """
  Persists an agent-reported committed config version (from a control-stream
  heartbeat hello) as a whole-version ack.

  The hello's config_version is set on the agent only after a fully-successful
  apply, so it is semantically equivalent to a legacy whole-version ack. This
  keeps versions applied via the config POLL path (which never sends a stream
  ack) from reading as unacknowledged in wedge detection.
  """
  @spec record_reported_version(String.t(), String.t()) :: :ok | {:error, term()}
  def record_reported_version(agent_id, config_version) do
    core_call(:record_config_ack, [
      agent_id,
      %{config_version: config_version, acked_at: DateTime.utc_now(), section_statuses: nil}
    ])
  end

  @doc """
  Persists the per-section config apply statuses an agent reported on a
  control-stream hello.

  The hello carries the agent's current section state between commits,
  including a section that is deferring the commit (`transient_failure`), which
  has no ack to ride on. Core stores the statuses without treating them as an
  ack. A hello without statuses (agents that predate the field) forwards
  nothing.
  """
  @spec record_section_statuses(String.t(), Monitoring.ControlStreamHello.t()) ::
          :ok | {:error, term()}
  def record_section_statuses(agent_id, %Monitoring.ControlStreamHello{} = hello) do
    case section_statuses(hello.config_section_statuses) do
      nil ->
        :ok

      statuses ->
        core_call(:record_config_section_statuses, [agent_id, %{section_statuses: statuses}])
    end
  end

  @doc """
  Fetches the agent's current config from core when it differs from
  `config_version`, the version the agent reported on its control stream.

  This is the same version-aware call the config poll makes, scoped to the
  partition the gateway authenticated for the session. The caller delivers the
  result to the session it owns, so nothing here depends on core finding that
  session in the cluster registry.
  """
  @spec fetch_config_if_changed(String.t(), String.t(), String.t() | nil) ::
          {:ok, Monitoring.AgentConfigResponse.t()} | :not_modified | {:error, term()}
  def fetch_config_if_changed(agent_id, partition_id, config_version)
      when is_binary(agent_id) and is_binary(partition_id) do
    case rpc(:get_config_if_changed, [agent_id, partition_id, config_version || ""], @config_rpc_timeout) do
      :not_modified ->
        :not_modified

      {:ok, %{} = config} ->
        {:ok, AgentConfigGenerator.to_proto_response(config)}

      {:error, reason} ->
        Logger.warning("Failed to fetch agent config from core: agent_id=#{agent_id} #{inspect(reason)}")

        {:error, reason}

      other ->
        Logger.warning("Unexpected agent config fetch result: agent_id=#{agent_id} #{inspect(other)}")

        {:error, {:unexpected_result, other}}
    end
  end

  @doc """
  Persists the config version pushed to an agent over the control stream.

  Core decides whether this push moves `config_pushed_at`. See
  `ServiceRadar.Edge.AgentGatewaySync.record_config_push/2`.
  """
  @spec record_config_push(String.t(), String.t()) :: :ok | {:error, term()}
  def record_config_push(agent_id, config_version) do
    core_call(:record_config_push, [
      agent_id,
      %{config_version: config_version, pushed_at: DateTime.utc_now()}
    ])
  end

  @doc "Persists an agent's answer to a sweep lease push on core."
  @spec record_sweep_lease_ack(String.t(), Monitoring.SweepLeaseAck.t()) :: :ok | {:error, term()}
  def record_sweep_lease_ack(agent_id, %Monitoring.SweepLeaseAck{} = ack) do
    core_call(:record_sweep_lease_ack, [
      agent_id,
      %{
        sweep_group_id: ack.sweep_group_id,
        payload_sha256: ack.payload_sha256,
        installed: ack.installed,
        error: ack.error,
        installed_through_unix_nano: ack.installed_through_unix_nano,
        installed_slot_count: ack.installed_slot_count
      }
    ])
  end

  defp section_statuses([_ | _] = statuses) do
    Enum.map(statuses, fn status ->
      %{
        "section" => status.section,
        "disposition" => status.disposition,
        "error" => status.error,
        "since" => since_iso8601(status.since)
      }
    end)
  end

  defp section_statuses(_statuses), do: nil

  defp since_iso8601(since) when is_integer(since) and since > 0 do
    case DateTime.from_unix(since) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp since_iso8601(_since), do: nil

  defp unix_datetime(timestamp) when is_integer(timestamp) and timestamp > 0 do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp unix_datetime(_timestamp), do: DateTime.utc_now()

  defp core_call(function, args) do
    case rpc(function, args, @rpc_timeout) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to sync agent config state to core: #{function} #{inspect(reason)}")

        {:error, reason}

      other ->
        Logger.warning("Unexpected agent config sync result: #{function} #{inspect(other)}")

        {:error, other}
    end
  end

  defp rpc(function, args, timeout) do
    case Application.get_env(:serviceradar_agent_gateway, :config_sync_rpc) do
      nil -> default_rpc(function, args, timeout)
      injected_rpc -> injected_rpc.(function, args)
    end
  end

  defp default_rpc(function, args, timeout) do
    node = CoreNodeForwarder.select_core_node("agent config sync")

    case :rpc.call(node, ServiceRadar.Edge.AgentGatewaySync, function, args, timeout) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  rescue
    ArgumentError -> {:error, :core_unavailable}
  end
end
