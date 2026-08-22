defmodule ServiceRadar.Inventory.Remediation.AgentLinks do
  @moduledoc """
  Step `agent-links` (OpenSpec refactor-device-identity-reconciliation 4.3).

  Repairs the worker-agent chimera and related agent->device mislinks. The
  EXPECTED mapping is derived at runtime from `ocsf_agents` ground truth
  (`agent uid -> host -> ip`), never from hardcoded device ids, so the step
  is correct even after the live state drifts.

  For every in-scope agent (default: `connected`):

  1. Decide whether its `device_uid` is right: the device must be live and
     carry the agent's expected hostname; when several agents share one
     device (the chimera), only the hostname-matching agent keeps it.
  2. Mislinked agents are repointed at a per-host device found in this
     order: a live device already carrying `agent_id == agent.uid` and the
     expected hostname (adopt), the most recent tombstoned device with the
     expected hostname and matching/absent `agent_id` (restore — merge-away
     tombstones carry an audit trail; restoring a live row is respected by
     `IdentityReconciler.follow_canonical_device_id/2`), else a freshly
     created device. Explicit reconstruction from agent ground truth is
     preferred over blind `IdentityReconciler.unmerge_device/2` because the
     chimera's audit trail resurrects merged-away ids wholesale.
  3. Every relocation writes a `merge_audit` row (reason `"unmerge"`, source
     `"dire_remediation"`) — this both documents the split and arms the
     per-pair merge cooldown against an immediate re-collapse.
  4. The `agent_id` device identifier is repointed (audited
     `:reassign_device`) or registered onto the agent's device — this also
     fixes identifiers stranded on unrelated devices (the k8s-agent-on-FAKER
     pathology) even when the device link itself was correct.
  5. The denormalized `ocsf_devices.agent_id` ownership is made one-to-one:
     the target row carries the agent id and every other live row is cleared.
  6. Active `device_alias_states` rows that claim the agent's IP for a
     DIFFERENT device are marked stale (poisoned alias cleanup).
  7. Devices whose `ip` equals the corruption literal (default `"agent"`)
     get `ip = NULL`.
  """

  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "agent-links"
  @default_statuses [:connected]
  @active_alias_states [:detected, :confirmed, :updated]
  # A real host carries identity for one machine. Beyond this many MAC
  # identifiers the row is a faker/merge chimera, not a single host.
  @max_plausible_host_macs 32

  @doc false
  def run(mode, opts, manifest, actor) do
    agents = scoped_agents(opts, actor)
    plans = build_plans(agents, actor)
    ip_literal = Keyword.get(opts, :ip_literal, "agent")
    ip_literal_uids = devices_with_ip_literal(ip_literal)

    report = %{
      agents_checked: length(agents),
      plans: Enum.map(plans, &describe_plan/1),
      keep: count_actions(plans, :keep),
      adopt: count_actions(plans, :adopt),
      restore: count_actions(plans, :restore),
      create: count_actions(plans, :create),
      skipped: count_actions(plans, :skip),
      identifier_moves: Enum.sum(Enum.map(plans, &length(&1.identifier_move_ids))),
      identifier_registrations: Enum.count(plans, & &1.register_identifier?),
      stale_device_agent_links: Enum.sum(Enum.map(plans, &length(&1.stale_device_agent_uids))),
      target_agent_link_assignments: Enum.count(plans, & &1.assign_target_agent?),
      alias_states_to_stale: Enum.sum(Enum.map(plans, &length(&1.alias_ids))),
      ip_literal_devices: ip_literal_uids
    }

    case mode do
      :dry_run ->
        report

      :execute ->
        stats =
          Enum.reduce(plans, %{errors: 0}, fn plan, stats ->
            apply_plan(plan, manifest, actor, stats)
          end)

        fixed = fix_ip_literal(ip_literal, manifest)

        report
        |> Map.merge(stats)
        |> Map.put(:ip_literal_fixed, fixed)
    end
  end

  # -- planning (read-only) ----------------------------------------------------

  defp scoped_agents(opts, actor) do
    statuses = Keyword.get(opts, :agent_statuses, @default_statuses)
    uids = Keyword.get(opts, :agent_uids, [])

    Agent
    |> Ash.Query.filter(status in ^statuses)
    |> Ash.read!(actor: actor)
    |> then(fn agents ->
      if uids == [], do: agents, else: Enum.filter(agents, &(&1.uid in uids))
    end)
    |> Enum.sort_by(& &1.uid)
  end

  defp build_plans(agents, actor) do
    devices =
      agents
      |> Enum.map(& &1.device_uid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn uid -> {uid, fetch_device(uid, actor)} end)

    sharing = Enum.group_by(agents, & &1.device_uid)

    {plans, _claimed} =
      Enum.reduce(agents, {[], MapSet.new()}, fn agent, {plans, claimed} ->
        plan = plan_agent(agent, devices, sharing, claimed, actor)
        claimed = if plan.target_uid, do: MapSet.put(claimed, plan.target_uid), else: claimed
        {[plan | plans], claimed}
      end)

    Enum.reverse(plans)
  end

  defp plan_agent(agent, devices, sharing, claimed, actor) do
    expected = Decisions.expected_hostname(agent)
    device = devices[agent.device_uid]

    base = %{
      agent_uid: agent.uid,
      agent: agent,
      old_device_uid: agent.device_uid,
      expected_hostname: expected,
      target_uid: nil,
      target_device: nil,
      create_attrs: nil,
      action: :skip,
      skip_reason: nil,
      identifier_move_ids: [],
      register_identifier?: false,
      stale_device_agent_uids: [],
      assign_target_agent?: false,
      alias_ids: []
    }

    cond do
      is_nil(expected) ->
        %{base | skip_reason: :no_expected_hostname}

      keeps_current_device?(agent, device, expected, sharing) ->
        finalize_plan(%{base | action: :keep, target_uid: device.uid}, actor)

      true ->
        base
        |> relocate(agent, expected, claimed, actor)
        |> finalize_plan(actor)
    end
  end

  # Golden path: the agent keeps its current device when that device is the
  # agent's own — anchored on the stable agent_id (survives k8s pod renames and
  # IP churn), with hostname as corroboration only — AND the row is a clean
  # single host, not a faker/merge chimera carrying foreign strong identity.
  # The previous hostname-only anchor churned every time a pod was recreated
  # under a new name, and happily kept agents welded to multi-host chimeras.
  defp keeps_current_device?(agent, device, expected, sharing) do
    not is_nil(device) and is_nil(Map.get(device, :deleted_at)) and
      not chimera_device?(device) and
      agent_owns_device?(agent, device, expected) and
      rightful_owner_of_shared?(agent, device, sharing)
  end

  # agent_id is the anchor (the agent declares it; it does not change on pod
  # rename). Hostname is accepted only as corroboration for devices that do not
  # yet carry the agent's agent_id identifier row.
  defp agent_owns_device?(agent, device, expected) do
    device_carries_agent_id?(device, agent.uid) or
      Decisions.device_matches_host?(device, expected)
  end

  defp device_carries_agent_id?(device, agent_uid) do
    device
    |> device_identifiers()
    |> Enum.any?(&(&1.identifier_type == :agent_id and &1.identifier_value == agent_uid))
  end

  # A real host carries identity for exactly one machine. Multiple distinct
  # armis_device_ids — or an implausible MAC cardinality — means the row is a
  # faker/merge chimera (e.g. the agent welded onto a 60-MAC faker device). An
  # agent must never keep such a row; it relocates to a clean one.
  defp chimera_device?(device) do
    identifiers = device_identifiers(device)

    distinct_armis =
      identifiers
      |> Enum.filter(&(&1.identifier_type == :armis_device_id))
      |> Enum.map(& &1.identifier_value)
      |> Enum.uniq()
      |> length()

    mac_count = Enum.count(identifiers, &(&1.identifier_type == :mac))

    distinct_armis > 1 or mac_count > @max_plausible_host_macs
  end

  defp device_identifiers(device) do
    case Map.get(device, :identifiers) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp rightful_owner_of_shared?(agent, device, sharing) do
    case Map.get(sharing, agent.device_uid, [agent]) do
      [_single] ->
        true

      shared ->
        owner = Decisions.choose_device_owner(shared, device.hostname)
        owner != nil and owner.uid == agent.uid
    end
  end

  defp relocate(plan, agent, expected, claimed, actor) do
    candidates = relocation_candidates(agent, expected, claimed, actor)

    live = Enum.filter(candidates, &is_nil(&1.deleted_at))
    tombstoned = Enum.reject(candidates, &is_nil(&1.deleted_at))

    cond do
      (adopt = most_recent(Enum.filter(live, &(&1.agent_id == agent.uid)))) != nil ->
        %{plan | action: :adopt, target_uid: adopt.uid, target_device: adopt}

      (restore = most_recent(tombstoned)) != nil ->
        %{plan | action: :restore, target_uid: restore.uid, target_device: restore}

      true ->
        %{plan | action: :create, create_attrs: create_attrs(agent)}
    end
  end

  # Candidate per-host devices for an agent: anything carrying its agent_id
  # or its expected hostname, excluding the (wrong) current device and
  # devices already claimed by another agent's plan. Tombstoned candidates
  # must not carry a different agent's identity.
  defp relocation_candidates(agent, expected, claimed, actor) do
    by_agent_id =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(agent_id == ^agent.uid)
      |> read_all!(actor)

    by_hostname =
      case agent.host do
        host when is_binary(host) and host != "" ->
          Device
          |> Ash.Query.for_read(:read, %{include_deleted: true})
          |> Ash.Query.filter(hostname == ^host)
          |> read_all!(actor)

        _ ->
          []
      end

    (by_agent_id ++ by_hostname)
    |> Enum.uniq_by(& &1.uid)
    |> Enum.filter(fn device ->
      device.uid != agent.device_uid and
        not MapSet.member?(claimed, device.uid) and
        Decisions.normalize_hostname(device.hostname) == expected and
        device.agent_id in [agent.uid, nil]
    end)
  end

  defp create_attrs(agent) do
    then(
      %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: agent.host || agent.name,
        agent_id: agent.uid,
        discovery_sources: ["agent"],
        metadata: %{"created_by" => "dire_remediation", "step" => @step}
      },
      fn attrs ->
        if Decisions.valid_ip?(agent.ip), do: Map.put(attrs, :ip, agent.ip), else: attrs
      end
    )
  end

  # Identifier and alias work applies to every non-skipped plan (a correct
  # device link can still have a stranded agent_id identifier or poisoned
  # alias rows elsewhere).
  defp finalize_plan(plan, actor) do
    target_uid = plan.target_uid || (plan.create_attrs && plan.create_attrs.uid)

    identifiers =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :agent_id and identifier_value == ^plan.agent_uid)
      |> Ash.read!(actor: actor)

    moves = Enum.filter(identifiers, &(&1.device_id != target_uid))

    alias_ids =
      if Decisions.valid_ip?(plan.agent.ip) do
        agent_ip = String.trim(plan.agent.ip)

        DeviceAliasState
        |> Ash.Query.filter(
          alias_value == ^agent_ip and
            state in ^@active_alias_states and
            device_id != ^target_uid
        )
        |> Ash.read!(actor: actor)
      else
        []
      end

    {assign_target_agent?, stale_device_agent_uids} =
      device_agent_link_repairs(plan.agent_uid, target_uid, plan.action)

    %{
      plan
      | target_uid: target_uid,
        identifier_move_ids: moves,
        register_identifier?: identifiers == [],
        stale_device_agent_uids: stale_device_agent_uids,
        assign_target_agent?: assign_target_agent?,
        alias_ids: alias_ids
    }
  end

  defp device_agent_link_repairs(_agent_uid, nil, _action), do: {false, []}

  defp device_agent_link_repairs(agent_uid, target_uid, action) do
    %{rows: rows} =
      query!(
        """
        SELECT uid, agent_id
        FROM platform.ocsf_devices
        WHERE deleted_at IS NULL
          AND (uid = $1 OR agent_id = $2)
        """,
        [target_uid, agent_uid]
      )

    target_agent_id =
      Enum.find_value(rows, fn
        [^target_uid, agent_id] -> agent_id
        _ -> nil
      end)

    stale_uids =
      Enum.flat_map(rows, fn
        [uid, ^agent_uid] when uid != target_uid -> [uid]
        _ -> []
      end)

    assign_target? = action != :create and target_agent_id != agent_uid

    {assign_target?, stale_uids}
  end

  defp most_recent([]), do: nil

  defp most_recent(devices) do
    Enum.max_by(devices, fn device ->
      case device.last_seen_time do
        %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
        _ -> 0
      end
    end)
  end

  defp count_actions(plans, action), do: Enum.count(plans, &(&1.action == action))

  defp describe_plan(plan) do
    %{
      agent_uid: plan.agent_uid,
      action: plan.action,
      skip_reason: plan.skip_reason,
      expected_hostname: plan.expected_hostname,
      old_device_uid: plan.old_device_uid,
      target_device_uid: plan.target_uid,
      identifier_moves: Enum.map(plan.identifier_move_ids, & &1.device_id),
      register_identifier: plan.register_identifier?,
      stale_device_agent_links: plan.stale_device_agent_uids,
      assign_target_agent: plan.assign_target_agent?,
      alias_states_to_stale: Enum.map(plan.alias_ids, &"#{&1.alias_type}:#{&1.alias_value}")
    }
  end

  # -- execution ----------------------------------------------------------------

  defp apply_plan(%{action: :skip}, _manifest, _actor, stats), do: stats

  defp apply_plan(plan, manifest, actor, stats) do
    with {:ok, target_uid} <- ensure_target_device(plan, manifest, actor),
         :ok <- repoint_agent(plan, target_uid, manifest, actor),
         :ok <- repair_device_agent_links(plan, target_uid, manifest),
         :ok <- record_relocation_audit(plan, target_uid, actor),
         :ok <- repair_identifiers(plan, target_uid, manifest, actor),
         :ok <- stale_aliases(plan, manifest, actor) do
      stats
    else
      {:error, error} ->
        Logger.warning(
          "AgentLinks: remediation failed for agent #{plan.agent_uid}: #{inspect(error)}"
        )

        Map.update!(stats, :errors, &(&1 + 1))
    end
  end

  defp ensure_target_device(%{action: :keep, target_uid: uid}, _manifest, _actor), do: {:ok, uid}

  defp ensure_target_device(%{action: :adopt, target_uid: uid}, _manifest, _actor), do: {:ok, uid}

  # Atomic updates build their query from the primary read, which filters
  # tombstoned rows — restore must go through an include_deleted query.
  defp ensure_target_device(%{action: :restore} = plan, manifest, actor) do
    result =
      Device
      |> Ash.Query.for_read(:by_uid, %{uid: plan.target_device.uid, include_deleted: true})
      |> Ash.bulk_update(:restore, %{},
        actor: actor,
        return_errors?: true,
        strategy: [:atomic, :stream]
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        Manifest.record(
          manifest,
          @step,
          :restore_device,
          "platform.ocsf_devices",
          [plan.target_device.uid],
          %{agent_uid: plan.agent_uid}
        )

        {:ok, plan.target_device.uid}

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp ensure_target_device(%{action: :create} = plan, manifest, actor) do
    case Device
         |> Ash.Changeset.for_create(:create, plan.create_attrs)
         |> Ash.create(actor: actor) do
      {:ok, device} ->
        Manifest.record(manifest, @step, :create_device, "platform.ocsf_devices", [device.uid], %{
          agent_uid: plan.agent_uid
        })

        {:ok, device.uid}

      {:error, _} = error ->
        error
    end
  end

  defp repoint_agent(%{old_device_uid: uid}, uid, _manifest, _actor), do: :ok

  defp repoint_agent(plan, target_uid, manifest, actor) do
    case plan.agent
         |> Ash.Changeset.for_update(:reassign_device, %{device_uid: target_uid})
         |> Ash.update(actor: actor) do
      {:ok, _} ->
        # A repoint changes identity composition on BOTH sides: the old device
        # stops naming the machine this agent runs on, the target starts naming
        # it. The no-op clause above (old == target) deliberately bumps neither.
        bump_device_revision(plan.old_device_uid, actor)
        bump_device_revision(target_uid, actor)

        Manifest.record(
          manifest,
          @step,
          :reassign_agent_device,
          "platform.ocsf_agents",
          [plan.agent_uid],
          %{from: plan.old_device_uid, to: target_uid}
        )

        :ok

      {:error, _} = error ->
        error
    end
  end

  # ocsf_devices.agent_id IS agent identity in this codebase -- AliasGuard reads it
  # as one when deciding whether a merge is blocked by distinct agent identity -- so
  # gaining or losing it is a transition.
  #
  # nil covers a never-linked agent. A uid that no longer resolves to a live device
  # is skipped rather than chased through an include_deleted read: :soft_delete
  # already carries a bump, so a tombstone's fence has moved and there is nothing
  # here to correct. Best-effort, like the rest of this repair step.
  defp bump_device_revision(nil, _actor), do: :ok

  defp bump_device_revision(device_uid, actor) when is_binary(device_uid) do
    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, %Device{} = device} ->
        case Device.bump_identity_revision(device, actor: actor) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.warning(
              "Failed to bump identity revision for #{device_uid}: #{inspect(error)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  defp repair_device_agent_links(plan, target_uid, manifest) do
    with :ok <- clear_stale_device_agent_links(plan.agent_uid, target_uid, manifest) do
      ensure_target_device_agent_link(plan.agent_uid, target_uid, manifest)
    end
  end

  defp clear_stale_device_agent_links(agent_uid, target_uid, manifest) do
    %{rows: rows} =
      query!(
        """
        UPDATE platform.ocsf_devices
        SET agent_id = NULL,
            modified_time = now(),
            identity_revision = identity_revision + 1
        WHERE deleted_at IS NULL
          AND agent_id = $1
          AND uid <> $2
        RETURNING uid
        """,
        [agent_uid, target_uid]
      )

    uids = List.flatten(rows)

    if uids != [] do
      Manifest.record(
        manifest,
        @step,
        :clear_stale_device_agent_links,
        "platform.ocsf_devices",
        uids,
        %{agent_uid: agent_uid, target: target_uid}
      )
    end

    :ok
  end

  defp ensure_target_device_agent_link(agent_uid, target_uid, manifest) do
    %{rows: rows} =
      query!(
        """
        UPDATE platform.ocsf_devices
        SET agent_id = $1,
            modified_time = now(),
            identity_revision = identity_revision + 1
        WHERE deleted_at IS NULL
          AND uid = $2
          AND agent_id IS DISTINCT FROM $1
        RETURNING uid
        """,
        [agent_uid, target_uid]
      )

    uids = List.flatten(rows)

    if uids != [] do
      Manifest.record(
        manifest,
        @step,
        :assign_target_device_agent_link,
        "platform.ocsf_devices",
        uids,
        %{agent_uid: agent_uid}
      )
    end

    :ok
  end

  # Reason "unmerge" + a fresh audit row arms the per-pair merge cooldown so
  # the alias-merge war cannot immediately re-collapse the split pair.
  defp record_relocation_audit(%{action: action}, _target, _actor) when action == :keep, do: :ok

  defp record_relocation_audit(plan, target_uid, actor) do
    if is_binary(plan.old_device_uid) and plan.old_device_uid != target_uid do
      case MergeAudit.record(
             %{
               from_device_id: plan.old_device_uid,
               to_device_id: target_uid,
               reason: "unmerge",
               source: "dire_remediation",
               details: %{
                 step: @step,
                 agent_uid: plan.agent_uid,
                 action: to_string(plan.action),
                 expected_hostname: plan.expected_hostname
               }
             },
             actor: actor
           ) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp repair_identifiers(plan, target_uid, manifest, actor) do
    moved =
      Enum.reduce_while(plan.identifier_move_ids, [], fn identifier, acc ->
        case identifier
             |> Ash.Changeset.for_update(:reassign_device, %{device_id: target_uid})
             |> Ash.update(actor: actor) do
          {:ok, _} -> {:cont, [identifier.id | acc]}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    with ids when is_list(ids) <- moved do
      if ids != [] do
        Manifest.record(
          manifest,
          @step,
          :reassign_agent_identifier,
          "platform.device_identifiers",
          Enum.reverse(ids),
          %{agent_uid: plan.agent_uid, to: target_uid}
        )
      end

      maybe_register_identifier(plan, target_uid, manifest, actor)
    end
  end

  defp maybe_register_identifier(%{register_identifier?: false}, _target, _manifest, _actor),
    do: :ok

  defp maybe_register_identifier(plan, target_uid, manifest, actor) do
    case DeviceIdentifier
         |> Ash.Changeset.for_create(:upsert, %{
           device_id: target_uid,
           identifier_type: :agent_id,
           identifier_value: plan.agent_uid,
           partition: "default",
           confidence: :strong,
           source: "dire_remediation"
         })
         |> Ash.create(actor: actor) do
      {:ok, identifier} ->
        Manifest.record(
          manifest,
          @step,
          :register_agent_identifier,
          "platform.device_identifiers",
          [identifier.id],
          %{agent_uid: plan.agent_uid}
        )

        :ok

      {:error, _} = error ->
        error
    end
  end

  defp stale_aliases(plan, manifest, actor) do
    staled =
      Enum.reduce_while(plan.alias_ids, [], fn alias_state, acc ->
        case DeviceAliasState.mark_stale(alias_state, actor: actor) do
          {:ok, _} -> {:cont, [to_string(alias_state.id) | acc]}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    with ids when is_list(ids) <- staled do
      if ids != [] do
        Manifest.record(
          manifest,
          @step,
          :mark_alias_stale,
          "platform.device_alias_states",
          Enum.reverse(ids),
          %{agent_uid: plan.agent_uid}
        )
      end

      :ok
    end
  end

  # -- ip literal fix -----------------------------------------------------------

  defp devices_with_ip_literal(ip_literal) when is_binary(ip_literal) and ip_literal != "" do
    %{rows: rows} =
      query!("SELECT uid FROM platform.ocsf_devices WHERE ip = $1", [ip_literal])

    List.flatten(rows)
  end

  defp devices_with_ip_literal(_), do: []

  defp fix_ip_literal(ip_literal, manifest) when is_binary(ip_literal) and ip_literal != "" do
    %{rows: rows} =
      query!(
        "UPDATE platform.ocsf_devices SET ip = NULL, modified_time = now() " <>
          "WHERE ip = $1 RETURNING uid",
        [ip_literal]
      )

    uids = List.flatten(rows)

    Manifest.record(manifest, @step, :clear_ip_literal, "platform.ocsf_devices", uids, %{
      ip_literal: ip_literal
    })

    length(uids)
  end

  defp fix_ip_literal(_, _), do: 0

  # Device's primary read paginates by default; unwrap to a plain list.
  defp read_all!(query, actor) do
    case Ash.read!(query, actor: actor) do
      %Ash.Page.Keyset{results: results} -> results
      %Ash.Page.Offset{results: results} -> results
      results when is_list(results) -> results
    end
  end

  defp fetch_device(uid, actor) do
    case Device.get_by_uid(uid, true, actor: actor) do
      {:ok, %Device{} = device} ->
        case Ash.load(device, [:identifiers], actor: actor) do
          {:ok, loaded} -> loaded
          _ -> device
        end

      _ ->
        nil
    end
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
