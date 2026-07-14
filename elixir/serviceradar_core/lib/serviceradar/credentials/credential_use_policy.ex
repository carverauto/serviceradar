defmodule ServiceRadar.Credentials.CredentialUsePolicy do
  @moduledoc """
  Evaluates the actor-use policy attached to a brokered credential rule.

  The policy is deliberately deny-by-default and reusable across providers.
  Rules opt in with metadata shaped as:

      %{
        "credential_use_policy" => %{
          "schema" => "serviceradar.credential_use_policy.v1",
          "principals" => ["user UUID or IdP subject"],
          "roles" => ["admin"],
          "groups" => ["IdP group ID"]
        }
      }

  At least one selector must be present. A matching principal, role, or group
  grants use; missing, malformed, unknown-version, or non-matching policies
  deny use. System actors never satisfy an end-user credential-use policy.
  """

  alias ServiceRadar.Plugins.ValueUtils

  @schema "serviceradar.credential_use_policy.v1"
  @policy_keys MapSet.new(~w(schema principals roles groups))
  @max_selectors 128
  @max_selector_bytes 256

  @type denial ::
          :credential_use_policy_missing
          | :credential_use_policy_invalid
          | :credential_use_policy_denied

  @spec authorize_rule(map(), map() | nil, map()) :: :ok | {:error, denial()}
  def authorize_rule(rule, actor, identity_claims \\ %{}) when is_map(rule) do
    metadata = ValueUtils.map_value(rule, [:metadata, "metadata"]) || %{}

    case map_value(metadata, "credential_use_policy") do
      policy when is_map(policy) -> authorize(policy, actor, identity_claims)
      _policy -> {:error, :credential_use_policy_missing}
    end
  end

  @spec authorize(map(), map() | nil, map()) :: :ok | {:error, denial()}
  def authorize(policy, actor, identity_claims \\ %{})

  def authorize(policy, actor, identity_claims)
      when is_map(policy) and is_map(actor) and is_map(identity_claims) do
    with :ok <- validate_actor(actor),
         :ok <- validate_policy_keys(policy),
         :ok <- validate_schema(policy),
         {:ok, principals} <- selector_list(policy, "principals", &normalize_exact/1),
         {:ok, roles} <- selector_list(policy, "roles", &normalize_role/1),
         {:ok, groups} <- selector_list(policy, "groups", &normalize_exact/1),
         true <- principals != [] or roles != [] or groups != [],
         true <-
           selector_match?(principals, principal_values(actor, identity_claims)) or
             selector_match?(roles, role_values(actor)) or
             selector_match?(groups, group_values(identity_claims)) do
      :ok
    else
      {:error, :credential_use_policy_denied} = denied -> denied
      {:error, _reason} -> {:error, :credential_use_policy_invalid}
      false -> {:error, :credential_use_policy_denied}
      _other -> {:error, :credential_use_policy_invalid}
    end
  end

  def authorize(_policy, _actor, _identity_claims), do: {:error, :credential_use_policy_invalid}

  def schema, do: @schema

  defp validate_actor(actor) do
    roles = role_values(actor)

    if "system" in roles or (principal_values(actor, %{}) == [] and roles == []),
      do: {:error, :credential_use_policy_denied},
      else: :ok
  end

  defp validate_policy_keys(policy) do
    keys =
      policy
      |> Map.keys()
      |> MapSet.new(fn
        key when is_binary(key) -> key
        key when is_atom(key) -> Atom.to_string(key)
        _key -> nil
      end)

    if MapSet.subset?(keys, @policy_keys),
      do: :ok,
      else: {:error, :invalid_policy_keys}
  end

  defp validate_schema(policy) do
    if string_value(policy, "schema") == @schema,
      do: :ok,
      else: {:error, :unsupported_policy_schema}
  end

  defp selector_list(policy, key, normalizer) do
    case map_value(policy, key) do
      nil ->
        {:ok, []}

      values when is_list(values) and length(values) <= @max_selectors ->
        normalized = Enum.map(values, normalizer)

        if Enum.all?(normalized, &is_binary/1),
          do: {:ok, Enum.uniq(normalized)},
          else: {:error, :invalid_selector}

      _values ->
        {:error, :invalid_selector_list}
    end
  end

  defp principal_values(actor, claims) do
    normalize_values(
      [map_value(actor, :id), map_value(claims, "sub"), map_value(claims, :sub)],
      &normalize_exact/1
    )
  end

  defp role_values(actor) do
    normalize_values([map_value(actor, :role), map_value(actor, "role")], &normalize_role/1)
  end

  defp group_values(claims) do
    [
      map_value(claims, "groups"),
      map_value(claims, :groups),
      map_value(claims, "group_ids"),
      map_value(claims, :group_ids)
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> normalize_values(&normalize_exact/1)
  end

  defp normalize_values(values, normalizer) do
    values
    |> Enum.map(normalizer)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp selector_match?([], _actor_values), do: false

  defp selector_match?(selectors, actor_values) do
    not MapSet.disjoint?(MapSet.new(selectors), MapSet.new(actor_values))
  end

  defp normalize_exact(value) when is_binary(value) do
    value
    |> String.trim()
    |> bounded_selector()
  end

  defp normalize_exact(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_exact()

  defp normalize_exact(_value), do: nil

  defp normalize_role(value) do
    case normalize_exact(value) do
      normalized when is_binary(normalized) -> String.downcase(normalized)
      _normalized -> nil
    end
  end

  defp bounded_selector(""), do: nil

  defp bounded_selector(value) when byte_size(value) <= @max_selector_bytes, do: value

  defp bounded_selector(_value), do: nil

  defp string_value(map, key) do
    case map_value(map, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || alternate_key_value(map, key)
  end

  defp alternate_key_value(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp alternate_key_value(map, key) when is_atom(key), do: Map.get(map, Atom.to_string(key))
  defp alternate_key_value(_map, _key), do: nil
end
