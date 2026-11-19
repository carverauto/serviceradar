defmodule ServiceRadarWebNGWeb.Auth.ClaimDiagnostics do
  @moduledoc """
  What an SSO claim set carries for role mapping, and what it resolved to.

  A token whose groups or roles match no configured mapping silently gets the
  default role, which is indistinguishable from a working mapping that grants
  that role. This makes the difference visible: at sign-in (one log line) and on
  the user's own profile.
  """

  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.RoleMapping
  alias ServiceRadar.Identity.RoleMappingSupport

  @role_claim_keys ~w[groups group roles role]
  @identity_claim_keys ~w[iss email preferred_username upn]
  @max_logged_values 25

  @type t :: %{
          role_claims: [{String.t(), [String.t()]}],
          identity: [{String.t(), String.t()}],
          groups_overage?: boolean(),
          mapping_count: non_neg_integer(),
          resolution: RoleMapping.resolution()
        }

  @doc "Diagnoses `claims` against the stored role mappings. `opts` carries the actor."
  @spec diagnose(map(), keyword()) :: t()
  def diagnose(claims, opts) when is_map(claims) do
    settings =
      case AuthorizationSettings.get_settings(opts) do
        {:ok, settings} -> settings
        {:error, _reason} -> nil
      end

    mappings = (settings && settings.role_mappings) || []

    %{
      role_claims: role_claims(claims, mappings),
      identity: identity(claims),
      groups_overage?: groups_overage?(claims),
      mapping_count: length(mappings),
      resolution: RoleMapping.resolve_with_settings(settings, claims)
    }
  end

  @doc """
  Whether the IdP left the groups claim out because the user is in too many
  groups (Microsoft Entra "overage"): the token then points at a Graph lookup
  instead of listing groups, so no group mapping can match.
  """
  @spec groups_overage?(map()) :: boolean()
  def groups_overage?(claims) when is_map(claims) do
    claim_names = RoleMappingSupport.get_key(claims, "_claim_names")

    (is_map(claim_names) and Map.has_key?(claim_names, "groups")) or
      RoleMappingSupport.get_key(claims, "hasgroups") in [true, "true"]
  end

  @doc "The log level and message for a sign-in's diagnosis."
  @spec log_entry(t(), atom()) :: {:info | :warning, String.t()}
  def log_entry(diagnosis, provider) do
    %{resolution: resolution, mapping_count: count} = diagnosis

    matched =
      Enum.map_join(resolution.matched, ", ", fn mapping ->
        "#{RoleMappingSupport.get_key(mapping, "source")}=#{RoleMappingSupport.get_key(mapping, "value")}"
      end)

    claims =
      diagnosis.role_claims
      |> Enum.map_join(" ", fn {key, values} ->
        "#{key}=[#{values |> Enum.take(@max_logged_values) |> Enum.join(", ")}]"
      end)
      |> case do
        "" -> "none"
        text -> text
      end

    detail =
      "provider=#{provider} mapped_role=#{resolution.role} mappings_configured=#{count} " <>
        "matched=[#{matched}] role_claims: #{claims} groups_overage=#{diagnosis.groups_overage?}"

    if count > 0 and resolution.matched == [] do
      {:warning, "SSO sign-in matched no role mapping; mappings grant only the default role. " <> detail}
    else
      {:info, "SSO role mapping resolved. " <> detail}
    end
  end

  defp role_claims(claims, mappings) do
    (@role_claim_keys ++ mapping_claim_keys(mappings))
    |> Enum.uniq()
    |> Enum.flat_map(fn key ->
      case claim_values(RoleMappingSupport.get_key(claims, key)) do
        [] -> []
        values -> [{key, values}]
      end
    end)
  end

  defp mapping_claim_keys(mappings) do
    mappings
    |> Enum.map(&RoleMappingSupport.presence(stringify(RoleMappingSupport.get_key(&1, "claim"))))
    |> Enum.reject(&is_nil/1)
  end

  defp identity(claims) do
    Enum.flat_map(@identity_claim_keys, fn key ->
      case RoleMappingSupport.get_key(claims, key) do
        value when is_binary(value) and value != "" -> [{key, value}]
        _ -> []
      end
    end)
  end

  defp claim_values(nil), do: []
  defp claim_values(list) when is_list(list), do: list |> Enum.map(&stringify/1) |> Enum.reject(&(&1 == ""))
  defp claim_values(value), do: Enum.reject([stringify(value)], &(&1 == ""))

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp stringify(value), do: inspect(value)
end
