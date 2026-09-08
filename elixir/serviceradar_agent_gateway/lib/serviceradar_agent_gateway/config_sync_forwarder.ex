defmodule ServiceRadarAgentGateway.ConfigSyncForwarder do
  @moduledoc """
  Forwards agent config-distribution state (config acks, reported committed
  versions, and config pushes) to core for persistence.

  The gateway has no database access, so persistence happens on a core node via
  the same `ServiceRadar.Edge.AgentGatewaySync` RPC surface used for agent
  hello/heartbeat sync. Core stores the state on the agent record and evaluates
  config-wedge health from it (see `ServiceRadar.Infrastructure.StateMonitor`).

  The RPC is injectable via the `:config_sync_rpc` application env (a 2-arity
  fun taking the AgentGatewaySync function name and args) so session tests can
  capture forwarded payloads without a core node.
  """

  alias ServiceRadarAgentGateway.CoreNodeForwarder

  require Logger

  @rpc_timeout 5_000

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
      section_statuses: section_statuses(ack)
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
  Persists the config version pushed to an agent over the control stream. The
  first-push timestamp of a version anchors the no-ack wedge window on core.
  """
  @spec record_config_push(String.t(), String.t()) :: :ok | {:error, term()}
  def record_config_push(agent_id, config_version) do
    core_call(:record_config_push, [
      agent_id,
      %{config_version: config_version, pushed_at: DateTime.utc_now()}
    ])
  end

  defp section_statuses(%Monitoring.ConfigAck{section_statuses: [_ | _] = statuses}) do
    Enum.map(statuses, fn status ->
      %{
        "section" => status.section,
        "disposition" => status.disposition,
        "error" => status.error,
        "since" => since_iso8601(status.since)
      }
    end)
  end

  defp section_statuses(_ack), do: nil

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
    rpc = Application.get_env(:serviceradar_agent_gateway, :config_sync_rpc, &default_rpc/2)

    case rpc.(function, args) do
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

  defp default_rpc(function, args) do
    node = CoreNodeForwarder.select_core_node("agent config sync")

    case :rpc.call(node, ServiceRadar.Edge.AgentGatewaySync, function, args, @rpc_timeout) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  rescue
    ArgumentError -> {:error, :core_unavailable}
  end
end
