defmodule ServiceRadar.Infrastructure.AgentSupersession do
  @moduledoc """
  Replaces an agent identity when a host checks in under a new uid.

  Two rows are the same host only when they share a `device_uid`. A shared
  address or hostname is not identity: hosts behind one NAT address stay
  independent. An identity that is still heartbeating (connected or degraded,
  and seen within the StateMonitor agent timeout) is left in place.

  Every supersession path marks the replaced row `:superseded`, cancels its
  non-terminal release targets, sets its `release_rollout_state` to `:canceled`,
  and transfers its `SweepGroup`, `MapperJob`, agent-scoped
  `NetworkCredentialRule`, enabled manual `PluginAssignment`,
  `Camera.Source`, `SNMPProfile`, `IntegrationSource`, and `ServiceCheck`
  assignments to the replacement:

  - `on_check_in/3` runs at enrollment/check-in and supersedes quiet siblings
    immediately while keeping live ones.
  - `on_agent_disconnected/2` runs when `StateMonitor` times out an agent to
    `:disconnected` and supersedes it immediately if a live sibling exists on
    the same device.
  - `sweep/1` runs hourly as backfill for quiet siblings on a shared device and
    reconciles any lingering assignments or active release targets left on
    already-superseded identities (including across multi-hop chains).
  """

  import Ash.Expr

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.StateMonitor
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SweepJobs.AgentAssignment
  alias ServiceRadar.SweepJobs.SweepGroup

  require Ash.Query
  require Logger

  @sweep_page 500
  @source "agent_supersession"
  @terminal_release_target_statuses [:healthy, :failed, :rolled_back, :canceled]

  @type sweep_result :: %{superseded: non_neg_integer()}

  @doc """
  Supersedes quiet identities that share a device with a more recently seen
  identity. The most recently seen identity is the keeper, even when it too has
  gone quiet. Running it again supersedes nothing.

  Also reconciles any lingering assignments or active release targets left on
  identities that were previously marked `:superseded`.
  """
  @spec sweep(keyword()) :: {:ok, sweep_result()} | {:error, term()}
  def sweep(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:agent_supersession))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, agents} <- load_active_agents(actor) do
      superseded =
        agents
        |> Enum.group_by(& &1.device_uid)
        |> Enum.reduce(0, fn {_device_uid, group}, count ->
          count + supersede_quiet_siblings(group, actor, now)
        end)

      reconcile_superseded_assignments(actor)

      {:ok, %{superseded: superseded}}
    end
  end

  @doc """
  On check-in of `agent_id` onto `device_uid`, supersede every other identity
  on that device that is no longer live. Live identities are kept and the
  decision is recorded either way.

  Returns the agents that were superseded. Assignment handoff and release-target
  cancellation run for each superseded agent as part of marking it superseded.
  A failed read or update is logged and does not fail the check-in.
  """
  @spec on_check_in(String.t(), String.t() | nil, map()) :: [Agent.t()]
  def on_check_in(agent_id, device_uid, actor)
      when is_binary(agent_id) and is_binary(device_uid) do
    now = DateTime.utc_now()

    case siblings(device_uid, agent_id, actor) do
      {:ok, agents} ->
        Enum.flat_map(agents, &decide_sibling(&1, agent_id, device_uid, actor, now))

      {:error, reason} ->
        Logger.warning(
          "Failed to look up sibling agents for #{agent_id} on #{device_uid}: #{inspect(reason)}"
        )

        []
    end
  end

  def on_check_in(_agent_id, _device_uid, _actor), do: []

  @doc """
  Called when an agent transitions to `:disconnected` (e.g. heartbeat timeout).

  If another identity on the same `device_uid` is currently live, supersede the
  disconnected identity immediately and hand off its active assignments instead
  of waiting for the hourly `sweep/1` pass.
  """
  @spec on_agent_disconnected(Agent.t(), map()) :: {:ok, Agent.t()} | :noop
  def on_agent_disconnected(
        %Agent{uid: uid, device_uid: device_uid, superseded_at: nil} = agent,
        actor
      )
      when is_binary(device_uid) do
    now = DateTime.utc_now()

    case siblings(device_uid, uid, actor) do
      {:ok, sibling_agents} ->
        case Enum.filter(sibling_agents, &live?(&1, now)) do
          [] ->
            :noop

          live_siblings ->
            replacement = keeper(live_siblings)

            case mark_superseded(agent, replacement.uid, actor, "older_identity_on_device") do
              {:ok, updated} -> {:ok, updated}
              :error -> :noop
            end
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to look up sibling agents for disconnected agent #{uid} on #{device_uid}: #{inspect(reason)}"
        )

        :noop
    end
  end

  def on_agent_disconnected(_agent, _actor), do: :noop

  @doc """
  Returns a superseded identity to `:connected` and records the revival.

  This is the only path that leaves `:superseded`. The connected-registration
  upsert refuses a superseded row.
  """
  @spec revive(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, term()}
  def revive(%Agent{status: :superseded} = agent, actor) do
    case agent
         |> Ash.Changeset.for_update(:revive_superseded, %{})
         |> Ash.update(actor: actor) do
      {:ok, revived} ->
        record(revived.device_uid, revived.uid, "superseded_agent_reconnected", %{})
        {:ok, revived}

      {:error, reason} = error ->
        Logger.warning("Failed to revive superseded agent #{agent.uid}: #{inspect(reason)}")
        error
    end
  end

  def revive(%Agent{} = agent, _actor), do: {:ok, agent}

  defp decide_sibling(agent, replacement_uid, device_uid, actor, now) do
    if live?(agent, now) do
      record(device_uid, agent.uid, "live_identity_kept", %{replacement_uid: replacement_uid})
      []
    else
      case mark_superseded(agent, replacement_uid, actor, "reenrolled_under_new_uid") do
        {:ok, updated} -> [updated]
        :error -> []
      end
    end
  end

  defp supersede_quiet_siblings(group, _actor, _now) when length(group) < 2, do: 0

  defp supersede_quiet_siblings(group, actor, now) do
    keeper = keeper(group)

    Enum.reduce(group, 0, fn agent, count ->
      if agent.uid == keeper.uid or live?(agent, now) do
        count
      else
        case mark_superseded(agent, keeper.uid, actor, "older_identity_on_device") do
          {:ok, _updated} -> count + 1
          :error -> count
        end
      end
    end)
  end

  defp mark_superseded(agent, replacement_uid, actor, reason) do
    case agent
         |> Ash.Changeset.for_update(:supersede, %{superseded_by: replacement_uid})
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        record(agent.device_uid, agent.uid, reason, %{superseded_by: replacement_uid})
        finish_superseded_agent(updated, replacement_uid, actor)
        {:ok, updated}

      {:error, error} ->
        Logger.warning(
          "Failed to supersede agent #{agent.uid} in favor of #{replacement_uid}: #{inspect(error)}"
        )

        :error
    end
  end

  defp finish_superseded_agent(agent, replacement_agent_id, actor) do
    cancel_superseded_release_targets(agent.uid, replacement_agent_id, actor)
    mark_superseded_release_state(agent, actor)
    transfer_superseded_assignments(agent.uid, replacement_agent_id, actor)

    Logger.info("Superseded agent #{agent.uid} in favor of #{replacement_agent_id}")
  end

  defp reconcile_superseded_assignments(actor) do
    snapshot = %{
      release_targets: load_active_release_targets(actor),
      mapper_jobs: load_field_assigned_records(MapperJob, :agent_id, "mapper jobs", actor),
      sweep_groups: load_list_assigned_records(SweepGroup, "sweep groups", actor),
      credential_rules: load_agent_credential_rules(actor),
      plugin_assignments: load_enabled_manual_plugin_assignments(actor),
      camera_sources:
        load_field_assigned_records(CameraSource, :assigned_agent_id, "camera sources", actor),
      snmp_profiles: load_list_assigned_records(SNMPProfile, "snmp profiles", actor),
      integration_sources:
        load_field_assigned_records(IntegrationSource, :agent_id, "integration sources", actor),
      service_checks:
        load_field_assigned_records(ServiceCheck, :agent_uid, "service checks", actor)
    }

    referenced_uids = collect_referenced_agent_ids(snapshot)

    with [_ | _] <- referenced_uids,
         {:ok, superseded_by_map} when map_size(superseded_by_map) > 0 <-
           load_superseded_map(referenced_uids, actor) do
      reconcile_release_targets(snapshot.release_targets, superseded_by_map, actor)

      reconcile_grouped_records(
        snapshot.mapper_jobs,
        & &1.agent_id,
        superseded_by_map,
        :mapper_jobs,
        &update_field_assignments(&1, :agent_id, &2, actor, label: "mapper job")
      )

      reconcile_list_assignments(
        snapshot.sweep_groups,
        superseded_by_map,
        :sweep_groups,
        "sweep group",
        actor
      )

      reconcile_grouped_records(
        snapshot.credential_rules,
        & &1.scope_value,
        superseded_by_map,
        :network_credential_rules,
        &update_field_assignments(&1, :scope_value, &2, actor, label: "credential rule")
      )

      reconcile_grouped_records(
        snapshot.plugin_assignments,
        & &1.agent_uid,
        superseded_by_map,
        :plugin_assignments,
        &update_field_assignments(&1, :agent_uid, &2, actor,
          action: :reassign_agent,
          label: "plugin assignment"
        )
      )

      reconcile_grouped_records(
        snapshot.camera_sources,
        & &1.assigned_agent_id,
        superseded_by_map,
        :camera_sources,
        &update_field_assignments(&1, :assigned_agent_id, &2, actor, label: "camera source")
      )

      reconcile_list_assignments(
        snapshot.snmp_profiles,
        superseded_by_map,
        :snmp_profiles,
        "snmp profile",
        actor
      )

      reconcile_grouped_records(
        snapshot.integration_sources,
        & &1.agent_id,
        superseded_by_map,
        :integration_sources,
        &update_field_assignments(&1, :agent_id, &2, actor,
          action: :reassign_agent,
          label: "integration source"
        )
      )

      reconcile_grouped_records(
        snapshot.service_checks,
        & &1.agent_uid,
        superseded_by_map,
        :service_checks,
        &update_field_assignments(&1, :agent_uid, &2, actor, label: "service check")
      )

      :ok
    else
      [] ->
        :ok

      {:ok, _empty} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to load superseded agents for assignment reconciliation: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp load_active_release_targets(actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(status not in ^@terminal_release_target_statuses))
    |> read_reconciliation_records("active release targets", actor)
  end

  defp load_field_assigned_records(resource, field, label, actor) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(not is_nil(^ref(field)) and ^ref(field) != ""))
    |> read_reconciliation_records(label, actor)
  end

  defp load_list_assigned_records(resource, label, actor) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(agent_ids != []))
    |> read_reconciliation_records(label, actor)
  end

  defp load_agent_credential_rules(actor) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(scope_type == :agent and scope_value != ""))
    |> read_reconciliation_records("credential rules", actor)
  end

  defp load_enabled_manual_plugin_assignments(actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(source == :manual and enabled == true and partition_id != "" and agent_uid != "")
    )
    |> read_reconciliation_records("manual plugin assignments", actor)
  end

  defp read_reconciliation_records(query, label, actor) do
    case Ash.read(query, actor: actor) do
      {:ok, records} ->
        records

      {:error, reason} ->
        Logger.warning(
          "Failed to load #{label} for supersession reconciliation: #{inspect(reason)}"
        )

        []
    end
  end

  defp collect_referenced_agent_ids(snapshot) do
    [
      Enum.map(snapshot.release_targets, & &1.agent_id),
      Enum.map(snapshot.mapper_jobs, & &1.agent_id),
      Enum.flat_map(snapshot.sweep_groups, &AgentAssignment.normalize(&1.agent_ids)),
      Enum.map(snapshot.credential_rules, & &1.scope_value),
      Enum.map(snapshot.plugin_assignments, & &1.agent_uid),
      Enum.map(snapshot.camera_sources, & &1.assigned_agent_id),
      Enum.flat_map(snapshot.snmp_profiles, &AgentAssignment.normalize(&1.agent_ids)),
      Enum.map(snapshot.integration_sources, & &1.agent_id),
      Enum.map(snapshot.service_checks, & &1.agent_uid)
    ]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp load_superseded_map(uids, actor) do
    load_superseded_frontier(uids, MapSet.new(), %{}, actor)
  end

  defp load_superseded_frontier([], _queried, superseded_by_map, _actor),
    do: {:ok, superseded_by_map}

  defp load_superseded_frontier(uids, queried, superseded_by_map, actor) do
    case Enum.reject(uids, &MapSet.member?(queried, &1)) do
      [] ->
        {:ok, superseded_by_map}

      pending ->
        advance_superseded_frontier(pending, queried, superseded_by_map, actor)
    end
  end

  defp advance_superseded_frontier(pending, queried, superseded_by_map, actor) do
    case read_superseded_agents_by_uids(pending, actor) do
      {:ok, agents} ->
        next_queried = MapSet.union(queried, MapSet.new(pending))
        next_map = Map.merge(superseded_by_map, Map.new(agents, &{&1.uid, &1.superseded_by}))

        next_uids =
          agents
          |> Enum.map(& &1.superseded_by)
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()

        load_superseded_frontier(next_uids, next_queried, next_map, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_superseded_agents_by_uids(uids, actor) do
    uids
    |> Enum.chunk_every(@sweep_page)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case read_superseded_agent_batch(batch, actor) do
        {:ok, results} -> {:cont, {:ok, results ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_superseded_agent_batch(batch, actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(uid in ^batch and status == :superseded and not is_nil(superseded_by))
    )
    |> Ash.Query.select([:uid, :superseded_by])
    |> Ash.read(actor: actor, page: false)
  end

  defp reconcile_release_targets(targets, superseded_by_map, actor) do
    Enum.each(targets, fn target ->
      case replacement_for_superseded(target.agent_id, superseded_by_map) do
        {:ok, replacement_uid} -> cancel_release_target(target, replacement_uid, actor)
        :noop -> :ok
      end
    end)
  end

  defp reconcile_list_assignments(records, superseded_by_map, label, item_label, actor) do
    Enum.each(
      records,
      &reconcile_list_assignment(&1, superseded_by_map, label, item_label, actor)
    )
  end

  defp reconcile_list_assignment(record, superseded_by_map, label, item_label, actor) do
    current_agent_ids = AgentAssignment.normalize(record.agent_ids)

    updated_agent_ids =
      current_agent_ids
      |> Enum.map(&replace_if_superseded(&1, superseded_by_map))
      |> AgentAssignment.normalize()

    if updated_agent_ids != current_agent_ids do
      case update_list_assignments([{record, updated_agent_ids}], item_label, actor) do
        {:ok, count} when count > 0 ->
          Logger.info(
            "Reassigned #{count} #{label} for superseded agents in #{item_label} #{record.id}"
          )

        {:ok, 0} ->
          :ok
      end
    end
  end

  defp reconcile_grouped_records(records, uid_fun, superseded_by_map, label, update_fun) do
    records
    |> Enum.reduce(%{}, fn record, acc ->
      agent_id = uid_fun.(record)

      case replacement_for_superseded(agent_id, superseded_by_map) do
        {:ok, replacement_uid} ->
          Map.update(acc, {agent_id, replacement_uid}, [record], &[record | &1])

        :noop ->
          acc
      end
    end)
    |> Enum.each(fn {{agent_id, replacement_uid}, grouped_records} ->
      result = update_fun.(grouped_records, replacement_uid)
      log_assignment_transfer({label, result}, agent_id, replacement_uid)
    end)
  end

  defp replace_if_superseded(agent_id, superseded_by_map) do
    case replacement_for_superseded(agent_id, superseded_by_map) do
      {:ok, replacement_uid} -> replacement_uid
      :noop -> agent_id
    end
  end

  defp replacement_for_superseded(agent_id, superseded_by_map) do
    if Map.has_key?(superseded_by_map, agent_id) do
      case resolve_replacement_uid(agent_id, superseded_by_map) do
        replacement_uid when is_binary(replacement_uid) and replacement_uid != agent_id ->
          {:ok, replacement_uid}

        _ ->
          :noop
      end
    else
      :noop
    end
  end

  defp resolve_replacement_uid(uid, superseded_by_map),
    do: resolve_replacement_uid(uid, superseded_by_map, MapSet.new([uid]))

  defp resolve_replacement_uid(uid, superseded_by_map, visited) do
    case Map.get(superseded_by_map, uid) do
      next when is_binary(next) and next != "" ->
        if MapSet.member?(visited, next) do
          nil
        else
          resolve_replacement_uid(next, superseded_by_map, MapSet.put(visited, next))
        end

      _ ->
        uid
    end
  end

  defp mark_superseded_release_state(agent, actor) do
    _ =
      agent
      |> Ash.Changeset.for_update(:update_release_status, %{
        release_rollout_state: :canceled,
        last_update_at: DateTime.utc_now(),
        last_update_error: "agent_superseded"
      })
      |> Ash.update(actor: actor)

    :ok
  end

  defp cancel_superseded_release_targets(agent_id, replacement_agent_id, actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(agent_id == ^agent_id and status not in ^@terminal_release_target_statuses)
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, targets} ->
        Enum.each(targets, &cancel_release_target(&1, replacement_agent_id, actor))

      {:error, reason} ->
        Logger.warning(
          "Failed to cancel release targets for superseded agent #{agent_id}: #{inspect(reason)}"
        )
    end
  end

  defp cancel_release_target(target, replacement_agent_id, actor) do
    _ =
      AgentReleaseTarget.set_status(
        target,
        %{
          status: :canceled,
          last_status_message: "superseded by #{replacement_agent_id}",
          last_error: "agent_superseded",
          completed_at: DateTime.utc_now()
        },
        actor: actor
      )

    :ok
  end

  defp transfer_superseded_assignments(agent_id, replacement_agent_id, actor) do
    Enum.each(
      [
        {:mapper_jobs,
         transfer_field_assignments(
           MapperJob,
           :agent_id,
           agent_id,
           replacement_agent_id,
           actor,
           label: "mapper job"
         )},
        {:sweep_groups,
         transfer_list_assignments(
           SweepGroup,
           "sweep group",
           agent_id,
           replacement_agent_id,
           actor
         )},
        {:network_credential_rules,
         transfer_credential_rules(agent_id, replacement_agent_id, actor)},
        {:plugin_assignments, transfer_plugin_assignments(agent_id, replacement_agent_id, actor)},
        {:camera_sources,
         transfer_field_assignments(
           CameraSource,
           :assigned_agent_id,
           agent_id,
           replacement_agent_id,
           actor,
           label: "camera source"
         )},
        {:snmp_profiles,
         transfer_list_assignments(
           SNMPProfile,
           "snmp profile",
           agent_id,
           replacement_agent_id,
           actor
         )},
        {:integration_sources,
         transfer_field_assignments(
           IntegrationSource,
           :agent_id,
           agent_id,
           replacement_agent_id,
           actor,
           action: :reassign_agent,
           label: "integration source"
         )},
        {:service_checks,
         transfer_field_assignments(
           ServiceCheck,
           :agent_uid,
           agent_id,
           replacement_agent_id,
           actor,
           label: "service check"
         )}
      ],
      &log_assignment_transfer(&1, agent_id, replacement_agent_id)
    )
  end

  defp log_assignment_transfer({_label, {:ok, 0}}, _agent_id, _replacement_agent_id), do: :ok

  defp log_assignment_transfer({label, {:ok, count}}, agent_id, replacement_agent_id) do
    Logger.info(
      "Reassigned #{count} #{label} from superseded agent #{agent_id} to #{replacement_agent_id}"
    )
  end

  defp log_assignment_transfer({label, {:error, reason}}, agent_id, replacement_agent_id) do
    Logger.warning(
      "Failed to reassign #{label} from superseded agent #{agent_id} to #{replacement_agent_id}: #{inspect(reason)}"
    )
  end

  defp transfer_field_assignments(resource, field, agent_id, replacement_agent_id, actor, opts) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(^ref(field) == ^agent_id))

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, records} ->
        update_field_assignments(records, field, replacement_agent_id, actor, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transfer_list_assignments(resource, item_label, agent_id, replacement_agent_id, actor) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(^agent_id in agent_ids)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, records} ->
        records
        |> Enum.map(&replace_list_agent_assignment(&1, agent_id, replacement_agent_id))
        |> update_list_assignments(item_label, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_list_agent_assignment(record, agent_id, replacement_agent_id) do
    agent_ids =
      record.agent_ids
      |> AgentAssignment.normalize()
      |> Enum.map(fn current_agent_id ->
        if current_agent_id == agent_id, do: replacement_agent_id, else: current_agent_id
      end)
      |> AgentAssignment.normalize()

    {record, agent_ids}
  end

  defp update_list_assignments(assignments, item_label, actor) do
    count =
      Enum.reduce(assignments, 0, fn {record, agent_ids}, acc ->
        record
        |> Ash.Changeset.for_update(:update, %{agent_ids: agent_ids}, actor: actor)
        |> Ash.update()
        |> case do
          {:ok, _record} ->
            acc + 1

          {:error, reason} ->
            Logger.warning(
              "Failed to reassign #{item_label} #{record.id} to #{inspect(agent_ids)}: #{inspect(reason)}"
            )

            acc
        end
      end)

    {:ok, count}
  end

  defp transfer_credential_rules(agent_id, replacement_agent_id, actor) do
    query =
      NetworkCredentialRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(scope_type == :agent and scope_value == ^agent_id))

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, rules} ->
        update_field_assignments(rules, :scope_value, replacement_agent_id, actor,
          label: "credential rule"
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transfer_plugin_assignments(agent_id, replacement_agent_id, actor) do
    query =
      PluginAssignment
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(
        expr(
          agent_uid == ^agent_id and source == :manual and enabled == true and partition_id != ""
        )
      )

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, assignments} ->
        update_field_assignments(assignments, :agent_uid, replacement_agent_id, actor,
          action: :reassign_agent,
          label: "plugin assignment"
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_field_assignments(records, field, replacement_agent_id, actor, opts) do
    action = Keyword.get(opts, :action, :update)
    label = Keyword.fetch!(opts, :label)

    update_records_best_effort(records, label, replacement_agent_id, fn record ->
      record
      |> Ash.Changeset.for_update(action, %{field => replacement_agent_id}, actor: actor)
      |> Ash.update()
    end)
  end

  defp update_records_best_effort(records, label, replacement_agent_id, update_fun) do
    count =
      Enum.reduce(records, 0, fn record, acc ->
        case update_fun.(record) do
          {:ok, _updated} ->
            acc + 1

          {:error, reason} ->
            Logger.warning(
              "Failed to reassign #{label} #{record.id} to #{replacement_agent_id}: #{inspect(reason)}"
            )

            acc
        end
      end)

    {:ok, count}
  end

  # Connected or degraded and seen inside the StateMonitor window. A nil
  # last_seen is not a heartbeat. Anything else (unavailable, disconnected,
  # connecting) has already left the live set.
  defp live?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen}, now)
       when status in [:connected, :degraded] do
    DateTime.diff(now, last_seen, :millisecond) <= StateMonitor.agent_timeout()
  end

  defp live?(%Agent{}, _now), do: false

  # Nil last_seen sorts oldest. Equal timestamps break toward the higher uid so
  # a repeated sweep picks the same keeper.
  defp keeper(agents) do
    Enum.max_by(agents, fn agent -> {seen_sort_key(agent.last_seen_time), agent.uid} end)
  end

  defp seen_sort_key(nil), do: {0, 0}
  defp seen_sort_key(%DateTime{} = time), do: {1, DateTime.to_unix(time, :microsecond)}

  defp siblings(device_uid, agent_id, actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(device_uid == ^device_uid and uid != ^agent_id and is_nil(superseded_at))
    )
    |> Ash.read(actor: actor)
  end

  defp load_active_agents(actor), do: load_active_agents(actor, nil, [])

  defp load_active_agents(actor, after_uid, acc) do
    case Ash.read(active_agent_query(actor, after_uid), actor: actor) do
      {:ok, %Keyset{results: results}} ->
        continue_active_agents(actor, results, acc)

      {:ok, results} when is_list(results) ->
        continue_active_agents(actor, results, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_active_agents(_actor, [], acc), do: {:ok, acc}

  defp continue_active_agents(actor, results, acc) do
    acc = acc ++ results

    if length(results) < @sweep_page do
      {:ok, acc}
    else
      load_active_agents(actor, List.last(results).uid, acc)
    end
  end

  defp active_agent_query(actor, after_uid) do
    query =
      Agent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(not is_nil(device_uid) and is_nil(superseded_at)))
      |> Ash.Query.sort(uid: :asc)
      |> Ash.Query.limit(@sweep_page)

    if is_binary(after_uid) do
      Ash.Query.filter(query, expr(uid > ^after_uid))
    else
      query
    end
  end

  defp record(device_uid, agent_uid, reason, evidence) when is_binary(device_uid) do
    DecisionLog.record(:agent_supersession, reason, [device_uid],
      subject: agent_uid,
      source: @source,
      evidence: evidence
    )
  end

  defp record(_device_uid, _agent_uid, _reason, _evidence), do: :ok
end
