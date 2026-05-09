defmodule ServiceRadar.Edge.RemoteAccessSSHPrincipalMapper do
  @moduledoc """
  Resolves SSH login principals from IdP claims and target policy mappings.

  This is intentionally a pure mapper. It does not grant remote access by
  itself; certificate issuance still requires RBAC, target scope, TTL, and
  session checks in `RemoteAccessSSHCertificatePolicy`.
  """

  @principal_max_length 128

  @doc """
  Returns the unique SSH principals granted by mappings that match the claims.

  Supported mapping sources mirror SSO role mappings:
  - `groups`: match a group-like claim, defaulting to groups/group/roles/role.
  - `email`: match the email/mail claim exactly.
  - `email_domain`: match the email/mail domain.
  - `claim`: match a configured claim key exactly.
  """
  @spec resolve(map(), list()) :: [String.t()]
  def resolve(claims, mappings) when is_map(claims) and is_list(mappings) do
    mappings
    |> Enum.flat_map(&mapping_principals(&1, claims))
    |> normalize_principal_list()
  end

  def resolve(_claims, _mappings), do: []

  defp mapping_principals(mapping, claims) when is_map(mapping) do
    source = normalize_value(get_key(mapping, "source"))
    value = normalize_value(get_key(mapping, "value"))
    claim_key = normalize_value(get_key(mapping, "claim"))

    if source && value && matches?(source, value, claim_key, claims) do
      mapping
      |> get_key("principals")
      |> principal_values()
    else
      []
    end
  end

  defp mapping_principals(_mapping, _claims), do: []

  defp matches?("groups", value, claim_key, claims) do
    keys = if claim_key, do: [claim_key], else: ["groups", "group", "roles", "role"]

    claims
    |> extract_claim_values(keys)
    |> Enum.any?(&(&1 == value))
  end

  defp matches?("email", value, _claim_key, claims), do: email(claims) == value

  defp matches?("email_domain", value, _claim_key, claims) do
    case email(claims) do
      nil -> false
      email -> String.ends_with?(email, "@" <> value)
    end
  end

  defp matches?("claim", value, claim_key, claims) do
    if blank?(claim_key) do
      false
    else
      case get_key(claims, claim_key) do
        list when is_list(list) -> Enum.any?(list, &(normalize_value(&1) == value))
        other -> normalize_value(other) == value
      end
    end
  end

  defp matches?(_source, _value, _claim_key, _claims), do: false

  defp email(claims) do
    normalize_value(get_key(claims, "email")) ||
      normalize_value(get_key(claims, "mail"))
  end

  defp extract_claim_values(claims, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case get_key(claims, key) do
        nil -> []
        list when is_list(list) -> Enum.map(list, &normalize_value/1)
        value -> split_values(value)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp principal_values(value), do: list_values(value)

  defp normalize_principal_list(values) do
    values
    |> Enum.map(&normalize_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&valid_principal?/1)
    |> Enum.uniq()
  end

  defp valid_principal?(value) do
    String.length(value) <= @principal_max_length and
      not String.contains?(value, [",", ":", "\n", "\r", "\t", " "])
  end

  defp split_values(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&normalize_value/1)
  end

  defp split_values(value), do: [normalize_value(value)]

  defp list_values(nil), do: []
  defp list_values(values) when is_list(values), do: values

  defp list_values(value) when is_binary(value) do
    String.split(value, [",", "\n"], trim: true)
  end

  defp list_values(value), do: [value]

  defp get_key(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || get_atom_key(map, key)
  end

  defp get_key(map, key) when is_map(map), do: Map.get(map, key)
  defp get_key(_map, _key), do: nil

  defp get_atom_key(map, key) do
    atom_key = String.to_existing_atom(key)
    Map.get(map, atom_key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: to_string(value)

  defp blank?(value), do: is_nil(normalize_value(value))
end
