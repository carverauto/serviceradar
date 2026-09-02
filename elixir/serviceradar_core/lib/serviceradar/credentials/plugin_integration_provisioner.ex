defmodule ServiceRadar.Credentials.PluginIntegrationProvisioner do
  @moduledoc """
  Reconciles package-declared credential integrations into plugin assignments and
  package-owned producer schedules.

  Provider behavior comes from a validated signed manifest and JSON Schema. Stored
  assignments contain only public plugin configuration. Producer schedules retain a
  secret reference that the dispatcher resolves into short-lived endpoint-scoped
  grants immediately before each command.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @policy_suffix "plugin_integration"

  @type summary :: %{
          rules: non_neg_integer(),
          assignments_written: non_neg_integer(),
          assignments_disabled: non_neg_integer(),
          schedules_bound: non_neg_integer(),
          schedules_disabled: non_neg_integer()
        }

  @doc "Reconcile all credential rules owned by approved plugin integration descriptors."
  @spec reconcile_all(keyword()) :: {:ok, summary()} | {:error, term()}
  def reconcile_all(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_provisioner))

    with {:ok, profiles} <- load_profiles(actor, opts),
         {:ok, rules} <- load_rules(actor, opts) do
      reconcile_rules(rules, profiles, Keyword.put(opts, :actor, actor))
    end
  end

  @doc false
  @spec reconcile_rules([map()], [map()], keyword()) :: {:ok, summary()} | {:error, term()}
  def reconcile_rules(rules, profiles, opts \\ [])

  def reconcile_rules(rules, profiles, opts) when is_list(rules) and is_list(profiles) do
    profiles_by_provider = Map.new(profiles, &{&1["provider"], &1})

    rules
    |> Enum.filter(&plugin_integration_rule?(&1, profiles_by_provider))
    |> Enum.filter(&producer_schedule_rule?(&1, profiles_by_provider))
    |> Enum.reduce_while({:ok, empty_summary()}, fn rule, {:ok, summary} ->
      provider = provider(rule)

      case {Map.get(profiles_by_provider, provider), rule_enabled?(rule)} do
        {%{} = profile, true} ->
          case reconcile_rule(rule, profile, opts) do
            {:ok, result} ->
              {:cont,
               {:ok,
                %{
                  summary
                  | rules: summary.rules + 1,
                    assignments_written:
                      summary.assignments_written + bool_count(result.assignment_changed?),
                    schedules_bound:
                      summary.schedules_bound + bool_count(result.schedule_changed?)
                }}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {_profile_or_nil, false} ->
          disable_and_continue(rule, summary, opts)

        {nil, true} ->
          # A revoked package must not leave its previous assignment runnable.
          disable_and_continue(rule, summary, opts)
      end
    end)
  end

  def reconcile_rules(_rules, _profiles, _opts), do: {:error, :invalid_plugin_integration_rules}

  @doc "Reconcile one enabled package-declared credential integration rule."
  @spec reconcile_rule(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_rule(rule, profile, opts \\ [])

  def reconcile_rule(rule, profile, opts) when is_map(rule) and is_map(profile) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_provisioner))

    with :ok <- validate_rule(rule, profile),
         {:ok, params} <- plugin_params(rule, profile),
         {:ok, cadence_seconds} <- cadence_seconds(rule, profile),
         {:ok, assignment, assignment_changed?} <-
           upsert_assignment(rule, profile, params, actor, opts),
         {:ok, schedule, schedule_changed?} <-
           bind_schedule(
             rule,
             profile,
             assignment,
             params,
             cadence_seconds,
             actor,
             opts
           ) do
      {:ok,
       %{
         rule: rule,
         assignment: assignment,
         schedule: schedule,
         assignment_changed?: assignment_changed?,
         schedule_changed?: schedule_changed?
       }}
    end
  end

  def reconcile_rule(_rule, _profile, _opts), do: {:error, :invalid_plugin_integration}

  defp load_profiles(actor, opts) do
    case Keyword.fetch(opts, :profiles) do
      {:ok, profiles} when is_list(profiles) -> {:ok, profiles}
      {:ok, _invalid} -> {:error, :invalid_plugin_integration_profiles}
      :error -> [actor: actor] |> IntegrationCatalog.load() |> map_catalog_profiles()
    end
  end

  defp map_catalog_profiles({:ok, catalog}), do: {:ok, catalog.credential_profiles}
  defp map_catalog_profiles({:error, reason}), do: {:error, reason}

  defp load_rules(actor, opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} when is_list(rules) ->
        {:ok, rules}

      {:ok, _invalid} ->
        {:error, :invalid_plugin_integration_rules}

      :error ->
        NetworkCredentialRule
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.read(actor: actor)
    end
  end

  defp upsert_assignment(rule, profile, params, actor, opts) do
    store = Keyword.get(opts, :assignment_store, __MODULE__.AssignmentStore)
    agent_uid = scope_agent(rule)
    policy_id = policy_id(rule)
    schedule = profile["producer_schedule"]

    attrs = %{
      agent_uid: agent_uid,
      plugin_package_id: profile["plugin_package_id"],
      source: :policy,
      source_key: source_key(rule, agent_uid),
      policy_id: policy_id,
      enabled: true,
      interval_seconds: schedule["default_cadence_seconds"],
      timeout_seconds: schedule["timeout_seconds"],
      params: params
    }

    with {:ok, assignments} <- store.list_policy_assignments(policy_id, actor),
         :ok <- ensure_one_assignment_per_agent(assignments, agent_uid),
         {:ok, _disabled_count} <-
           disable_other_agent_assignments(assignments, agent_uid, actor, store) do
      case Enum.find(assignments, &(to_string(&1.agent_uid) == agent_uid)) do
        nil ->
          with {:ok, assignment} <- store.create_assignment(attrs, actor) do
            {:ok, assignment, true}
          end

        assignment ->
          if assignment_matches?(assignment, attrs) do
            {:ok, assignment, false}
          else
            with {:ok, updated} <-
                   store.update_assignment(assignment, Map.delete(attrs, :agent_uid), actor) do
              {:ok, updated, true}
            end
          end
      end
    end
  end

  defp bind_schedule(rule, profile, assignment, params, cadence_seconds, actor, opts) do
    store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)
    provisioning = profile["provisioning"]
    package_id = profile["plugin_package_id"]
    schedule_id = provisioning["schedule_id"]
    requirement = provisioning["credential_requirement"]

    with {:ok, schedule} <- store.get_package_schedule(package_id, schedule_id, actor),
         false <- is_nil(schedule) do
      attrs = %{
        enabled: schedule_enabled?(rule),
        schedule_type: :interval,
        cadence_seconds: cadence_seconds,
        plugin_assignment_id: assignment.id,
        params: params,
        credential_refs: %{
          requirement => SecretRefs.network_credential_ref(required_value!(rule, :secret_id))
        },
        metadata:
          (schedule.metadata || %{})
          |> Map.put("credential_rule_id", required_value!(rule, :id))
          |> Map.put("integration_provider", profile["provider"])
      }

      if schedule_matches?(schedule, attrs) do
        {:ok, schedule, false}
      else
        with {:ok, updated} <- store.update_schedule(schedule, attrs, actor) do
          {:ok, updated, true}
        end
      end
    else
      true -> {:error, {:producer_schedule_not_found, profile["plugin_id"], schedule_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disable_and_continue(rule, summary, opts) do
    case disable_rule(rule, opts) do
      {:ok, %{assignments: assignments, schedules: schedules}} ->
        {:cont,
         {:ok,
          %{
            summary
            | rules: summary.rules + 1,
              assignments_disabled: summary.assignments_disabled + assignments,
              schedules_disabled: summary.schedules_disabled + schedules
          }}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp disable_rule(rule, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_provisioner))
    assignment_store = Keyword.get(opts, :assignment_store, __MODULE__.AssignmentStore)
    schedule_store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)

    with {:ok, assignments} <- assignment_store.list_policy_assignments(policy_id(rule), actor) do
      Enum.reduce_while(assignments, {:ok, %{assignments: 0, schedules: 0}}, fn assignment,
                                                                                {:ok, counts} ->
        with {:ok, assignment_count} <- disable_assignment(assignment, actor, assignment_store),
             {:ok, schedule_count} <-
               disable_assignment_schedules(assignment, actor, schedule_store) do
          {:cont,
           {:ok,
            %{
              assignments: counts.assignments + assignment_count,
              schedules: counts.schedules + schedule_count
            }}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp disable_assignment(%{enabled: false}, _actor, _store), do: {:ok, 0}

  defp disable_assignment(assignment, actor, store) do
    case store.update_assignment(assignment, %{enabled: false}, actor) do
      {:ok, _updated} -> {:ok, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disable_assignment_schedules(assignment, actor, store) do
    with {:ok, schedules} <- store.list_assignment_schedules(assignment.id, actor) do
      Enum.reduce_while(schedules, {:ok, 0}, fn schedule, {:ok, count} ->
        if schedule.enabled do
          case store.update_schedule(schedule, %{enabled: false}, actor) do
            {:ok, _updated} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, count}}
        end
      end)
    end
  end

  defp disable_other_agent_assignments(assignments, agent_uid, actor, store) do
    assignments
    |> Enum.reject(&(to_string(&1.agent_uid) == agent_uid))
    |> Enum.reduce_while({:ok, 0}, fn assignment, {:ok, count} ->
      case disable_assignment(assignment, actor, store) do
        {:ok, changed} -> {:cont, {:ok, count + changed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_rule(rule, profile) do
    auth_methods = Enum.map(profile["auth_methods"], & &1["id"])
    purposes = profile["purposes"]
    scope_types = profile["scope_types"]

    cond do
      provider(rule) != profile["provider"] ->
        {:error, :invalid_plugin_integration_provider}

      RuleAccessors.auth_method(rule) not in auth_methods ->
        {:error, :invalid_plugin_integration_auth_method}

      RuleAccessors.rule_purpose(rule) not in purposes ->
        {:error, :invalid_plugin_integration_purpose}

      scope_type(rule) not in scope_types ->
        {:error, :invalid_plugin_integration_scope}

      scope_type(rule) != "agent" or is_nil(scope_agent(rule)) ->
        {:error, :plugin_integration_requires_agent_scope}

      true ->
        :ok
    end
  end

  defp plugin_params(rule, profile) do
    metadata = RuleAccessors.metadata(rule)
    params = ValueUtils.map_value(metadata, ["plugin_config"], stringify_keys: true) || %{}
    schema = profile["config_schema"] || %{}
    normalized = ConfigSchema.normalize_params(schema, params)

    case ConfigSchema.validate_params(schema, normalized) do
      :ok -> {:ok, normalized}
      {:error, errors} -> {:error, {:invalid_plugin_integration_config, errors}}
    end
  end

  defp cadence_seconds(rule, profile) do
    # Match on a map rather than indexing straight into it. `nil["min_cadence_seconds"]`
    # is nil, not a raise, so a profile carrying no schedule used to reach the bounds
    # check with nil bounds and report `{:invalid_plugin_integration_cadence, nil, nil}`
    # -- which names the cadence as the problem when the schedule is what is missing.
    case profile["producer_schedule"] do
      %{} = schedule ->
        default = schedule["default_cadence_seconds"]
        value = RuleAccessors.metadata_int(rule, "cadence_seconds", default)
        minimum = schedule["min_cadence_seconds"]
        maximum = schedule["max_cadence_seconds"]

        if is_integer(value) and is_integer(minimum) and is_integer(maximum) and
             value >= minimum and value <= maximum do
          {:ok, value}
        else
          {:error, {:invalid_plugin_integration_cadence, minimum, maximum}}
        end

      _ ->
        {:error, {:missing_producer_schedule, profile["plugin_id"]}}
    end
  end

  defp schedule_enabled?(rule), do: RuleAccessors.metadata_bool(rule, "schedule_enabled", false)

  defp ensure_one_assignment_per_agent(assignments, agent_uid) do
    if Enum.count(assignments, &(to_string(&1.agent_uid) == agent_uid)) <= 1 do
      :ok
    else
      {:error, :duplicate_plugin_integration_policy_assignments}
    end
  end

  defp plugin_integration_rule?(rule, profiles_by_provider) do
    metadata = RuleAccessors.metadata(rule)
    Map.has_key?(profiles_by_provider, provider(rule)) or metadata["plugin_integration"] == true
  end

  # This provisioner only knows how to bind a package-owned producer schedule.
  # `IntegrationDescriptor` defines three provisioning modes -- "credential_only",
  # "producer_schedule" and "target_policy" -- and `IntegrationCatalog` attaches a
  # "producer_schedule" key to the third of those only. Reconciling either of the
  # other two through this path reached cadence validation with no schedule at all
  # and failed as `{:invalid_plugin_integration_cadence, nil, nil}`: a nil/nil
  # bound, because `nil["min_cadence_seconds"]` returns nil rather than raising.
  #
  # That is not a contained failure. The reduce below halts on the first error, so
  # one such rule stopped reconciliation for every other rule and the worker
  # discarded after max_attempts. On demo there is not a single producer_schedule
  # profile -- three target_policy (two proxmox, one camera) and one
  # credential_only (awx) -- so this worker could never complete a run.
  #
  # An allowlist, not a denylist. Rejecting only target_policy would still have let
  # credential_only through, and a fourth mode added later would silently break
  # this worker again. Anything this provisioner cannot provision is not its work.
  #
  # Skipped rather than routed to `disable_and_continue`: these rules are valid and
  # owned elsewhere -- target_policy by PluginTargetPolicyReconcileWorker,
  # credential_only by nothing at all (the rule exists purely to bind a secret).
  # Treating an unmatched profile as "revoked" would tear down working assignments.
  defp producer_schedule_rule?(rule, profiles_by_provider) do
    case Map.get(profiles_by_provider, provider(rule)) do
      %{} = profile -> provisioning_mode(profile) == "producer_schedule"
      _ -> false
    end
  end

  defp provisioning_mode(profile), do: get_in(profile, ["provisioning", "mode"])

  defp rule_enabled?(rule) do
    case ValueUtils.raw_value(rule, [:enabled, "enabled"]) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp provider(rule), do: RuleAccessors.value_string(rule, [:provider, "provider"])
  defp scope_type(rule), do: RuleAccessors.value_string(rule, [:scope_type, "scope_type"])

  defp scope_agent(rule) do
    case RuleAccessors.value_string(rule, [:scope_value, "scope_value"]) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp policy_id(rule),
    do: "network-credential-rule:#{required_value!(rule, :id)}:#{@policy_suffix}"

  defp source_key(rule, agent_uid),
    do: "plugin-credential-rule:#{required_value!(rule, :id)}:#{agent_uid}"

  defp assignment_matches?(assignment, attrs) do
    assignment.plugin_package_id == attrs.plugin_package_id and
      assignment.source == attrs.source and assignment.source_key == attrs.source_key and
      assignment.policy_id == attrs.policy_id and assignment.enabled == attrs.enabled and
      assignment.interval_seconds == attrs.interval_seconds and
      assignment.timeout_seconds == attrs.timeout_seconds and assignment.params == attrs.params
  end

  defp schedule_matches?(schedule, attrs) do
    schedule.enabled == attrs.enabled and schedule.schedule_type == attrs.schedule_type and
      schedule.cadence_seconds == attrs.cadence_seconds and
      schedule.plugin_assignment_id == attrs.plugin_assignment_id and
      schedule.params == attrs.params and schedule.credential_refs == attrs.credential_refs and
      schedule.metadata == attrs.metadata
  end

  defp required_value!(map, key) do
    case RuleAccessors.value_string(map, [key, to_string(key)]) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "missing required plugin integration identifier"
    end
  end

  defp bool_count(true), do: 1
  defp bool_count(false), do: 0

  defp empty_summary do
    %{
      rules: 0,
      assignments_written: 0,
      assignments_disabled: 0,
      schedules_bound: 0,
      schedules_disabled: 0
    }
  end

  defmodule AssignmentStore do
    @moduledoc false

    require Ash.Query

    def list_policy_assignments(policy_id, actor) do
      PluginAssignment
      |> Ash.Query.for_read(:all_partitions_for_policy, %{policy_id: policy_id}, actor: actor)
      |> Ash.read(actor: actor)
    end

    def create_assignment(attrs, actor) do
      PluginAssignment
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create(actor: actor)
    end

    def update_assignment(assignment, attrs, actor) do
      assignment
      |> Ash.Changeset.for_update(:update, attrs, actor: actor)
      |> Ash.update(actor: actor)
    end
  end

  defmodule ScheduleStore do
    @moduledoc false

    require Ash.Query

    def get_package_schedule(package_id, schedule_id, actor) do
      ProducerSchedule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(
        producer_kind == :wasm_plugin and plugin_package_id == ^package_id and
          schedule_id == ^schedule_id
      )
      |> Ash.read_one(actor: actor)
    end

    def list_assignment_schedules(assignment_id, actor) do
      ProducerSchedule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(plugin_assignment_id == ^assignment_id)
      |> Ash.read(actor: actor)
    end

    def update_schedule(schedule, attrs, actor) do
      schedule
      |> Ash.Changeset.for_update(:update, attrs, actor: actor)
      |> Ash.update(actor: actor)
    end
  end
end
