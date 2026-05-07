defmodule ServiceRadar.Credentials.NetworkCredentialRuleTestDispatcher do
  @moduledoc """
  Dispatches credential rule tests without transmitting plaintext credentials.

  Command payloads carry a short-lived credential broker grant and secret
  reference. The edge broker is responsible for constrained use of the
  credential; plugins and generic command handlers must not receive decrypted
  credential material.
  """

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.NetworkCredentialRuleTestPlan
  alias ServiceRadar.Edge.AgentCommandBus

  @spec dispatch_proxmox_api_test_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch_proxmox_api_test_by_id(id, opts \\ []) when is_binary(id) do
    with {:ok, plan} <- NetworkCredentialRuleTestPlan.proxmox_api_test_by_id(id, opts) do
      dispatch_plan(plan, opts)
    end
  end

  @spec dispatch_plan(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch_plan(%{payload: payload} = plan, opts) when is_map(payload) do
    with :ok <- validate_broker_grant(payload),
         {:ok, command_id} <- dispatch_command(plan, opts) do
      {:ok,
       %{
         command_id: command_id,
         command_type: plan.command_type,
         agent_id: plan.agent_id,
         context: plan.context,
         payload: CredentialRedactor.redact(payload)
       }}
    end
  end

  def dispatch_plan(_plan, _opts), do: {:error, :invalid_test_plan}

  defp dispatch_command(plan, opts) do
    command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

    command_bus.dispatch(
      plan.agent_id,
      plan.command_type,
      CredentialRedactor.redact(plan.payload),
      ttl_seconds: plan.ttl_seconds,
      required_capability: plan.required_capability,
      context: plan.context,
      actor: Keyword.get(opts, :actor),
      test_pid: Keyword.get(opts, :test_pid)
    )
  end

  defp validate_broker_grant(payload) do
    with %{} = broker <- Map.get(payload, "credential_broker"),
         {:ok, _schema} <- fetch_string(broker, "schema"),
         {:ok, _ref} <- fetch_string(broker, "credential_secret_ref"),
         {:ok, _rule_id} <- fetch_string(broker, "credential_rule_id"),
         %{} <- Map.get(broker, "target"),
         %{} <- Map.get(broker, "allow") do
      :ok
    else
      _ -> {:error, :missing_credential_broker_grant}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, key}}
    end
  end
end
