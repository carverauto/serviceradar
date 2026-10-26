defmodule ServiceRadar.Inventory.Identity.AwxSourceRetirement do
  @moduledoc """
  Retires the AWX source of inventory records whose AWX host the controller no longer reports.

  AWX inventory sync reports one aggregate per controller, and
  `ServiceRadar.Automation.Ansible.AwxMembershipReconciler` expires the membership of every host
  a complete aggregate leaves out. Nothing retired the inventory records built from those hosts,
  so a host removed from AWX stayed a live device, and a record keyed by the pre-v2 identity
  (`awx:host:<name>`) stayed live beside the v2 record (`awx:v2:<controller>:host:<host id>`)
  that replaced it.

  A pass runs for one controller after a complete observation commits
  (`ServiceRadar.Inventory.Identity.AwxSourceRetirementWorker`), and acts only while the
  controller's latest observation (`platform.ansible_awx_inventory_observations`) is complete. A
  partial observation, such as an unreadable inventory, a failed page or an expired token,
  retires nothing; nor does a controller whose sync never produced a versioned aggregate. After
  a complete observation the controller's current memberships are exactly the hosts it
  reported, so they are the reported set.

  A live, unmarked record is linked to the controller when it holds one of the controller's v2
  AWX `integration_id`s or its `metadata.awx.controller_id` names the controller. A linked record
  is current when it holds the v2 id of a reported host, or its `metadata.awx.host_id` names a
  reported host whose v2 id no other live record holds. Any other linked record is either
  `:absent` (its host is not reported) or `:superseded` (its host is reported, and another
  record holds the host's v2 id).

  Retiring an absent or superseded record:

    * archives the AWX `integration_id` rows it holds (the controller's v2 ids and legacy
      `awx:host:<name>` ids) to `device_identifier_archive` with `archive_reason`
      `source_absent`, through `SourceRetirement.archive_identifiers/3`, and records one
      `source_id_retired` identity decision per id;
    * marks the record `source_retired` when AWX was its only source (`discovery_sources` holds
      nothing but `awx`) and it is retired-only (`SourceRetirement`, design D5), so that
      `ServiceRadar.Inventory.SourceRetiredExpiry` soft-deletes it after the grace period. A
      marked record also releases every other identifier it holds (an address or MAC AWX gave
      it) to the archive, with a decision each, so that no lookup still finds a record awaiting
      deletion and the device that really has them can register them;
    * otherwise removes only its AWX source: `awx` leaves `discovery_sources`, and
      `metadata.awx` and an AWX `metadata.integration_id` are dropped.

  A current record keeps its AWX source and loses only the v2 ids of hosts no longer reported.

  An id retires only once AWX last reported it at least `source_retirement_min_absence_hours`
  ago: the later of the identifier's `last_seen` and, for an absent host, the membership's
  `last_seen_at`. A record holding no AWX id row is judged by its absent host's membership
  `last_seen_at`, which another source cannot refresh, and only without a membership time (no
  versioned observation ever reported the host, or a superseded record, whose host is reported
  for the record that replaced it) by its `last_seen_time`. The pass honours
  `source_retirement_enabled`, and the mass guard (`source_retirement_max_fraction`) and its
  override, as the collection-scoped pass (`SourceRetirement.run/2`) does.

  Residual risk, accepted pending a product decision: a host AWX reports again while its record
  is still marked, and whose report lands on that record (by address or MAC), does not clear the
  mark, because an `integration_id` is not a mark-clearing identifier type
  (`trg_device_identifiers_clear_source_retired`). The record stays hidden until the grace pass
  deletes it, and the host returns as a new record on a later sync. A re-created AWX host gets a
  new host id, so this needs the same host to come back within the grace period.

  Each record retires in its own transaction, under the controller's observation lock (the lock
  `AwxInventoryObservationFence` takes), then the record's lock and the identifier owner lock,
  in the order the ingest and `SourceRetirement` take them. The observation and the record's
  AWX ids are read again under those locks: a newer observation, a record marked or deleted
  since, or an AWX id reported since leaves the record alone.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.Repo

  require Logger

  @source "awx"
  @archive_reason "source_absent"
  @decision_source "awx_source_retirement"
  @legacy_prefix "awx:host:"

  @observation_sql """
  SELECT source_generation, complete
  FROM platform.ansible_awx_inventory_observations
  WHERE controller_id = (CAST($1 AS text))::uuid
  """

  # Per host the controller has a membership for: whether the latest complete observation
  # reported it, and when AWX last reported it.
  @hosts_sql """
  SELECT m.awx_host_id, bool_or(m.current), max(m.last_seen_at)
  FROM platform.ansible_awx_host_memberships AS m
  WHERE m.controller_id = (CAST($1 AS text))::uuid
  GROUP BY m.awx_host_id
  """

  # The live, unmarked records linked to the controller ($1) by metadata or by a v2 id ($2 the
  # v2 prefix pattern).
  @linked_sql """
  SELECT d.uid, d.metadata -> 'awx' ->> 'host_id', d.last_seen_time
  FROM platform.ocsf_devices AS d
  WHERE d.deleted_at IS NULL AND d.source_retired_at IS NULL
    AND (d.metadata -> 'awx' ->> 'controller_id' = CAST($1 AS text)
      OR d.uid IN (
        SELECT di.device_id FROM platform.device_identifiers AS di
        WHERE di.identifier_type = 'integration_id'
          AND di.identifier_value LIKE CAST($2 AS text)
      ))
  """

  # The controller's v2 ids held by any live record, and the legacy ids of the linked records
  # $2.
  @ids_sql """
  SELECT di.id, di.device_id, di.identifier_value, COALESCE(di.partition, 'default'),
         di.last_seen
  FROM platform.device_identifiers AS di
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  WHERE di.identifier_type = 'integration_id'
    AND (di.identifier_value LIKE CAST($1 AS text)
      OR (di.device_id = ANY (CAST($2 AS text[]))
        AND di.identifier_value LIKE CAST($3 AS text)))
  """

  # The record's AWX ids, locked, as the recheck reads them.
  @device_ids_sql """
  SELECT di.id, di.device_id, di.identifier_value, COALESCE(di.partition, 'default'),
         di.last_seen
  FROM platform.device_identifiers AS di
  WHERE di.device_id = CAST($1 AS text) AND di.identifier_type = 'integration_id'
    AND (di.identifier_value LIKE CAST($2 AS text) OR di.identifier_value LIKE CAST($3 AS text))
  ORDER BY di.id
  FOR UPDATE
  """

  # Every identifier row a marked record still holds, locked, with its type.
  @remaining_ids_sql """
  SELECT di.id, di.device_id, di.identifier_value, COALESCE(di.partition, 'default'),
         di.last_seen, di.identifier_type::text
  FROM platform.device_identifiers AS di
  WHERE di.device_id = CAST($1 AS text)
  ORDER BY di.id
  FOR UPDATE
  """

  @strip_sql """
  UPDATE platform.ocsf_devices AS d
  SET discovery_sources = array_remove(COALESCE(d.discovery_sources, ARRAY[]::text[]), 'awx'),
      metadata = COALESCE(d.metadata, '{}'::jsonb) - 'awx' -
        CASE WHEN d.metadata ->> 'integration_id' LIKE 'awx:%'
          THEN ARRAY['integration_id', 'legacy_integration_ids']
          ELSE ARRAY[]::text[]
        END,
      modified_time = CAST($2 AS timestamp)
  WHERE d.uid = CAST($1 AS text) AND d.deleted_at IS NULL
  """

  @doc """
  Runs one retirement pass for the AWX controller `controller_id`.

  `opts`: `:settings` (required, the `DeviceCleanupSettings`), `:actor` and `:now`.

  Returns `{:ok, stats}`, whose `:status` is `:completed`, `:disabled` or
  `:incomplete_observation`, or `{:error, {:mass_retirement_refused, counts}}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(controller_id, opts) when is_binary(controller_id) do
    settings = Keyword.fetch!(opts, :settings)

    with :ok <- ensure_enabled(settings),
         {:ok, observation} <- complete_observation(controller_id) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      ctx = %{
        controller_id: controller_id,
        observation: observation,
        cutoff: DateTime.shift(now, hour: -settings.source_retirement_min_absence_hours),
        min_absence_hours: settings.source_retirement_min_absence_hours,
        actor: Keyword.get(opts, :actor, SystemActor.system(:source_retirement))
      }

      {linked, plans} = read_plans(ctx)

      with :ok <- mass_retirement_guard(plans, length(linked), settings, ctx) do
        {:ok, retire_plans(plans, ctx)}
      end
    else
      {:skip, status} -> {:ok, %{status: status}}
    end
  end

  # The retirement plan for one controller, from what the database holds (see the moduledoc
  # for the rule): the linked records (`%{uid:, host_id:, last_seen_time:}`), the controller's
  # v2 ids held by live records and the linked records' legacy ids (`%{id:, device_id:, value:,
  # partition:, last_seen:}`), and per AWX host id `%{current:, last_seen_at:}` from its
  # memberships. An id last reported after `cutoff` does not retire.
  defp plan(controller_id, devices, ids, hosts, cutoff) do
    prefix = v2_prefix(controller_id)
    ids = Enum.map(ids, &Map.put(&1, :host_id, v2_host_id(&1.value, prefix)))

    v2_holders =
      ids
      |> Enum.filter(& &1.host_id)
      |> Enum.group_by(& &1.host_id, & &1.device_id)

    ids_by_device = Enum.group_by(ids, & &1.device_id)

    devices
    |> Enum.map(fn device ->
      device_plan(device, Map.get(ids_by_device, device.uid, []), v2_holders, hosts, cutoff)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.device_id)
  end

  defp device_plan(device, device_ids, v2_holders, hosts, cutoff) do
    held_hosts = for %{host_id: host_id} when is_integer(host_id) <- device_ids, do: host_id
    reported? = &(get_in(hosts, [&1, :current]) == true)

    current? =
      Enum.any?(held_hosts, reported?) or
        (reported?.(device.host_id) and
           Enum.all?(Map.get(v2_holders, device.host_id, []), &(&1 == device.uid)))

    if current? do
      stale =
        Enum.filter(device_ids, fn id ->
          is_integer(id.host_id) and not reported?.(id.host_id) and
            reported_by?(id_reported_at(id, hosts), cutoff)
        end)

      if stale != [],
        do: %{device_id: device.uid, outcome: :stale_ids, host_ids: hosts_of(stale), ids: stale}
    else
      outcome = if reported?.(device.host_id), do: :superseded, else: :absent
      host_ids = Enum.uniq(Enum.reject([device.host_id | held_hosts], &is_nil/1))

      {reported_at, clock} = record_reported_at(device, device_ids, host_ids, outcome, hosts)

      if reported_by?(reported_at, cutoff) do
        %{
          device_id: device.uid,
          outcome: outcome,
          host_ids: host_ids,
          ids: device_ids,
          clock: clock
        }
      end
    end
  end

  defp hosts_of(ids), do: ids |> Enum.map(& &1.host_id) |> Enum.uniq()

  defp id_reported_at(id, hosts),
    do: latest([id.last_seen, get_in(hosts, [id.host_id, :last_seen_at])])

  # When AWX last reported the record, and the clock that says so. A superseded record's host
  # is reported for the record that replaced it, so its membership says nothing about this one.
  # A record with no AWX id row falls back to its own last_seen_time only without a membership
  # time: another source refreshes last_seen_time, so it would hold the AWX source forever.
  defp record_reported_at(device, device_ids, host_ids, outcome, hosts) do
    membership_at =
      if outcome == :absent,
        do: latest(Enum.map(host_ids, &get_in(hosts, [&1, :last_seen_at])))

    cond do
      device_ids != [] ->
        {latest([membership_at | Enum.map(device_ids, & &1.last_seen)]), :identifiers}

      membership_at ->
        {membership_at, :membership}

      true ->
        {to_datetime(device.last_seen_time), :last_seen_time}
    end
  end

  defp latest(times) do
    times
    |> Enum.map(&to_datetime/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # No report time is no proof of absence.
  defp reported_by?(nil, _cutoff), do: false
  defp reported_by?(%DateTime{} = at, cutoff), do: DateTime.compare(at, cutoff) != :gt

  defp to_datetime(%DateTime{} = at), do: at
  defp to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_datetime(_at), do: nil

  defp v2_prefix(controller_id), do: "awx:v2:" <> controller_id <> ":host:"

  defp v2_host_id(value, prefix) do
    with ^prefix <> rest <- value,
         {host_id, ""} when host_id > 0 <- Integer.parse(rest) do
      host_id
    else
      _ -> nil
    end
  end

  defp ensure_enabled(%{source_retirement_enabled: true}), do: :ok
  defp ensure_enabled(_settings), do: {:skip, :disabled}

  defp complete_observation(controller_id) do
    case Repo.query!(@observation_sql, [controller_id]) do
      %{rows: [[generation, true]]} -> {:ok, %{source_generation: generation}}
      _ -> {:skip, :incomplete_observation}
    end
  end

  defp read_plans(ctx) do
    controller_id = ctx.controller_id
    pattern = v2_prefix(controller_id) <> "%"

    linked =
      Enum.map(Repo.query!(@linked_sql, [controller_id, pattern]).rows, fn
        [uid, host_id, last_seen_time] ->
          %{uid: uid, host_id: parse_host_id(host_id), last_seen_time: last_seen_time}
      end)

    ids = read_ids(pattern, Enum.map(linked, & &1.uid))

    hosts =
      Map.new(Repo.query!(@hosts_sql, [controller_id]).rows, fn [host_id, current, seen] ->
        {host_id, %{current: current, last_seen_at: seen}}
      end)

    {linked, plan(controller_id, linked, ids, hosts, ctx.cutoff)}
  end

  defp read_ids(pattern, uids) do
    @ids_sql
    |> Repo.query!([pattern, uids, @legacy_prefix <> "%"])
    |> id_rows()
  end

  defp id_rows(%{rows: rows}) do
    Enum.map(rows, fn [id, device_id, value, partition, last_seen] ->
      %{id: id, device_id: device_id, value: value, partition: partition, last_seen: last_seen}
    end)
  end

  defp parse_host_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {host_id, ""} when host_id > 0 -> host_id
      _ -> nil
    end
  end

  defp parse_host_id(_value), do: nil

  defp mass_retirement_guard(plans, live, settings, ctx) do
    devices = length(plans)
    max_fraction = settings.source_retirement_max_fraction

    case CanonicalRebuild.prune_guard_check(devices, live, max_fraction, false) do
      :allow ->
        :ok

      {:refuse, reason} ->
        if settings.source_retirement_guard_override == true and
             SourceRetirement.consume_guard_override() do
          Logger.warning(
            "AwxSourceRetirement: controller #{ctx.controller_id} pass over the guard " <>
              "admitted by source_retirement_guard_override, now cleared: retiring the AWX " <>
              "source of #{devices} of #{live} linked records (max fraction #{max_fraction})"
          )

          :ok
        else
          refuse(reason, devices, live, max_fraction, ctx)
        end
    end
  end

  defp refuse(reason, devices, live, max_fraction, ctx) do
    :telemetry.execute(
      [:serviceradar, :inventory, :source_retirement, :refused],
      %{candidates: devices, live_devices: live},
      %{
        reason: reason,
        max_fraction: max_fraction,
        source: @source,
        source_instance: ctx.controller_id
      }
    )

    Logger.error(
      "AwxSourceRetirement: controller #{ctx.controller_id} pass refused (#{reason}): would " <>
        "retire the AWX source of #{devices} of #{live} linked records in one pass (max " <>
        "fraction #{max_fraction}); set source_retirement_guard_override in the device " <>
        "cleanup settings to admit it"
    )

    {:error,
     {:mass_retirement_refused, %{candidates: devices, live: live, max_fraction: max_fraction}}}
  end

  defp retire_plans(plans, ctx) do
    results = Enum.map(plans, &{&1, retire_device(&1, ctx)})
    retired = for {plan, {:ok, %{} = retirement}} <- results, do: {plan, retirement}

    stats = %{
      status: :completed,
      candidates: length(plans),
      retired: retired |> Enum.map(fn {_plan, r} -> length(r.ids) end) |> Enum.sum(),
      devices: length(retired),
      marked: Enum.count(retired, fn {_plan, r} -> r.effect == :marked end),
      stripped: Enum.count(retired, fn {_plan, r} -> r.effect == :stripped end),
      skipped: Enum.count(results, &match?({_plan, {:ok, :not_retirable}}, &1)),
      failed: Enum.count(results, &match?({_plan, {:error, _}}, &1))
    }

    :telemetry.execute(
      [:serviceradar, :inventory, :source_retirement, :run],
      Map.take(stats, [:candidates, :retired, :devices, :marked, :skipped, :failed]),
      %{source: @source, source_instance: ctx.controller_id}
    )

    log_retired(retired, ctx)
    stats
  end

  defp retire_device(plan, ctx) do
    Device
    |> Ash.transact(fn ->
      lock_observation(ctx.controller_id)

      with true <- observation_unchanged?(ctx),
           {:ok, device} <- SourceRetirement.lock_live_device(plan.device_id, ctx.actor),
           :ok <- SourceRetirement.lock_identifier_owner(plan.device_id),
           [_ | _] = ids <- recheck(plan, device, ctx) do
        apply_plan(plan, ids, device, ctx)
      else
        {:error, _} = error -> error
        _not_retirable -> {:ok, :not_retirable}
      end
    end)
    |> case do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:error, error} ->
        Logger.warning(
          "AwxSourceRetirement: controller #{ctx.controller_id} could not retire the AWX " <>
            "source of #{plan.device_id}: " <> inspect(error)
        )

        {:error, error}
    end
  end

  defp lock_observation(controller_id) do
    _ =
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "awx-inventory-observation:" <> controller_id
      ])

    :ok
  end

  # The reported set the plan was read against holds while the controller's latest observation
  # is still the complete one the pass read: memberships change only when an observation
  # advances, under the lock this transaction holds.
  defp observation_unchanged?(ctx) do
    complete_observation(ctx.controller_id) == {:ok, ctx.observation}
  end

  # The record's AWX ids as they stand under the locks. A stale-id plan retires those of its ids
  # still unreported since the cutoff. An absent or superseded plan retires the record's AWX ids
  # only if they are still exactly the ones it read, none reported since; a record with no AWX
  # id row retires on its metadata link alone (`[:metadata_only]`): on its membership time, which
  # holds while the observation is unchanged, or else while its last_seen_time is still before
  # the cutoff.
  defp recheck(plan, device, ctx) do
    held =
      @device_ids_sql
      |> Repo.query!([plan.device_id, v2_prefix(ctx.controller_id) <> "%", @legacy_prefix <> "%"])
      |> id_rows()

    unreported? = fn id -> reported_by?(to_datetime(id.last_seen), ctx.cutoff) end
    planned = MapSet.new(plan.ids, & &1.id)

    case plan.outcome do
      :stale_ids ->
        Enum.filter(held, &(MapSet.member?(planned, &1.id) and unreported?.(&1)))

      _record when held == [] and plan.ids == [] ->
        if plan.clock == :membership or
             reported_by?(to_datetime(device.last_seen_time), ctx.cutoff),
           do: [:metadata_only],
           else: []

      _record ->
        if MapSet.new(held, & &1.id) == planned and Enum.all?(held, unreported?),
          do: held,
          else: []
    end
  end

  defp apply_plan(plan, ids, device, ctx) do
    ids = Enum.reject(ids, &(&1 == :metadata_only))
    now = DateTime.utc_now()
    archived = SourceRetirement.archive_identifiers(plan.device_id, Enum.map(ids, & &1.id), now)

    if archived == length(ids) do
      with {:ok, _device} <- Device.bump_identity_revision(device, actor: ctx.actor),
           {:ok, effect, released} <- record_effect(plan, device, ctx, now),
           ids = ids ++ released,
           :ok <- DecisionLog.record_many_strict(decisions(plan, ids, effect, ctx)) do
        {:ok, %{ids: ids, effect: effect}}
      end
    else
      {:error, {:archive_incomplete, archived, length(ids)}}
    end
  end

  # A stale-id plan leaves the record's AWX source in place. A record AWX alone reported is
  # marked when it is retired-only, and releases every identifier it still holds: AWX gave it
  # each of them (an address, a MAC), and a record awaiting deletion that kept them would still
  # be found by them, and would keep them from the record of the device that really has them.
  # Any other record loses only its AWX source. Returns the effect and the rows released.
  defp record_effect(%{outcome: :stale_ids}, _device, _ctx, _now), do: {:ok, :ids_only, []}

  defp record_effect(plan, device, ctx, now) do
    if awx_only?(device) and mark(plan.device_id, ctx.cutoff, now) do
      release_identifiers(plan.device_id, now)
    else
      strip(plan.device_id, now)
      {:ok, :stripped, []}
    end
  end

  defp release_identifiers(device_id, now) do
    rows =
      Enum.map(Repo.query!(@remaining_ids_sql, [device_id]).rows, fn
        [id, device_id, value, partition, last_seen, type] ->
          %{
            id: id,
            device_id: device_id,
            value: value,
            partition: partition,
            last_seen: last_seen,
            type: type
          }
      end)

    archived = SourceRetirement.archive_identifiers(device_id, Enum.map(rows, & &1.id), now)

    if archived == length(rows),
      do: {:ok, :marked, rows},
      else: {:error, {:archive_incomplete, archived, length(rows)}}
  end

  defp awx_only?(device), do: Enum.all?(device.discovery_sources || [], &(&1 == @source))

  defp mark(device_id, cutoff, now) do
    {retired_only, params} = SourceRetirement.retired_only_condition(cutoff)

    sql = """
    UPDATE platform.ocsf_devices AS d
    SET source_retired_at = CAST($5 AS timestamp)
    WHERE d.uid = CAST($4 AS text) AND #{retired_only}
      AND COALESCE(d.discovery_sources, ARRAY[]::text[]) <@ ARRAY['#{@source}']::text[]
    RETURNING d.source_retired_at
    """

    match?(%{rows: [_marked]}, Repo.query!(sql, params ++ [device_id, now]))
  end

  defp strip(device_id, now) do
    _ = Repo.query!(@strip_sql, [device_id, now])
    :ok
  end

  defp decisions(plan, [], effect, ctx) do
    subject =
      case plan.host_ids do
        [host_id | _] -> v2_prefix(ctx.controller_id) <> Integer.to_string(host_id)
        [] -> "awx:" <> ctx.controller_id
      end

    [decision(plan, subject, %{"identifier_type" => nil}, effect, ctx)]
  end

  defp decisions(plan, ids, effect, ctx) do
    Enum.map(ids, fn id ->
      decision(
        plan,
        id.value,
        %{
          "identifier_type" => Map.get(id, :type, "integration_id"),
          "identifier_value" => id.value,
          "identifier_partition" => id.partition,
          "archived_identifier_id" => id.id,
          "last_reported_at" => iso8601(id.last_seen)
        },
        effect,
        ctx
      )
    end)
  end

  defp decision(plan, subject, evidence, effect, ctx) do
    %{
      kind: :source_id_retired,
      reason: @archive_reason,
      device_uids: [plan.device_id],
      subject: subject,
      source: @decision_source,
      evidence:
        Map.merge(evidence, %{
          "source" => @source,
          "source_instance" => ctx.controller_id,
          "awx_outcome" => Atom.to_string(plan.outcome),
          "awx_host_ids" => plan.host_ids,
          "source_generation" => ctx.observation.source_generation,
          "min_absence_hours" => ctx.min_absence_hours,
          "record_effect" => Atom.to_string(effect),
          "marked_source_retired" => effect == :marked
        })
    }
  end

  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp log_retired([], _ctx), do: :ok

  defp log_retired(retired, ctx) do
    by_effect =
      retired
      |> Enum.group_by(fn {_plan, r} -> r.effect end, fn {plan, _r} -> plan.device_id end)
      |> Map.new(fn {effect, uids} -> {effect, Enum.take(uids, 50)} end)

    Logger.info(
      "AwxSourceRetirement: controller #{ctx.controller_id} retired the AWX source of " <>
        "#{length(retired)} record(s) its complete observation no longer reports, unreported " <>
        "for #{ctx.min_absence_hours}h+: #{inspect(by_effect)}"
    )
  end
end
