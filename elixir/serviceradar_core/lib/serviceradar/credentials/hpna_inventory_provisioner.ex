defmodule ServiceRadar.Credentials.HpnaInventoryProvisioner do
  @moduledoc """
  Reconciles the single HPNA credential rule into an action-only assignment and
  its package-owned producer schedule.

  Assignment and schedule params contain only public, validated HPNA settings.
  The schedule retains a credential reference; its dispatcher resolves that
  reference into fresh exact-endpoint grants immediately before each command.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.ProviderProfiles.HpnaProfile
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @policy_suffix "device_inventory"
  @minimum_cadence_seconds 3_600
  @maximum_cadence_seconds 2_592_000

  @type summary :: %{
          rules: non_neg_integer(),
          assignments_written: non_neg_integer(),
          assignments_disabled: non_neg_integer(),
          schedules_bound: non_neg_integer(),
          schedules_disabled: non_neg_integer()
        }

  @doc "Reconcile all persisted HPNA rules, allowing at most one enabled source."
  @spec reconcile_all(keyword()) :: {:ok, summary()} | {:error, term()}
  def reconcile_all(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:hpna_inventory_provisioner))

    with {:ok, rules} <- load_rules(actor, opts) do
      reconcile_rules(rules, Keyword.put(opts, :actor, actor))
    end
  end

  @doc false
  @spec reconcile_rules([map()], keyword()) :: {:ok, summary()} | {:error, term()}
  def reconcile_rules(rules, opts \\ []) when is_list(rules) do
    hpna_rules = Enum.filter(rules, &hpna_rule?/1)
    enabled_rules = Enum.filter(hpna_rules, &rule_enabled?/1)

    with :ok <- ensure_single_enabled_rule(enabled_rules),
         {:ok, disabled_summary} <- disable_inactive_rules(hpna_rules, opts) do
      case enabled_rules do
        [] -> {:ok, disabled_summary}
        [rule] -> reconcile_enabled_rule(rule, disabled_summary, opts)
      end
    end
  end

  @doc "Reconcile one enabled HPNA rule."
  @spec reconcile_rule(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_rule(rule, opts \\ []) when is_map(rule) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:hpna_inventory_provisioner))

    with :ok <- validate_rule(rule),
         {:ok, params} <- HpnaProfile.assignment_params(rule),
         :ok <- validate_cadence(HpnaProfile.cadence_seconds(rule)),
         {:ok, package} <- load_approved_package(actor, opts),
         {:ok, assignment, assignment_changed?} <-
           upsert_assignment(rule, package, params, actor, opts),
         {:ok, schedule, schedule_changed?} <-
           bind_schedule(rule, package, assignment, params, actor, opts) do
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

  defp reconcile_enabled_rule(rule, summary, opts) do
    case reconcile_rule(rule, opts) do
      {:ok, result} ->
        {:ok,
         %{
           summary
           | rules: 1,
             assignments_written:
               summary.assignments_written + bool_count(result.assignment_changed?),
             schedules_bound: summary.schedules_bound + bool_count(result.schedule_changed?)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_rules(actor, opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} when is_list(rules) ->
        {:ok, rules}

      {:ok, _invalid} ->
        {:error, :invalid_hpna_rules}

      :error ->
        NetworkCredentialRule
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(provider == "hpna")
        |> Ash.read(actor: actor)
    end
  end

  defp load_approved_package(actor, opts) do
    case Keyword.fetch(opts, :plugin_package) do
      {:ok, package} when is_map(package) ->
        {:ok, package}

      {:ok, _invalid} ->
        {:error, :invalid_hpna_plugin_package}

      :error ->
        PluginPackage
        |> Ash.Query.for_read(:approved, %{}, actor: actor)
        |> Ash.Query.filter(plugin_id == "hpna-inventory")
        |> Ash.read(actor: actor)
        |> case do
          {:ok, []} -> {:error, :hpna_plugin_package_not_found}
          {:ok, packages} -> {:ok, Enum.max_by(packages, &package_sort_key/1)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp upsert_assignment(rule, package, params, actor, opts) do
    store = Keyword.get(opts, :assignment_store, __MODULE__.AssignmentStore)
    agent_uid = scope_agent(rule)
    policy_id = policy_id(rule)

    attrs = %{
      agent_uid: agent_uid,
      plugin_package_id: value!(package, [:id, "id"]),
      source: :policy,
      source_key: source_key(rule, agent_uid),
      policy_id: policy_id,
      enabled: true,
      interval_seconds: 86_400,
      timeout_seconds: 900,
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

  defp bind_schedule(rule, package, assignment, params, actor, opts) do
    store = Keyword.get(opts, :schedule_store, __MODULE__.ScheduleStore)
    package_id = value!(package, [:id, "id"])

    with {:ok, schedule} <-
           store.get_package_schedule(package_id, HpnaProfile.schedule_id(), actor),
         false <- is_nil(schedule) do
      attrs = %{
        enabled: HpnaProfile.schedule_enabled?(rule),
        schedule_type: :interval,
        cadence_seconds: HpnaProfile.cadence_seconds(rule),
        plugin_assignment_id: assignment.id,
        params: params,
        credential_refs: %{
          "hpna_service_account" =>
            SecretRefs.network_credential_ref(value!(rule, [:secret_id, "secret_id"]))
        },
        metadata:
          (schedule.metadata || %{})
          |> Map.put("credential_rule_id", value!(rule, [:id, "id"]))
          |> Map.put("hpna_instance_id", params["instance_id"])
      }

      if schedule_matches?(schedule, attrs) do
        {:ok, schedule, false}
      else
        with {:ok, updated} <- store.update_schedule(schedule, attrs, actor) do
          {:ok, updated, true}
        end
      end
    else
      true -> {:error, :hpna_producer_schedule_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disable_inactive_rules(rules, opts) do
    rules
    |> Enum.reject(&rule_enabled?/1)
    |> Enum.reduce_while({:ok, empty_summary()}, fn rule, {:ok, summary} ->
      case disable_rule(rule, opts) do
        {:ok, %{assignments: assignments, schedules: schedules}} ->
          {:cont,
           {:ok,
            %{
              summary
              | assignments_disabled: summary.assignments_disabled + assignments,
                schedules_disabled: summary.schedules_disabled + schedules
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp disable_rule(rule, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:hpna_inventory_provisioner))
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

  defp validate_rule(rule) do
    cond do
      not hpna_rule?(rule) ->
        {:error, :invalid_hpna_provider}

      RuleAccessors.auth_method(rule) != "username_password" ->
        {:error, :invalid_hpna_auth_method}

      not HpnaProfile.rule_has_purpose?(rule, :device_inventory) ->
        {:error, :invalid_hpna_purpose}

      scope_type(rule) != "agent" ->
        {:error, :hpna_requires_agent_scope}

      is_nil(scope_agent(rule)) ->
        {:error, :hpna_requires_agent_scope}

      true ->
        :ok
    end
  end

  defp validate_cadence(value)
       when is_integer(value) and value >= @minimum_cadence_seconds and
              value <= @maximum_cadence_seconds, do: :ok

  defp validate_cadence(_value), do: {:error, :invalid_hpna_schedule_cadence}

  defp ensure_single_enabled_rule([]), do: :ok
  defp ensure_single_enabled_rule([_rule]), do: :ok

  defp ensure_single_enabled_rule(rules),
    do: {:error, {:multiple_enabled_hpna_credential_rules, length(rules)}}

  defp ensure_one_assignment_per_agent(assignments, agent_uid) do
    if Enum.count(assignments, &(to_string(&1.agent_uid) == agent_uid)) <= 1 do
      :ok
    else
      {:error, :duplicate_hpna_policy_assignments}
    end
  end

  defp hpna_rule?(rule), do: RuleAccessors.value_string(rule, [:provider, "provider"]) == "hpna"

  defp rule_enabled?(rule) do
    case ValueUtils.raw_value(rule, [:enabled, "enabled"]) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp scope_type(rule), do: RuleAccessors.value_string(rule, [:scope_type, "scope_type"])

  defp scope_agent(rule) do
    case RuleAccessors.value_string(rule, [:scope_value, "scope_value"]) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp policy_id(rule),
    do: "network-credential-rule:#{value!(rule, [:id, "id"])}:#{@policy_suffix}"

  defp source_key(rule, agent_uid),
    do: "hpna-credential-rule:#{value!(rule, [:id, "id"])}:#{agent_uid}"

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

  defp package_sort_key(package) do
    {semver(value(package, [:version, "version"])),
     timestamp(value(package, [:inserted_at, "inserted_at"]))}
  end

  defp semver(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)\.(\d+)\.(\d+)/, version) do
      [_match, major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch), version}

      _ ->
        {-1, -1, -1, version}
    end
  end

  defp semver(_version), do: {-1, -1, -1, ""}
  defp timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp timestamp(_value), do: 0

  defp value(map, keys), do: ValueUtils.raw_value(map, keys)

  defp value!(map, keys) do
    case RuleAccessors.value_string(map, keys) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "missing required HPNA provisioning identifier"
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
      |> Ash.Query.for_read(:by_policy, %{policy_id: policy_id}, actor: actor)
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
