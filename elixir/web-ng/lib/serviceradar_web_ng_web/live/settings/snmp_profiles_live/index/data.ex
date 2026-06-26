defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SNMPProfiles.BuiltinTemplates
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting

  require Ash.Query

  def assign_profiles_with_counts(socket, scope) do
    {profiles, profile_target_counts} = load_profiles_with_counts(scope)

    socket
    |> assign(:profiles, profiles)
    |> assign(:profile_target_counts, profile_target_counts)
  end

  def load_profiles_with_counts(scope) do
    profiles = load_profiles(scope)
    counts = load_profile_target_counts(scope, profiles)
    {profiles, counts}
  end

  def load_profiles(scope) do
    case Ash.read(SNMPProfile, scope: scope) do
      {:ok, profiles} ->
        # Sort by priority (highest first), then by name
        Enum.sort_by(profiles, fn p -> {-p.priority, p.name} end)

      {:error, _} ->
        []
    end
  end

  def load_profile_target_counts(_scope, []), do: %{}

  def load_profile_target_counts(scope, profiles) do
    profile_queries =
      Enum.map(profiles, fn profile ->
        {profile.id, Targeting.profile_target_query(profile)}
      end)

    counts_by_query =
      profile_queries
      |> Enum.map(fn {_profile_id, target_query} -> target_query end)
      |> Enum.uniq()
      |> Map.new(fn target_query ->
        {target_query, Targeting.count_target_devices(scope, target_query)}
      end)

    Map.new(profile_queries, fn {profile_id, target_query} ->
      {profile_id, Map.get(counts_by_query, target_query, :unknown)}
    end)
  end

  def load_profile(scope, id) do
    case Ash.get(SNMPProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  def load_profile_targets(scope, profile_id) do
    query =
      SNMPTarget
      |> Ash.Query.filter(snmp_profile_id == ^profile_id)
      |> Ash.Query.sort(:name)

    case Ash.read(query, scope: scope) do
      {:ok, targets} -> targets
      {:error, _} -> []
    end
  end

  def load_target(scope, id) do
    case Ash.get(SNMPTarget, id, scope: scope) do
      {:ok, target} -> target
      {:error, _} -> nil
    end
  end

  def load_target_oids(scope, target_id) do
    query =
      SNMPOIDConfig
      |> Ash.Query.filter(snmp_target_id == ^target_id)
      |> Ash.Query.sort(:name)

    case Ash.read(query, scope: scope) do
      {:ok, oids} ->
        # Convert to map format for UI
        Enum.map(oids, fn oid ->
          %{
            "id" => oid.id,
            "oid" => oid.oid,
            "name" => oid.name,
            "data_type" => to_string(oid.data_type),
            "scale" => to_string(oid.scale),
            "delta" => oid.delta
          }
        end)

      {:error, _} ->
        []
    end
  end

  def load_custom_templates(scope) do
    case Ash.read(SNMPOIDTemplate, action: :list_custom, scope: scope) do
      {:ok, templates} -> templates
      {:error, _} -> []
    end
  end

  # The agent selector ships a hidden empty entry so unchecking every box still
  # submits the field. Strip blanks so the persisted array is clean ([] = legacy
  # all-agents, otherwise exactly the checked agent UIDs).
  def normalize_agent_ids_param(%{"agent_ids" => agent_ids} = params) when is_list(agent_ids) do
    Map.put(params, "agent_ids", Enum.reject(agent_ids, &(&1 in [nil, ""])))
  end

  def normalize_agent_ids_param(params), do: params

  # Load active agents for the per-agent targeting selector. Mirrors the sweep
  # agent picker (NetworksLive). Only agents seen recently are offered so the
  # operator pins to live agents.
  def load_agents(scope) do
    if RBAC.can?(scope, "settings.snmp_profiles.manage") do
      case Ash.read(Agent, domain: ServiceRadar.Infrastructure, scope: scope) do
        {:ok, agents} -> Enum.filter(agents, &active_agent?/1)
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  def active_agent?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen_time})
      when status in [:connected, :degraded, :connecting] do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  def active_agent?(%Agent{last_seen_time: %DateTime{} = last_seen_time}) do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  def active_agent?(_agent), do: false

  def agent_display_name(agent) do
    cond do
      agent.name && agent.name != "" -> agent.name
      agent.uid && agent.uid != "" -> agent.uid
      true -> "Agent #{agent.uid}"
    end
  end

  def load_all_templates(scope) do
    # Load builtin templates
    builtin =
      Enum.map(BuiltinTemplates.all_templates(), fn t ->
        %{
          id: t.id,
          name: t.name,
          description: t.description,
          vendor: t.vendor,
          category: t.category,
          oid_count: length(t.oids || []),
          is_builtin: true
        }
      end)

    # Load custom templates from database
    custom =
      case Ash.read(SNMPOIDTemplate, action: :list_custom, scope: scope) do
        {:ok, templates} ->
          Enum.map(templates, fn t ->
            %{
              id: t.id,
              name: t.name,
              description: t.description,
              vendor: t.vendor,
              category: t.category,
              oid_count: length(t.oids || []),
              is_builtin: false
            }
          end)

        {:error, _} ->
          []
      end

    builtin ++ custom
  end
end
