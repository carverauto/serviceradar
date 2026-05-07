defmodule ServiceRadar.Credentials.NetworkCredentialRuleTestDispatcher do
  @moduledoc """
  Dispatches credential rule tests without persisting plaintext credentials.

  The persisted AgentCommand payload remains the redacted test plan. The
  runtime payload sent over the authenticated control stream includes the
  resolved credential material and is never stored in `agent_commands`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.NetworkCredentialRuleTestPlan
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.SecretRefs

  @spec dispatch_proxmox_api_test_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch_proxmox_api_test_by_id(id, opts \\ []) when is_binary(id) do
    with {:ok, plan} <- NetworkCredentialRuleTestPlan.proxmox_api_test_by_id(id, opts) do
      dispatch_plan(plan, opts)
    end
  end

  @spec dispatch_plan(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch_plan(%{payload: payload} = plan, opts) when is_map(payload) do
    with {:ok, runtime_payload} <- runtime_payload(payload, opts),
         {:ok, command_id} <- dispatch_command(plan, runtime_payload, opts) do
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

  defp dispatch_command(plan, runtime_payload, opts) do
    command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

    command_bus.dispatch(
      plan.agent_id,
      plan.command_type,
      CredentialRedactor.redact(plan.payload),
      ttl_seconds: plan.ttl_seconds,
      required_capability: plan.required_capability,
      context: plan.context,
      actor: Keyword.get(opts, :actor),
      test_pid: Keyword.get(opts, :test_pid),
      transmit_payload: runtime_payload
    )
  end

  defp runtime_payload(payload, opts) do
    resolver = Keyword.get(opts, :secret_resolver, &resolve_secret_ref/2)

    with {:ok, ref} <- fetch_string(payload, "credential_secret_ref"),
         {:ok, token} <- resolver.(ref, opts) do
      {:ok,
       payload
       |> Map.delete("credential_secret_ref")
       |> Map.put("api_token", proxmox_api_token_header(token))}
    end
  end

  defp resolve_secret_ref(ref, opts) do
    actor = Keyword.get(opts, :secret_actor, SystemActor.system(:network_credential_rule_test))

    with {:ok, secret_id} <- SecretRefs.network_credential_ref_id(ref),
         {:ok, secret} <- NetworkCredentialSecret.get_secret_by_id(secret_id, actor: actor),
         payload when is_binary(payload) and payload != "" <- Map.get(secret, :secret_payload) do
      {:ok, payload}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_secret_payload}
    end
  end

  defp proxmox_api_token_header(token) when is_binary(token) do
    token = String.trim(token)

    if String.starts_with?(token, "PVEAPIToken=") do
      token
    else
      "PVEAPIToken=" <> token
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, key}}
    end
  end
end
