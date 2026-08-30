defmodule ServiceRadar.Plugins.SNMPRequirementCatalog do
  @moduledoc """
  Materializes package-declared SNMP requirements as operator-owned rows.

  A plugin **declares what it needs polled**; it never arms the polling. Each
  requirement becomes two ordinary rows an operator can see and edit in
  `/settings/snmp`: an `SNMPOIDTemplate` holding the OIDs, and an `SNMPProfile`
  created `enabled: false`, with no credentials and no agents bound.

  Three properties, all deliberate:

    * **Sync runs on APPROVE, not on import.** A staged package's manifest has
      not been reviewed by anyone. SNMP is a stronger case than alert rules: an
      approved requirement ultimately produces outbound UDP/161 traffic to real
      inventory devices bearing real credentials.

    * **Inert twice over.** `enabled: false`, and `SNMPProfile.resolve_profile`
      requires `enabled == true`. Even if enabled, `compile_device_target`
      skips every device when credentials do not resolve, so an un-credentialed
      profile compiles to zero targets. The failure being guarded against - a
      package silently probing production on approval - is not one a single
      boolean should stand alone against.

    * **Re-sync writes the OID list and nothing else.** Which OIDs carry which
      metric is intrinsic: a fact of the MIB, identical on every deployment, and
      owned by the plugin that reads the results. Cadence, targeting,
      credentials, agents, priority and whether to poll at all are deployment
      facts owned outright by the operator, so they are written once at create
      and never again. An operator who wants a different OID list forks the
      template with `copy_template_to_custom`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query
  require Logger

  # What a plugin owns on the template. Everything else, on either row, belongs
  # to the operator.
  @template_definition_fields [:description, :category, :oids]

  # Seeded from the manifest at create so an operator is not reverse-engineering
  # cadence or targeting, then never written again.
  @seed_only_profile_fields [:target_query, :poll_interval, :timeout, :retries]

  # Mirrors maxOIDNameLength in go/pkg/agent/snmp/config.go.
  @max_oid_name_length 64

  # Vendor marks the template as plugin-contributed. It is not "builtin", so
  # the template browser's Custom tab already renders it.
  @plugin_vendor "plugin"

  @spec sync_package(PluginPackage.t(), keyword()) :: :ok | {:error, term()}
  def sync_package(package, opts \\ [])

  def sync_package(%PluginPackage{} = package, opts) do
    sync_requirements(package, package.snmp_requirements || [], opts)
  end

  def sync_package(_package, _opts), do: :ok

  @doc """
  Disable every profile a package proposed.

  Used when a package is denied, revoked or restaged. Rows are kept rather than
  deleted so an operator can still see what a since-revoked plugin was polling,
  and so re-approving does not silently lose their tuning. The template is left
  untouched: it is inert on its own, and deleting it would break any profile an
  operator had added it to.
  """
  @spec disable_package_snmp(PluginPackage.t(), keyword()) :: :ok | {:error, term()}
  def disable_package_snmp(%PluginPackage{} = package, opts) do
    _opts = opts
    actor = SystemActor.system(:snmp_requirement_catalog)

    case package_profiles(package.id, actor) do
      {:ok, profiles} ->
        Enum.reduce_while(profiles, :ok, fn profile, :ok ->
          case update_profile(profile, %{enabled: false}, actor) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def disable_package_snmp(_package, _opts), do: :ok

  defp sync_requirements(package, requirements, opts) when is_list(requirements) do
    _opts = opts
    actor = SystemActor.system(:snmp_requirement_catalog)

    Enum.reduce_while(requirements, :ok, fn requirement, :ok ->
      case sync_requirement(package, normalize_map(requirement), actor) do
        {:ok, _profile} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_requirements(_package, _requirements, _opts), do: :ok

  defp sync_requirement(package, requirement, actor) do
    name = qualified_name(package, map_get(requirement, "name"))

    with {:ok, template} <- sync_template(package, requirement, name, actor) do
      sync_profile(package, requirement, name, template, actor)
    end
  end

  defp sync_template(package, requirement, name, actor) do
    definition = %{
      description: map_get(requirement, "description"),
      category: map_get(requirement, "category"),
      oids: namespaced_oids(package, map_get(requirement, "oids") || [])
    }

    case find_existing(SNMPOIDTemplate, package.id, name, actor) do
      {:ok, nil} ->
        attrs =
          definition
          |> Map.merge(%{name: name, vendor: @plugin_vendor})
          |> drop_nils()

        SNMPOIDTemplate
        |> Ash.Changeset.for_create(:create, attrs)
        |> put_provenance(package)
        |> Ash.create(actor: actor)

      {:ok, template} ->
        template
        |> Ash.Changeset.for_update(
          :update,
          drop_nils(Map.take(definition, @template_definition_fields))
        )
        |> Ash.update(actor: actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_profile(package, requirement, name, template, actor) do
    case find_existing(SNMPProfile, package.id, name, actor) do
      {:ok, nil} ->
        attrs =
          requirement
          |> seed_profile_tuning()
          |> Map.merge(%{
            name: name,
            description: map_get(requirement, "description"),
            oid_template_ids: [template.id],
            # None of the following is ever taken from the manifest, and the
            # manifest cannot express any of them. A package must not start
            # probing inventory, become the instance default, outrank an
            # operator's profile, or pin itself to agents.
            enabled: false,
            is_default: false,
            priority: 0,
            agent_ids: []
          })
          |> drop_nils()

        SNMPProfile
        |> Ash.Changeset.for_create(:create, attrs)
        |> put_provenance(package)
        |> Ash.create(actor: actor)

      # Deliberately a no-op. Every remaining field on a profile is
      # operator-owned, including oid_template_ids: if an operator removed the
      # plugin's template or added their own, an upgrade must not reinstate the
      # list. This is also what stops a re-approve after a revoke from re-arming
      # polling, since `enabled` is never written here.
      {:ok, profile} ->
        {:ok, profile}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Provenance is forced rather than accepted: neither resource lists
  # `plugin_package_id` in its action's `accept`, so an ordinary API caller
  # cannot claim a package contributed their row.
  defp put_provenance(changeset, package) do
    changeset
    |> Ash.Changeset.force_change_attribute(:plugin_package_id, package.id)
    |> Ash.Changeset.force_change_attribute(:plugin_contributed, true)
  end

  defp update_profile(profile, attrs, actor) do
    profile
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end

  # Templates and profiles are namespaced by package for the same reason alert
  # rules are: the name is the lookup key, and an unqualified name could collide
  # with an operator's own row.
  defp qualified_name(package, name), do: "plugin:#{package.name}:#{name}"

  # The agent rejects duplicate OID *names* within a target
  # (`errOIDDuplicate`), while `load_template_oids/2` dedupes by OID *string*
  # only. A plugin shipping `ifInOctets` alongside an operator template that
  # already has one would otherwise produce a name collision that rejects the
  # entire agent config - taking out every other profile on that agent.
  defp namespaced_oids(package, oids) when is_list(oids) do
    prefix = package |> Map.get(:name) |> slug() |> String.slice(0, 20)

    oids
    |> Enum.map_reduce(MapSet.new(), fn oid, seen ->
      oid = normalize_map(oid)
      name = namespaced_oid_name(prefix, map_get(oid, "name"))

      name =
        if MapSet.member?(seen, name),
          do: disambiguate(name, map_get(oid, "oid")),
          else: name

      {Map.put(oid, "name", name), MapSet.put(seen, name)}
    end)
    |> elem(0)
  end

  defp namespaced_oids(_package, _oids), do: []

  defp namespaced_oid_name(prefix, name) do
    name = slug(name)

    case prefix do
      "" -> String.slice(name, 0, @max_oid_name_length)
      prefix -> String.slice(prefix <> "_" <> name, 0, @max_oid_name_length)
    end
  end

  # Truncation can map two distinct OID names onto one. The suffix is derived
  # from the OID itself so it is stable across re-syncs rather than dependent on
  # declaration order.
  defp disambiguate(name, oid) do
    suffix =
      oid
      |> to_string()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 8)

    String.slice(name, 0, @max_oid_name_length - 9) <> "_" <> suffix
  end

  defp slug(value) when is_binary(value), do: String.replace(value, ~r/[^A-Za-z0-9_-]/, "_")
  defp slug(_value), do: ""

  defp seed_profile_tuning(requirement) do
    Enum.reduce(@seed_only_profile_fields, %{}, fn field, acc ->
      case map_get(requirement, manifest_key(field)) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp manifest_key(:target_query), do: "target_hint"
  defp manifest_key(:poll_interval), do: "default_poll_interval_seconds"
  defp manifest_key(:timeout), do: "default_timeout_seconds"
  defp manifest_key(:retries), do: "default_retries"

  defp find_existing(resource, package_id, name, actor) do
    resource
    |> Ash.Query.filter(plugin_package_id == ^package_id and name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp package_profiles(package_id, actor) do
    SNMPProfile
    |> Ash.Query.filter(plugin_package_id == ^package_id)
    |> Ash.read(actor: actor)
  end

  defp normalize_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_map(_map), do: %{}

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil

  defp drop_nils(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
