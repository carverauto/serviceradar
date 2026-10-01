defmodule ServiceRadar.Automation.Northbound.PluginPackageContext do
  @moduledoc """
  Package-scoped context for northbound actions provided by a Wasm plugin.

  Everything here is derived from the approved package manifest and from the
  records the credential provisioner writes for that package, never from an
  invocation input:

    * the package's declared `integrations.inventory_sources`, which bound the
      `integration_id` identifiers a target snapshot may expose to the plugin;
    * the secret bound into a producer schedule on the invocation's plugin
      assignment (`credential_source: assignment_schedule`);
    * the credential rules provisioned for the package, among which an operator
      may choose one by id (`credential_source: package_rule`).

  A credential rule is provisioned for a package when it is enabled, its
  provider is the provider of one of the package's `producer_schedule`
  credential profiles, and an enabled plugin assignment of that package carries
  the provisioner policy id of that rule. That is the linkage
  `ServiceRadar.Credentials.PluginIntegrationProvisioner` creates, so a rule of
  another package or provider, a disabled rule, or an arbitrary secret id is
  never eligible.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Plugins.ActionCredentialRequirements
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ProducerSchedule

  require Ash.Query

  @type rule_option :: %{required(String.t()) => String.t()}

  @doc """
  The inventory sources declared by an approved package, sorted.

  A package that is missing or not approved declares none.
  """
  @spec inventory_sources(String.t() | nil, keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def inventory_sources(package_id, opts \\ []) do
    with {:ok, manifest} <- approved_manifest(package_id, actor(opts)) do
      {:ok,
       manifest
       |> manifest_integrations("inventory_sources")
       |> Enum.map(& &1["source"])
       |> Enum.filter(&is_binary/1)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  @doc """
  Keeps only `integration_id` values whose `<source>:` prefix is one of
  `sources` and which carry a non-empty id after it; sorted and deduplicated.
  """
  @spec own_integration_ids([String.t()], [String.t()]) :: [String.t()]
  def own_integration_ids(values, sources) when is_list(values) and is_list(sources) do
    prefixes = Enum.map(sources, &(&1 <> ":"))

    values
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(fn value ->
      Enum.any?(prefixes, fn prefix ->
        String.starts_with?(value, prefix) and byte_size(value) > byte_size(prefix)
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def own_integration_ids(_values, _sources), do: []

  @doc """
  The secret reference bound under `credential_refs[ref_name]` of an enabled
  producer schedule of the assignment's own package on that assignment.
  """
  @spec schedule_credential(map(), String.t(), keyword()) ::
          {:ok, %{secret_ref: String.t(), credential_rule_id: String.t() | nil}}
          | {:error, term()}
  def schedule_credential(assignment, ref_name, opts \\ [])

  def schedule_credential(%{id: assignment_id, plugin_package_id: package_id}, ref_name, opts)
      when is_binary(ref_name) and not is_nil(assignment_id) and not is_nil(package_id) do
    actor = actor(opts)

    ProducerSchedule
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      producer_kind == :wasm_plugin and enabled == true and
        plugin_assignment_id == ^assignment_id and plugin_package_id == ^package_id
    )
    |> Ash.Query.sort(schedule_id: :asc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, schedules} ->
        Enum.find_value(schedules, {:error, :no_bound_schedule}, fn schedule ->
          case bound_ref(schedule, ref_name) do
            nil ->
              nil

            secret_ref ->
              {:ok,
               %{
                 secret_ref: secret_ref,
                 credential_rule_id: metadata_string(schedule.metadata, "credential_rule_id")
               }}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  def schedule_credential(_assignment, _ref_name, _opts), do: {:error, :no_bound_schedule}

  @doc """
  The credential rules provisioned for an approved package, sorted by name.
  """
  @spec eligible_rules(String.t() | nil, keyword()) :: {:ok, [struct()]} | {:error, term()}
  def eligible_rules(package_id, opts \\ []) do
    rule_actor = Keyword.get(opts, :actor)
    actor = SystemActor.system(:northbound_plugin_package_context)

    with :ok <- authorize_rule_read(rule_actor),
         {:ok, manifest} <- approved_manifest(package_id, actor),
         providers when providers != [] <- scheduled_providers(manifest),
         {:ok, policy_ids} <- provisioned_policy_ids(package_id, actor),
         {:ok, rules} <- enabled_rules_for_providers(providers, rule_actor) do
      {:ok,
       rules
       |> Enum.filter(fn rule ->
         MapSet.member?(policy_ids, PluginIntegrationProvisioner.policy_id_for_rule_id(rule.id))
       end)
       |> Enum.filter(&purpose_matches?(&1, Keyword.get(opts, :purpose)))
       |> Enum.sort_by(&{String.downcase(&1.name || ""), to_string(&1.id)})}
    else
      [] -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Resolves an operator-supplied credential rule id among the package's
  eligible rules. Any other id is `{:error, :credential_rule_not_eligible}`.
  """
  @spec eligible_rule(String.t() | nil, term(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def eligible_rule(package_id, rule_id, opts \\ []) do
    with {:ok, rule_id} <- cast_uuid(rule_id),
         {:ok, rules} <- eligible_rules(package_id, opts) do
      case Enum.find(rules, &(to_string(&1.id) == rule_id)) do
        nil -> {:error, :credential_rule_not_eligible}
        rule -> {:ok, rule}
      end
    end
  end

  @doc """
  Candidate credential rules for every `package_rule` requirement of a
  descriptor, keyed by the requirement's `rule_input`.

  Each option carries only the rule id and its name; no secret material.
  The caller is responsible for having authorized the descriptor for the
  operator (the catalog reads it through `:launchable_for_scope`).
  """
  @spec rule_options(map(), map() | nil, keyword()) ::
          {:ok, %{String.t() => [rule_option()]}} | {:error, term()}
  def rule_options(descriptor, provider, opts \\ [])

  def rule_options(
        %{credential_requirements: requirements},
        %{provider_type: :wasm_plugin, plugin_package_id: package_id},
        opts
      )
      when not is_nil(package_id) do
    case package_rule_requirements(requirements) do
      [] ->
        {:ok, %{}}

      rule_requirements ->
        with {:ok, rules} <- eligible_rules(package_id, opts) do
          options =
            rule_requirements
            |> Enum.group_by(& &1.input)
            |> Map.new(fn {input, requirements} ->
              eligible =
                Enum.filter(rules, fn rule ->
                  Enum.all?(requirements, &purpose_matches?(rule, &1.purpose))
                end)

              {input, Enum.map(eligible, &rule_option/1)}
            end)

          {:ok, options}
        end
    end
  end

  def rule_options(_descriptor, _provider, _opts), do: {:ok, %{}}

  @doc "The `rule_input` keys of a descriptor's `package_rule` requirements."
  @spec package_rule_inputs(term()) :: [String.t()]
  def package_rule_inputs(requirements) do
    requirements
    |> package_rule_requirements()
    |> Enum.map(& &1.input)
    |> Enum.uniq()
  end

  @doc "The required `rule_input` keys of a descriptor's `package_rule` requirements."
  @spec package_rule_required_inputs(term()) :: [String.t()]
  def package_rule_required_inputs(requirements) do
    requirements
    |> package_rule_requirements()
    |> Enum.filter(& &1.required)
    |> Enum.map(& &1.input)
    |> Enum.uniq()
  end

  defp package_rule_requirements(requirements) do
    requirements
    |> ActionCredentialRequirements.flatten()
    |> Enum.filter(&(ActionCredentialRequirements.credential_source(&1) == "package_rule"))
    |> Enum.map(fn requirement ->
      input = requirement["rule_input"]

      if is_binary(input) and String.trim(input) != "" do
        %{
          input: String.trim(input),
          purpose: requirement["purpose"],
          required: requirement["required"] == true or requirement["required?"] == true
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp purpose_matches?(_rule, nil), do: true

  defp purpose_matches?(rule, purpose) when is_binary(purpose) and purpose != "" do
    rule_purpose = Map.get(rule, :purpose) || Map.get(rule, "purpose")
    rule_purpose == purpose
  end

  defp purpose_matches?(_rule, _purpose), do: false

  defp rule_option(rule) do
    %{"id" => to_string(rule.id), "label" => rule.name || to_string(rule.id)}
  end

  defp approved_manifest(nil, _actor), do: {:ok, nil}

  defp approved_manifest(package_id, actor) do
    case Ecto.UUID.cast(to_string(package_id)) do
      {:ok, package_id} ->
        PluginPackage
        |> Ash.Query.for_read(:approved, %{}, actor: actor)
        |> Ash.Query.filter(id == ^package_id)
        |> Ash.read_one(actor: actor)
        |> case do
          {:ok, nil} -> {:ok, nil}
          {:ok, package} -> parse_manifest(package)
          {:error, error} -> {:error, error}
        end

      :error ->
        {:ok, nil}
    end
  end

  defp parse_manifest(%PluginPackage{manifest: manifest}) when is_map(manifest) do
    case Manifest.from_map(manifest) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, {:invalid_approved_plugin_manifest, errors}}
    end
  end

  defp parse_manifest(_package), do: {:ok, nil}

  defp manifest_integrations(nil, _key), do: []

  defp manifest_integrations(%Manifest{integrations: integrations}, key) do
    integrations
    |> Kernel.||(%{})
    |> Map.get(key)
    |> List.wrap()
  end

  defp scheduled_providers(manifest) do
    manifest
    |> manifest_integrations("credential_profiles")
    |> Enum.filter(&(get_in(&1, ["provisioning", "mode"]) == "producer_schedule"))
    |> Enum.map(& &1["provider"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp provisioned_policy_ids(package_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:by_package, %{plugin_package_id: package_id}, actor: actor)
    |> Ash.Query.filter(source == :policy)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} ->
        {:ok,
         assignments
         |> Enum.map(& &1.policy_id)
         |> Enum.filter(&is_binary/1)
         |> MapSet.new()}

      {:error, error} ->
        {:error, error}
    end
  end

  defp enabled_rules_for_providers(providers, actor) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(enabled == true and provider in ^providers)
    |> Ash.read(actor: actor)
  end

  defp bound_ref(schedule, ref_name) do
    case schedule.credential_refs do
      %{} = refs ->
        case Map.get(refs, ref_name) do
          value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp metadata_string(%{} = metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp metadata_string(_metadata, _key), do: nil

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :credential_rule_not_eligible}
    end
  end

  defp cast_uuid(_value), do: {:error, :credential_rule_not_eligible}

  defp actor(opts) do
    Keyword.get(opts, :actor) || SystemActor.system(:northbound_plugin_package_context)
  end

  defp authorize_rule_read(%{role: :system}), do: :ok

  defp authorize_rule_read(actor) do
    if RBAC.has_permission?(actor, "settings.credentials.manage"),
      do: :ok,
      else: {:error, :credential_rule_permission_required}
  end
end
