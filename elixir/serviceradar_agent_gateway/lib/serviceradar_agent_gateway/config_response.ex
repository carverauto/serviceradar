defmodule ServiceRadarAgentGateway.ConfigResponse do
  @moduledoc false

  require Logger

  @spec from_core_result(term(), String.t(), String.t(), (term() -> Monitoring.AgentConfigResponse.t())) ::
          Monitoring.AgentConfigResponse.t()
  def from_core_result(core_result, agent_id, config_version, success_converter)

  def from_core_result({:error, :core_unavailable}, agent_id, config_version, _success_converter) do
    Logger.warning("Core unavailable for config request: agent_id=#{agent_id}, version=#{config_version}")

    unavailable_config_response(config_version)
  end

  def from_core_result({:ok, :not_modified}, agent_id, config_version, _success_converter) do
    Logger.debug("Agent config not modified: agent_id=#{agent_id}, version=#{config_version}")

    unavailable_config_response(config_version)
  end

  def from_core_result({:ok, {:ok, config}}, _agent_id, _config_version, success_converter) do
    success_converter.(config)
  end

  def from_core_result({:ok, {:error, reason}}, agent_id, config_version, _success_converter) do
    Logger.warning("Failed to generate config for agent #{agent_id}: #{inspect(reason)}, retaining current config")

    unavailable_config_response(config_version)
  end

  def from_core_result({:ok, other}, agent_id, config_version, _success_converter) do
    Logger.warning("Unexpected config response for agent #{agent_id}: #{inspect(other)}")

    unavailable_config_response(config_version)
  end

  defp unavailable_config_response(config_version) do
    %Monitoring.AgentConfigResponse{
      not_modified: true,
      config_version: config_version
    }
  end
end
