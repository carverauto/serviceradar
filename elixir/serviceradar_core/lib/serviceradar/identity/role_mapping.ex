defmodule ServiceRadar.Identity.RoleMapping do
  @moduledoc """
  Resolves authorization roles from IdP claims using AuthorizationSettings.
  """

  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.RoleMappingSupport

  @default_role :viewer

  @typedoc """
  Everything a claim set resolves to.

  `matched` is kept so an operator can be shown *why* a user has the access they
  have -- the previous resolver returned a bare role atom, which made that
  unanswerable.
  """
  @type resolution :: %{
          role: atom(),
          role_profile_ids: [String.t()],
          user_group_ids: [String.t()],
          matched: [map()]
        }

  @doc """
  Resolve a role from IdP claims using stored mappings.

  Kept for callers that only want the role. `resolve/2` carries the rest.
  """
  def resolve_role(claims, opts \\ []) when is_map(claims) do
    resolve(claims, opts).role
  end

  @doc """
  Resolve every grant that `claims` matches.

  **Every** matching mapping contributes, not just the first. The previous
  implementation used `Enum.find_value/2`, so a user in three mapped groups got
  whichever mapping happened to be listed first, and reordering the list
  silently changed who could do what. Profiles and groups union; the role is the
  highest-privilege one matched, by `RoleMappingSupport.role_rank/1` rather than
  by atom comparison, which would sort :admin below :helpdesk.

  Falls back to the configured default role when nothing matches.
  """
  @spec resolve(map(), keyword()) :: resolution()
  def resolve(claims, opts \\ []) when is_map(claims) do
    case AuthorizationSettings.get_settings(opts) do
      {:ok, nil} -> empty_resolution(@default_role)
      {:ok, settings} -> resolve_from_settings(settings, claims)
      {:error, _reason} -> empty_resolution(@default_role)
    end
  end

  defp empty_resolution(role) do
    %{role: role, role_profile_ids: [], user_group_ids: [], matched: []}
  end

  defp resolve_from_settings(settings, claims) do
    matched = match_mappings(settings.role_mappings || [], claims)
    default_role = settings.default_role || @default_role

    role =
      matched
      |> Enum.map(&RoleMappingSupport.normalize_role(RoleMappingSupport.get_key(&1, "role")))
      |> RoleMappingSupport.highest_role()

    %{
      role: role || default_role,
      role_profile_ids: grant_ids(matched, "role_profile_id"),
      user_group_ids: grant_ids(matched, "user_group_id"),
      matched: matched
    }
  end

  defp grant_ids(matched, key) do
    matched
    |> Enum.map(&RoleMappingSupport.presence(RoleMappingSupport.get_key(&1, key)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp match_mappings(mappings, claims) do
    Enum.filter(mappings, fn mapping ->
      source = normalize_value(RoleMappingSupport.get_key(mapping, "source"))
      value = normalize_value(RoleMappingSupport.get_key(mapping, "value"))
      claim_key = normalize_value(RoleMappingSupport.get_key(mapping, "claim"))

      # A mapping no longer has to name a role to count; it may grant a profile
      # or a group instead, so matching is decided by source and value alone.
      value && source && matches?(source, value, claim_key, claims)
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
    email =
      normalize_value(RoleMappingSupport.get_key(claims, "email")) ||
        normalize_value(RoleMappingSupport.get_key(claims, "mail"))

    case email do
      nil -> false
      _ -> String.ends_with?(email, "@" <> value)
    end
  end

  defp matches?("email", value, _claim_key, claims) do
    email =
      normalize_value(RoleMappingSupport.get_key(claims, "email")) ||
        normalize_value(RoleMappingSupport.get_key(claims, "mail"))

    email == value
  end

  defp matches?("claim", value, claim_key, claims) do
    claim_key = claim_key || ""

    if claim_key == "" do
      false
    else
      claim_value = RoleMappingSupport.get_key(claims, claim_key)

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
      case RoleMappingSupport.get_key(claims, key) do
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
end
