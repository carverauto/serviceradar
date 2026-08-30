defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SNMPProfiles.BuiltinTemplates
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting

  require Ash.Query

  def assign_profiles_with_counts(socket, scope) do
    {profiles, profile_target_counts} = load_profiles_with_counts(scope)

    socket
    |> assign(:profiles, profiles)
    |> assign(:profile_target_counts, profile_target_counts)
    |> assign(:profile_package_names, Provenance.load_package_names(scope, profiles))
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
            "delta" => oid.delta,
            "mode" => to_string(oid.mode || :get),
            "max_rows" => oid.max_rows,
            "walk_timeout_seconds" => oid.walk_timeout_seconds
          }
        end)

      {:error, _} ->
        []
    end
  end

  def assign_custom_templates(socket, scope) do
    templates = load_custom_templates(scope)

    socket
    |> assign(:custom_templates, templates)
    |> assign(:template_package_names, Provenance.load_package_names(scope, templates))
  end

  def load_custom_templates(scope) do
    case Ash.read(SNMPOIDTemplate, action: :list_custom, scope: scope) do
      {:ok, templates} -> templates
      {:error, _} -> []
    end
  end

  @doc """
  Reusable SNMP credentials a profile or target can bind instead of holding its
  own encrypted copy.

  Filtered to `credential_kind == :snmp`, because that is the only kind whose
  payload `SNMPProfiles.CredentialResolver` knows how to read. Offering an
  `:api_token` here would produce a rule that resolves to material SNMP cannot
  use, and the failure would surface at poll time rather than at selection.

  Returns `{label, id}` pairs for a select. The label carries the provider so
  two credentials named "core switches" from different sources stay
  distinguishable.
  """
  def load_snmp_credentials(scope) do
    NetworkCredentialSecret
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(credential_kind == :snmp)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, secrets} -> secrets
      _ -> []
    end
  end

  @doc "Select options for `load_snmp_credentials/1`, with a profile-local default."
  def snmp_credential_options(secrets) do
    [{"Store on this profile (encrypted here)", ""}] ++
      Enum.map(secrets, fn secret ->
        {"#{secret.name} (#{secret.provider})", secret.id}
      end)
  end

  @doc """
  Creates a reusable SNMP credential from the credential fields already on the
  profile form.

  The operator types the community string or v3 user exactly as before; ticking
  "save as reusable" additionally stores it in the shared inventory and binds
  the profile to it, instead of encrypting a private copy onto the profile.

  The values are routed through `CredentialSecretBuilder` against the native
  SNMP descriptor rather than being assembled here, so a shared SNMP credential
  is validated, encoded, fingerprinted and redacted by exactly the same code as
  a package-owned one. Choosing the auth method from the SNMP version is the
  only SNMP-specific decision, and it is the same decision the form already
  makes when it picks which fields to show.
  """
  def create_snmp_credential(scope, version, name, field_values) do
    auth_method = if to_string(version) in ["v1", "v2c"], do: "community", else: "v3"

    values =
      field_values
      |> Enum.reject(fn {_key, value} -> is_nil(value) or String.trim(to_string(value)) == "" end)
      |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)

    with {:ok, descriptor} <- NativeDescriptors.fetch("snmp"),
         {:ok, attrs} <-
           CredentialSecretBuilder.build(descriptor, auth_method, values, %{
             name: name,
             description: "Created from SNMP profile #{name}"
           }),
         {:ok, secret} <-
           NetworkCredentialSecret
           |> Ash.Changeset.for_create(:create, attrs, scope: scope)
           |> Ash.create(scope: scope) do
      {:ok, secret}
    else
      :error -> {:error, :snmp_descriptor_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # The agent selector ships a hidden empty entry so unchecking every box still
  # submits the field. Strip blanks so the persisted array is clean ([] = legacy
  # all-agents, otherwise exactly the checked agent UIDs).
  # "Store on this profile" is the empty option of the credential select, so an
  # unselected credential arrives as "". `credential_secret_id` is a :uuid, and
  # Ash does not cast "" to nil for that type the way it does for :string -- it
  # fails to cast. Blank means "no shared credential", so send nil.
  def normalize_credential_secret_param(%{"credential_secret_id" => value} = params) when is_binary(value) do
    case String.trim(value) do
      "" -> Map.put(params, "credential_secret_id", nil)
      trimmed -> Map.put(params, "credential_secret_id", trimmed)
    end
  end

  def normalize_credential_secret_param(params), do: params

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
