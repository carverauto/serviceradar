defmodule ServiceRadar.Credentials.PluginIntegrationProvisioner do
  @moduledoc """
  Reconciles package-declared credential integrations into plugin assignments and
  package-owned producer schedules.

  Provider behavior comes from a validated signed manifest and JSON Schema. Stored
  assignments contain only public plugin configuration. Producer schedules retain a
  secret reference that the dispatcher resolves into short-lived endpoint-scoped
  grants immediately before each command.

  ## One rule, several schedules

  A profile's `provisioning` names its schedules with either `schedule_id` or
  `schedule_ids` (see `ServiceRadar.Plugins.IntegrationDescriptor.producer_schedule_ids/1`).
  A rule still materializes exactly one assignment per agent, and every listed
  schedule is bound to that same assignment with the same params and the same
  `credential_refs`. The dispatcher runs each schedule on its own and reads the
  agent and params through `plugin_assignment_id`, so a second assignment would
  only duplicate state the schedules already share.

  Cadence is per schedule. The rule's `cadence_seconds` overrides only the
  primary (first listed) schedule, which is the one the rule form bounds; every
  other schedule runs at its own `default_cadence_seconds`. A 15-minute inventory
  override applied to a 60-second telemetry poll would silently slow it by an
  order of magnitude, so the override is never broadcast. `schedule_enabled` is
  shared: a rule's schedules are armed and disarmed together.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.IntegrationDescriptor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
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

    {scheduled, unscheduled} =
      rules
      |> Enum.filter(&plugin_integration_rule?(&1, profiles_by_provider))
      |> Enum.split_with(&producer_schedule_rule?(&1, profiles_by_provider))

    # Revocation first. The scheduled pass halts on the first rule that fails
    # validation, and a rule nobody has fixed yet must not keep a revoked
    # package runnable.
    with {:ok, summary} <- disable_revoked_package_rules(unscheduled, empty_summary(), opts) do
      reconcile_scheduled_rules(scheduled, profiles_by_provider, summary, opts)
    end
  end

  def reconcile_rules(_rules, _profiles, _opts), do: {:error, :invalid_plugin_integration_rules}

  @doc "Reconcile one enabled package-declared credential integration rule."
  @spec reconcile_rule(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_rule(rule, profile, opts \\ [])

  def reconcile_rule(rule, profile, opts) when is_map(rule) and is_map(profile) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_provisioner))

    # Every listed schedule is planned and loaded before anything is written, so
    # a profile naming a schedule the package never materialized fails without
    # leaving the assignment half-bound to the schedules that do exist.
    with :ok <- validate_rule(rule, profile),
         {:ok, params} <- plugin_params(rule, profile),
         {:ok, plan} <- schedule_plan(rule, profile),
         {:ok, plan} <- load_planned_schedules(plan, profile, actor, opts),
         {:ok, assignment, assignment_changed?} <-
           upsert_assignment(rule, profile, params, actor, opts),
         {:ok, schedules_retired} <-
           retire_superseded_schedules(
             assignment,
             profile["plugin_package_id"],
             Enum.map(plan, & &1.schedule_id),
             actor,
             opts
           ),
         {:ok, schedules, schedules_changed} <-
           bind_schedules(rule, profile, assignment, params, plan, actor, opts) do
      {:ok,
       %{
         rule: rule,
         assignment: assignment,
         schedule: hd(schedules),
         schedules: schedules,
         assignment_changed?: assignment_changed?,
         schedule_changed?: schedules_changed > 0,
         schedules_changed: schedules_changed,
         schedules_retired: schedules_retired
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

  defp load_planned_schedules(plan, profile, actor, opts) do
    store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)
    package_id = profile["plugin_package_id"]

    plan
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case store.get_package_schedule(package_id, entry.schedule_id, actor) do
        {:ok, nil} ->
          {:halt,
           {:error, {:producer_schedule_not_found, profile["plugin_id"], entry.schedule_id}}}

        {:ok, schedule} ->
          {:cont, {:ok, [Map.put(entry, :schedule, schedule) | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_schedules(rule, profile, assignment, params, plan, actor, opts) do
    store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)

    plan
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, bound, changed} ->
      case bind_schedule(rule, profile, assignment, params, entry, actor, store) do
        {:ok, schedule, changed?} ->
          {:cont, {:ok, [schedule | bound], changed + bool_count(changed?)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bound, changed} -> {:ok, Enum.reverse(bound), changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_schedule(rule, profile, assignment, params, entry, actor, store) do
    %{schedule: schedule, cadence_seconds: cadence_seconds} = entry
    requirement = profile["provisioning"]["credential_requirement"]

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
  end

  # Every rule reaching this reduce has a producer_schedule profile, which is
  # what `producer_schedule_rule?/2` selected it for.
  defp reconcile_scheduled_rules(rules, profiles_by_provider, summary, opts) do
    Enum.reduce_while(rules, {:ok, summary}, fn rule, {:ok, summary} ->
      if rule_enabled?(rule) do
        profile = Map.fetch!(profiles_by_provider, provider(rule))

        case reconcile_rule(rule, profile, opts) do
          {:ok, result} ->
            {:cont,
             {:ok,
              %{
                summary
                | rules: summary.rules + 1,
                  assignments_written:
                    summary.assignments_written + bool_count(result.assignment_changed?),
                  schedules_bound: summary.schedules_bound + result.schedules_changed,
                  schedules_disabled:
                    summary.schedules_disabled + Map.get(result, :schedules_retired, 0)
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        disable_and_continue(rule, summary, opts)
      end
    end)
  end

  # A revoked package must not leave its previous assignment runnable.
  #
  # The integration catalog is built from approved packages only, so revoking a
  # producer-schedule package removes its profile and its rules arrive here, in
  # the set `producer_schedule_rule?/2` rejected. A missing profile cannot be the
  # signal: target_policy and credential_only rules land in the same set and
  # their assignments belong to other reconcilers. The package status is the
  # signal. Only assignments under this provisioner's own policy id are read,
  # which no other reconciler writes, and of those only the ones whose package
  # is no longer :approved are disabled, together with their schedules. An
  # approved package whose profile is merely absent keeps its assignment.
  defp disable_revoked_package_rules(rules, summary, opts) do
    Enum.reduce_while(rules, {:ok, summary}, fn rule, {:ok, summary} ->
      case disable_revoked_package_assignments(rule, opts) do
        {:ok, %{assignments: 0, schedules: 0}} -> {:cont, {:ok, summary}}
        {:ok, counts} -> {:cont, {:ok, add_disabled(summary, counts)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp disable_revoked_package_assignments(rule, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_provisioner))
    store = Keyword.get(opts, :assignment_store, __MODULE__.AssignmentStore)

    with {:ok, assignments} <- store.list_policy_assignments(policy_id(rule), actor),
         {:ok, revoked} <- revoked_package_assignments(assignments, actor, store) do
      disable_assignments(revoked, actor, opts)
    end
  end

  defp revoked_package_assignments([], _actor, _store), do: {:ok, []}

  defp revoked_package_assignments(assignments, actor, store) do
    package_ids = assignments |> Enum.map(&to_string(&1.plugin_package_id)) |> Enum.uniq()

    with {:ok, approved} <- store.approved_package_ids(package_ids, actor) do
      {:ok, Enum.reject(assignments, &MapSet.member?(approved, to_string(&1.plugin_package_id)))}
    end
  end

  defp disable_and_continue(rule, summary, opts) do
    case disable_rule(rule, opts) do
      {:ok, counts} -> {:cont, {:ok, add_disabled(summary, counts)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp add_disabled(summary, %{assignments: assignments, schedules: schedules}) do
    %{
      summary
      | rules: summary.rules + 1,
        assignments_disabled: summary.assignments_disabled + assignments,
        schedules_disabled: summary.schedules_disabled + schedules
    }
  end

  defp disable_rule(rule, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_provisioner))
    assignment_store = Keyword.get(opts, :assignment_store, __MODULE__.AssignmentStore)

    with {:ok, assignments} <- assignment_store.list_policy_assignments(policy_id(rule), actor) do
      disable_assignments(assignments, actor, opts)
    end
  end

  defp disable_assignments(assignments, actor, opts) do
    assignment_store = Keyword.get(opts, :assignment_store, __MODULE__.AssignmentStore)
    schedule_store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)

    initial = {:ok, %{assignments: 0, schedules: 0}}

    Enum.reduce_while(assignments, initial, fn assignment, {:ok, counts} ->
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

  defp disable_assignment(%{enabled: false}, _actor, _store), do: {:ok, 0}

  defp disable_assignment(assignment, actor, store) do
    case store.update_assignment(assignment, %{enabled: false}, actor) do
      {:ok, _updated} -> {:ok, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  # An upgrade repoints the assignment at the successor package and binds that
  # package's schedules. Schedules still armed for an earlier package stay bound
  # to the same assignment, and the dispatcher would run the old contract
  # against the new assignment. Disarm every enabled schedule on this assignment
  # whose package is not the one being bound, before the successor is armed.
  #
  # The same holds inside the bound package for a schedule the profile no longer
  # lists: it keeps pointing at this assignment and would keep running on the
  # rule's credential. A successor version that drops an id from schedule_ids
  # is caught by the package check; the listed-id check covers a profile whose
  # list shrinks without the package id changing.
  defp retire_superseded_schedules(_assignment, package_id, _bound_ids, _actor, _opts)
       when package_id in [nil, ""],
       do: {:ok, 0}

  defp retire_superseded_schedules(assignment, package_id, bound_ids, actor, opts) do
    store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)
    package_id = to_string(package_id)

    with {:ok, schedules} <- store.list_assignment_schedules(assignment.id, actor) do
      Enum.reduce_while(schedules, {:ok, 0}, fn schedule, {:ok, count} ->
        if superseded_schedule?(schedule, package_id, bound_ids) do
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

  defp superseded_schedule?(%{enabled: true} = schedule, package_id, bound_ids) do
    case schedule_package_id(schedule) do
      nil -> false
      ^package_id -> unlisted_schedule?(schedule, bound_ids)
      _other_package -> true
    end
  end

  defp superseded_schedule?(_schedule, _package_id, _bound_ids), do: false

  defp unlisted_schedule?(schedule, bound_ids) do
    case Map.get(schedule, :schedule_id) do
      schedule_id when is_binary(schedule_id) -> schedule_id not in bound_ids
      _ -> false
    end
  end

  defp schedule_package_id(schedule) do
    case Map.get(schedule, :plugin_package_id) do
      nil -> nil
      "" -> nil
      id -> to_string(id)
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

  # One entry per listed schedule, primary first. The primary takes the rule's
  # cadence override within its own bounds; every other schedule takes its own
  # package default, checked against its own bounds.
  defp schedule_plan(rule, profile) do
    # Match on a map rather than indexing straight into it. `nil["min_cadence_seconds"]`
    # is nil, not a raise, so a profile carrying no schedule used to reach the bounds
    # check with nil bounds and report `{:invalid_plugin_integration_cadence, nil, nil}`
    # -- which names the cadence as the problem when the schedule is what is missing.
    case {profile["producer_schedule"], producer_schedule_ids(profile)} do
      {%{}, []} ->
        {:error, {:producer_schedule_not_found, profile["plugin_id"], nil}}

      {%{} = primary, [primary_id | secondary_ids]} ->
        with {:ok, primary_cadence} <- primary_cadence_seconds(rule, primary),
             {:ok, secondaries} <- secondary_plan(profile, secondary_ids) do
          {:ok, [%{schedule_id: primary_id, cadence_seconds: primary_cadence} | secondaries]}
        end

      _ ->
        {:error, {:missing_producer_schedule, profile["plugin_id"]}}
    end
  end

  defp producer_schedule_ids(profile),
    do: IntegrationDescriptor.producer_schedule_ids(profile["provisioning"])

  defp primary_cadence_seconds(rule, schedule) do
    default = schedule["default_cadence_seconds"]
    value = RuleAccessors.metadata_int(rule, "cadence_seconds", default)
    minimum = schedule["min_cadence_seconds"]
    maximum = schedule["max_cadence_seconds"]

    if within_bounds?(value, minimum, maximum) do
      {:ok, value}
    else
      {:error, {:invalid_plugin_integration_cadence, minimum, maximum}}
    end
  end

  defp secondary_plan(profile, schedule_ids) do
    schedule_ids
    |> Enum.reduce_while({:ok, []}, fn schedule_id, {:ok, acc} ->
      case secondary_plan_entry(profile, schedule_id) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secondary_plan_entry(profile, schedule_id) do
    schedule =
      profile
      |> Map.get("producer_schedules")
      |> List.wrap()
      |> Enum.find(&(is_map(&1) and &1["schedule_id"] == schedule_id))

    case schedule do
      %{} ->
        value = schedule["default_cadence_seconds"]
        minimum = schedule["min_cadence_seconds"]
        maximum = schedule["max_cadence_seconds"]

        if within_bounds?(value, minimum, maximum) do
          {:ok, %{schedule_id: schedule_id, cadence_seconds: value}}
        else
          {:error, {:invalid_plugin_integration_cadence, schedule_id, minimum, maximum}}
        end

      nil ->
        {:error, {:missing_producer_schedule, profile["plugin_id"], schedule_id}}
    end
  end

  defp within_bounds?(value, minimum, maximum) do
    is_integer(value) and is_integer(minimum) and is_integer(maximum) and value >= minimum and
      value <= maximum
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
  # owned elsewhere -- target_policy by PluginCredentialRuleReconcileWorker (which
  # drives PluginAssignmentMaterializer), credential_only by nothing at all (the
  # rule exists purely to bind a secret).
  # Treating an unmatched profile as "revoked" would tear down working assignments.
  # Rejected rules still go through `disable_revoked_package_rules/3`, which acts
  # on the package status of this provisioner's own assignments, never on the
  # missing profile.
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

    def approved_package_ids(package_ids, actor) do
      PluginPackage
      |> Ash.Query.for_read(:approved, %{}, actor: actor)
      |> Ash.Query.filter(id in ^package_ids)
      |> Ash.Query.select([:id])
      |> Ash.read(actor: actor)
      |> case do
        {:ok, packages} -> {:ok, MapSet.new(packages, &to_string(&1.id))}
        {:error, reason} -> {:error, reason}
      end
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
