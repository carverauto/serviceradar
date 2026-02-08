defmodule ServiceRadar.Identity.RoleMapping do
  @moduledoc """
  Resolves authorization roles from IdP claims using AuthorizationSettings.
  """

  alias ServiceRadar.Identity.AuthorizationSettings

  @default_role :viewer

  @doc """
  Resolve a role from IdP claims using stored mappings.

  Accepts an opts keyword list forwarded to Ash reads (actor/scope).
  """
  def resolve_role(claims, opts \\ []) when is_map(claims) do
    case AuthorizationSettings.get_settings(opts) do
      {:ok, nil} -> @default_role
      {:ok, settings} -> resolve_from_settings(settings, claims)
      {:error, _} -> @default_role
    end
  end

  defp resolve_from_settings(settings, claims) do
    mapping_role = match_mappings(settings.role_mappings || [], claims)
    mapping_role || settings.default_role || @default_role
  end

  defp match_mappings(mappings, claims) do
    Enum.find_value(mappings, fn mapping ->
      source = normalize_value(get_key(mapping, "source"))
      value = normalize_value(get_key(mapping, "value"))
      role = normalize_role(get_key(mapping, "role"))
      claim_key = normalize_value(get_key(mapping, "claim"))

      if role && value && source && matches?(source, value, claim_key, claims) do
        role
      else
        nil
      end
    end)
  end

  defp matches?("groups", value, claim_key, claims) do
    keys =
      if claim_key do
        [claim_key]
      else
        ["groups", "group", "roles", "role"]
      end

    values = extract_claim_values(claims, keys)
    Enum.any?(values, &(&1 == value))
  end

  defp matches?("email_domain", value, _claim_key, claims) do
    email = normalize_value(get_key(claims, "email")) || normalize_value(get_key(claims, "mail"))

    case email do
      nil -> false
      _ -> String.ends_with?(email, "@" <> value)
    end
  end

  defp matches?("email", value, _claim_key, claims) do
    email = normalize_value(get_key(claims, "email")) || normalize_value(get_key(claims, "mail"))
    email == value
  end

  defp matches?("claim", value, claim_key, claims) do
    claim_key = claim_key || ""

    if claim_key == "" do
      false
    else
      claim_value = get_key(claims, claim_key)

      case claim_value do
        list when is_list(list) -> Enum.any?(list, &(normalize_value(&1) == value))
        other -> normalize_value(other) == value
      end
    end
  end

  defp matches?(_, _value, _claim_key, _claims), do: false

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

  defp split_values(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&normalize_value/1)
  end

  defp split_values(value), do: [normalize_value(value)]

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: to_string(value)

  defp normalize_role(nil), do: nil
  defp normalize_role(role) when role in [:viewer, :helpdesk, :operator, :admin], do: role

  defp normalize_role(role) when is_binary(role) do
    case role do
      "viewer" -> :viewer
      "helpdesk" -> :helpdesk
      "operator" -> :operator
      "admin" -> :admin
      _ -> nil
    end
  end

  defp get_key(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || get_atom_key(map, key)
  end

  defp get_key(map, key) when is_map(map), do: Map.get(map, key)

  defp get_atom_key(map, key) do
    atom_key = String.to_existing_atom(key)
    Map.get(map, atom_key)
  rescue
    ArgumentError -> nil
  end
end
