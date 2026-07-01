defmodule ServiceRadar.Credentials.ProviderProfiles.CameraProfileHelpers do
  @moduledoc """
  Shared building blocks for camera provider profiles (unifi-protect, axis).

  Camera assignments never carry `host` (SRQL-injected per target) or `relay`
  (agent-injected). Credentials arrive as a broker grant plus a `*_secret_ref`,
  while the non-secret `username` is baked plaintext for username/password auth.
  """

  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.SecretRefs

  @doc """
  Build the credential-broker grant attrs (+ empty extras) for a camera plugin.

  Cameras resolve credentials at the control plane (config-gen) rather than via
  the agent-side action-mode HTTP inject, so no `inject`/`allow` is attached.
  """
  @spec grant_spec(String.t(), atom(), map(), String.t(), String.t(), String.t()) ::
          {map(), map()}
  def grant_spec(grant_type, purpose, rule, secret_id, agent_id, consumer_id) do
    attrs = %{
      secret_id: secret_id,
      secret_ref: SecretRefs.network_credential_ref(secret_id),
      credential_rule_id: RuleAccessors.value_string(rule, [:id, "id"]),
      grant_type: grant_type,
      consumer_kind: :plugin,
      consumer_id: consumer_id,
      purpose: Atom.to_string(purpose),
      agent_id: agent_id,
      resolution_location: :control_plane,
      ttl_seconds: RuleAccessors.metadata_int(rule, "credential_broker_ttl_seconds", 300)
    }

    {attrs, %{}}
  end

  @doc """
  Attach the credential fields to a camera params template.

  API-key auth stores only `api_key_secret_ref`; username/password auth stores
  `password_secret_ref` plus the resolved public `username` plaintext.
  """
  @spec put_credentials(map(), map(), map()) :: map()
  def put_credentials(params, rule, ctx) do
    if RuleAccessors.auth_method(rule) == "api_key" do
      Map.put(params, "api_key_secret_ref", ctx.secret_ref)
    else
      params
      |> Map.put("password_secret_ref", ctx.secret_ref)
      |> maybe_put_username(ctx)
    end
  end

  defp maybe_put_username(params, %{username: username})
       when is_binary(username) and username != "" do
    Map.put(params, "username", username)
  end

  defp maybe_put_username(params, _ctx), do: params
end
