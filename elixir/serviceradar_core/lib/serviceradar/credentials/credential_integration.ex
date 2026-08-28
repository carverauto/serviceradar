defmodule ServiceRadar.Credentials.CredentialIntegration do
  @moduledoc """
  Interprets a validated package-owned credential integration descriptor.

  This module is deliberately provider-neutral. Approved plugin manifests own
  provider names, form fields, purposes, consumers, grants, and stored plugin
  parameters. Core only applies the bounded descriptor contract and never
  executes package-supplied code or gives it plaintext credential values.
  """

  alias ServiceRadar.Credentials.CredentialParameterTemplate
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.SecretRefs

  @resolution_locations %{
    "control_plane" => :control_plane,
    "agent" => :agent,
    "hybrid" => :hybrid
  }

  @spec target_policy?(map()) :: boolean()
  def target_policy?(profile) when is_map(profile) do
    get_in(profile, ["provisioning", "mode"]) == "target_policy"
  end

  def target_policy?(_profile), do: false

  @spec provider(map()) :: String.t() | nil
  def provider(profile) when is_map(profile), do: profile["provider"]
  def provider(_profile), do: nil

  @spec purposes(map()) :: [String.t()]
  def purposes(profile) when is_map(profile) do
    profile
    |> consumers()
    |> Enum.map(& &1["purpose"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def purposes(_profile), do: []

  @spec consumers(map()) :: [map()]
  def consumers(profile) when is_map(profile) do
    profile
    |> get_in(["provisioning", "consumers"])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  def consumers(_profile), do: []

  @spec rule_has_purpose?(map(), map(), String.t() | atom()) :: boolean()
  def rule_has_purpose?(profile, rule, purpose) when is_map(profile) and is_map(rule) do
    purpose = to_string(purpose)
    purpose in rule_purposes(profile, rule)
  end

  def rule_has_purpose?(_profile, _rule, _purpose), do: false

  @spec consumer_for_rule(map(), map(), String.t() | atom()) ::
          {:ok, map()} | {:error, term()}
  def consumer_for_rule(profile, rule, purpose) when is_map(profile) and is_map(rule) do
    purpose = to_string(purpose)
    auth_method = auth_method(profile, rule)

    case Enum.find(consumers(profile), fn consumer ->
           consumer["purpose"] == purpose and auth_method in consumer["auth_methods"]
         end) do
      nil -> {:error, {:credential_consumer_not_declared, purpose, auth_method}}
      consumer -> {:ok, consumer}
    end
  end

  def consumer_for_rule(_profile, _rule, _purpose),
    do: {:error, :invalid_credential_integration_descriptor}

  @spec validate_rule(map(), map(), map()) :: :ok | {:error, term()}
  def validate_rule(profile, consumer, rule)
      when is_map(profile) and is_map(consumer) and is_map(rule) do
    auth_method = auth_method(profile, rule)
    method = Enum.find(profile["auth_methods"] || [], &(&1["id"] == auth_method)) || %{}
    constraints = consumer["constraints"] || %{}
    tls_policy = rule_value(rule, "tls_policy", profile, "verify")
    ssh_policy = rule_value(rule, "ssh_host_key_policy", profile, "known_hosts")

    cond do
      auth_method not in (consumer["auth_methods"] || []) ->
        {:error, :credential_auth_method_not_allowed}

      not allowed?(tls_policy, method["tls_policies"]) or
          not allowed?(tls_policy, constraints["tls_policies"]) ->
        {:error, :credential_tls_policy_not_allowed}

      not allowed?(ssh_policy, method["ssh_host_key_policies"]) or
          not allowed?(ssh_policy, constraints["ssh_host_key_policies"]) ->
        {:error, :credential_ssh_host_key_policy_not_allowed}

      true ->
        :ok
    end
  end

  def validate_rule(_profile, _consumer, _rule),
    do: {:error, :invalid_credential_integration_descriptor}

  @spec failure_mode(map()) :: String.t()
  def failure_mode(consumer) when is_map(consumer), do: consumer["failure_mode"] || "error"
  def failure_mode(_consumer), do: "error"

  @doc """
  How the consumer's work maps onto the rule's resolved targets.

  `"per_target"` (the default) chunks the resolved targets and delivers one
  assignment per chunk. `"single"` declares that the work belongs to the rule
  rather than to any target, so the whole target set must arrive as one
  un-chunked assignment.
  """
  @spec target_cardinality(map()) :: String.t()
  def target_cardinality(consumer) when is_map(consumer),
    do: consumer["target_cardinality"] || "per_target"

  def target_cardinality(_consumer), do: "per_target"

  @spec single_target_cardinality?(map()) :: boolean()
  def single_target_cardinality?(consumer), do: target_cardinality(consumer) == "single"

  @spec requires_public_username?(map()) :: boolean()
  def requires_public_username?(consumer) when is_map(consumer) do
    CredentialParameterTemplate.references_source?(consumer["params"] || %{}, "public_username") or
      CredentialParameterTemplate.references_source?(
        get_in(consumer, ["grant", "payload"]) || %{},
        "public_username"
      )
  end

  def requires_public_username?(_consumer), do: false

  @spec grant_spec(map(), map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, {map(), map()}} | {:error, term()}
  def grant_spec(consumer, rule, secret_id, agent_id, public_username)
      when is_map(consumer) and is_map(rule) and is_binary(secret_id) and is_binary(agent_id) do
    grant = consumer["grant"] || %{}
    secret_ref = SecretRefs.network_credential_ref(secret_id)

    context = %{
      rule: rule,
      secret_ref: secret_ref,
      public_username: public_username
    }

    with {:ok, resolution_location} <- resolution_location(grant["resolution_location"]),
         {:ok, extras} <-
           CredentialParameterTemplate.render(grant["payload"] || %{}, context) do
      allow = grant["allow"] || %{}

      attrs =
        %{
          secret_id: secret_id,
          secret_ref: secret_ref,
          credential_rule_id: RuleAccessors.value_string(rule, [:id, "id"]),
          grant_type: grant["grant_type"],
          consumer_kind: :plugin,
          consumer_id: consumer["plugin_id"],
          purpose: consumer["purpose"],
          agent_id: agent_id,
          resolution_location: resolution_location,
          ttl_seconds:
            RuleAccessors.metadata_int(
              rule,
              "credential_broker_ttl_seconds",
              grant["ttl_seconds"] || 300
            )
        }
        |> maybe_put_map(:inject, grant["inject"])
        |> maybe_put_list(:allowed_methods, allow["methods"])
        |> maybe_put_list(:allowed_paths, allow["paths"])
        |> maybe_put_list(:allowed_hosts, allow["hosts"])
        |> maybe_put_list(:allowed_ports, allow["ports"])

      {:ok, {attrs, extras}}
    end
  end

  def grant_spec(_consumer, _rule, _secret_id, _agent_id, _public_username),
    do: {:error, :invalid_credential_integration_descriptor}

  @spec params_template(map(), map(), String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def params_template(consumer, rule, secret_id, grant_payload, public_username)
      when is_map(consumer) and is_map(rule) and is_binary(secret_id) and is_map(grant_payload) do
    CredentialParameterTemplate.render(consumer["params"] || %{}, %{
      rule: rule,
      grant: grant_payload,
      secret_ref: SecretRefs.network_credential_ref(secret_id),
      public_username: public_username
    })
  end

  def params_template(_consumer, _rule, _secret_id, _grant_payload, _public_username),
    do: {:error, :invalid_credential_integration_descriptor}

  @spec plugin_id(map()) :: String.t() | nil
  def plugin_id(consumer) when is_map(consumer), do: consumer["plugin_id"]
  def plugin_id(_consumer), do: nil

  defp auth_method(profile, rule) do
    RuleAccessors.auth_method(rule) || get_in(profile, ["rule_defaults", "auth_method"])
  end

  defp rule_purposes(profile, rule) do
    case RuleAccessors.rule_purposes(rule) do
      [] -> get_in(profile, ["rule_defaults", "purposes"]) || []
      purposes -> purposes
    end
  end

  defp rule_value(rule, field, profile, fallback) do
    RuleAccessors.value_string(rule, [field_atom(field), field]) ||
      get_in(profile, ["rule_defaults", field]) || fallback
  end

  defp field_atom("tls_policy"), do: :tls_policy
  defp field_atom("ssh_host_key_policy"), do: :ssh_host_key_policy

  defp allowed?(_value, nil), do: true
  defp allowed?(_value, []), do: true
  defp allowed?(value, allowed), do: value in allowed

  defp resolution_location(value) do
    case Map.fetch(@resolution_locations, value) do
      {:ok, location} -> {:ok, location}
      :error -> {:error, :invalid_credential_resolution_location}
    end
  end

  defp maybe_put_map(map, _key, value) when not is_map(value) or map_size(value) == 0, do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_list(map, _key, value) when not is_list(value) or value == [], do: map
  defp maybe_put_list(map, key, value), do: Map.put(map, key, value)
end
