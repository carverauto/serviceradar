defmodule ServiceRadarAgentGateway.ConfigResponseTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.ConfigResponse

  test "delegates generated configs to the gateway converter" do
    config = %{config_version: "v-next"}
    converted = %Monitoring.AgentConfigResponse{config_version: "v-next"}

    assert ^converted =
             ConfigResponse.from_core_result(
               {:ok, {:ok, config}},
               "agent-1",
               "v-current",
               fn ^config -> converted end
             )
  end

  test "returns not modified when core confirms the current version" do
    response =
      ConfigResponse.from_core_result(
        {:ok, :not_modified},
        "agent-1",
        "v-current",
        &unexpected_success/1
      )

    assert %Monitoring.AgentConfigResponse{
             not_modified: true,
             config_version: "v-current"
           } = response
  end

  test "preserves the current config when generation fails" do
    response =
      ConfigResponse.from_core_result(
        {:ok, {:error, :invalid_assignment}},
        "agent-1",
        "v-current",
        &unexpected_success/1
      )

    assert %Monitoring.AgentConfigResponse{
             not_modified: true,
             config_version: "v-current"
           } = response
  end

  test "preserves the current config for an unexpected core response" do
    response =
      ConfigResponse.from_core_result(
        {:ok, {:unexpected, :response}},
        "agent-1",
        "v-current",
        &unexpected_success/1
      )

    assert %Monitoring.AgentConfigResponse{
             not_modified: true,
             config_version: "v-current"
           } = response
  end

  test "does not apply an empty config when the current version is empty" do
    core_responses = [
      {:error, :core_unavailable},
      {:ok, {:error, :invalid_assignment}},
      {:ok, {:unexpected, :response}}
    ]

    for core_response <- core_responses do
      response = ConfigResponse.from_core_result(core_response, "agent-1", "", &unexpected_success/1)

      assert %Monitoring.AgentConfigResponse{
               not_modified: true,
               config_version: ""
             } = response
    end
  end

  defp unexpected_success(_config), do: flunk("success converter must not be called")
end
