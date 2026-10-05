defmodule ServiceRadar.Inventory.Identity.DuplicateSweep do
  @moduledoc """
  Scheduled duplicate reconciliation: builds strong-evidence indexes,
  identifies duplicate components, and merges only isolated device pairs.

  Components larger than two devices are ambiguous and fail closed. Flattening
  a transitive graph into one canonical device can merge vertices that share no
  direct evidence, which is not a safe unattended identity decision.

  After the duplicate pass, the succession pass (`SourceSuccession`, design D3 and D4) merges
  a record whose source-authoritative id retired into the record holding the source's current
  id when the evidence is strong enough, and records a `succession_review` decision when it is
  not.

  A component the sweep blocks, or a pair a merge guard refuses, is recorded with its evidence
  fingerprint (`BlockFingerprint`, design D9). The next run skips it while the fingerprint is
  unchanged: it is counted as blocked and unchanged, and neither attempted nor recorded again.

  Each run's counts are emitted as `[:serviceradar, :identity_reconciler, :run]`, followed by
  the inventory gauges of `PopulationGauges`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceInterfaceMac
  alias ServiceRadar.Inventory.Identity.BlockFingerprint
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.MergePolicy
  alias ServiceRadar.Inventory.Identity.PopulationGauges
  alias ServiceRadar.Inventory.Identity.ReconciliationRun
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Inventory.Identity.SourceSuccession
  alias ServiceRadar.Inventory.IdentityDecision

  require Ash.Query
  require Logger

  @component_block_reason "ambiguous_transitive_component"

  # The devices whose fingerprint inputs one read covers (`BlockFingerprint.load/1`). The
  # components are disjoint, so a chunk of them is read in one pass; a larger component is a
  # chunk of its own.
  @fingerprint_chunk_devices 500

  # The run counts `[:serviceradar, :identity_reconciler, :run]` carries.
  @run_measurements [
    :merges,
    :errors,
    :blocked_components,
    :blocked_merges,
    :blocked_unchanged,
    :succession_merges,
    :succession_reviews,
    :successions_skipped,
    :successions_deferred
  ]

  @doc """
  Reconcile duplicate devices by shared strong identifiers.

  Returns stats for observability and logging, and persists one
  `ReconciliationRun` record per run -- including when the run raises. Before
  that record existed the stats map was logged and dropped, so "did this run
  stop at its cap" and "did this run fail at all" were unanswerable afterwards
  (GitHub #4229).
  """
  @spec reconcile_duplicates(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_duplicates(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:identity_reconciliation))
    # Keyword.get/3 does not apply the default when the key is present as nil.
    # The AshOban job always passes `:max_merges` from schedule.args, which is
    # nil unless an operator set it -- and `halted? or ...` then raises
    # BadBooleanError after the first merge component (prod 2026-08-26).
    max_merges = normalize_max_merges(Keyword.get(opts, :max_merges))

    context = %{
      run_id: Ash.UUID.generate(),
      started_at: DateTime.utc_now(),
      started_monotonic: System.monotonic_time(:millisecond),
      max_merges: max_merges,
      # nil reads `max_successions_per_run` from the device cleanup settings.
      max_successions: Keyword.get(opts, :max_successions),
      trigger: normalize_trigger(Keyword.get(opts, :trigger)),
      job_schedule_id: Keyword.get(opts, :job_schedule_id),
      # A test stands for a release that changes the rules with `:rule_version`.
      fingerprint_opts: [
        rule_version: Keyword.get(opts, :rule_version, BlockFingerprint.rule_version()),
        recheck_seconds: blocked_recheck_seconds()
      ]
    }

    Logger.info("Device identity reconciliation started")

    case run_stages(context, actor) do
      {:ok, acc} ->
        stats = build_run_stats(acc, context)
        Logger.info("Device identity reconciliation completed: #{inspect(stats)}")
        record_run(context, :completed, stats, acc, nil)
        report_run(context, :completed, stats)
        {:ok, stats}

      {:error, acc, error} ->
        stats = build_run_stats(acc, context)
        Logger.warning("Device identity reconciliation failed: #{inspect(error)}")
        record_run(context, :failed, stats, acc, error)
        report_run(context, :failed, stats)
        {:error, error}
    end
  end

  # Stages are threaded rather than written as one straight-line body so that a
  # raise partway through still carries the counters established before it. A
  # function-level `rescue` cannot see variables bound inside the body; it CAN
  # see the ones bound in the head, which is why the accumulator is a parameter.
  defp run_stages(context, actor) do
    {:ok, initial_accumulator()}
    |> run_stage(&collect_duplicate_candidates/1)
    |> run_stage(&classify_and_report(&1, context))
    |> run_stage(&merge_stage(&1, actor, context))
    |> run_stage(&succession_stage(&1, actor, context.max_successions))
  end

  defp run_stage({:error, _acc, _error} = failure, _fun), do: failure

  defp run_stage({:ok, acc}, fun) do
    {:ok, fun.(acc)}
  rescue
    error -> {:error, acc, error}
  end

  @doc false
  def initial_accumulator do
    %{
      duplicate_identifier_count: 0,
      duplicate_components: 0,
      mergeable_components: 0,
      blocked_components: 0,
      blocked_devices: 0,
      largest_blocked_component: 0,
      merges: 0,
      errors: 0,
      blocked_merges: 0,
      blocked_unchanged: 0,
      succession_merges: 0,
      successions_skipped: 0,
      successions_deferred: 0,
      succession_reviews: 0,
      max_successions_configured: nil,
      blocked_component_devices: [],
      identifier_duplicates: [],
      components: []
    }
  end

  defp collect_duplicate_candidates(acc) do
    # Bounded: the database aggregates duplicate identifier groups (values
    # mapped to more than one device); the full identifier table is never
    # loaded into memory. Bare-IP overlap is NOT merge evidence (policy:
    # weak/medium evidence never merges devices), and neither are
    # locally-administered MACs or serial-only matches. Hardware serials are
    # useful during source-aware ingestion, where conflicting universal MACs
    # can veto convergence, but ambiguous legacy serial rows must not drive an
    # unattended scheduled merge.
    identifier_duplicates =
      duplicate_identifier_groups() ++
        hardware_mac_sibling_groups() ++
        agent_anchor_sibling_groups() ++
        column_mac_groups() ++
        interface_mac_chassis_groups()

    %{
      acc
      | identifier_duplicates: identifier_duplicates,
        duplicate_identifier_count: length(identifier_duplicates)
    }
  end

  defp classify_and_report(acc, context) do
    %{mergeable: components, blocked: blocked_components} =
      classify_duplicate_components(acc.identifier_duplicates)

    largest_blocked = report_blocked_components(blocked_components)
    unchanged = record_blocked_components(blocked_components, context.fingerprint_opts)

    %{
      acc
      | components: components,
        blocked_unchanged: acc.blocked_unchanged + unchanged,
        duplicate_components: length(components) + length(blocked_components),
        mergeable_components: length(components),
        blocked_components: length(blocked_components),
        blocked_devices: Enum.sum(Enum.map(blocked_components, &length(&1.device_ids))),
        largest_blocked_component: largest_blocked,
        blocked_component_devices:
          blocked_component_membership(blocked_components, blocked_component_capture_limit())
    }
  end

  defp merge_stage(acc, actor, context) do
    counts = merge_components(acc.components, actor, context)

    %{
      acc
      | merges: counts.merges,
        errors: counts.errors,
        blocked_merges: counts.blocked_merges,
        blocked_unchanged: acc.blocked_unchanged + counts.blocked_unchanged
    }
  end

  # After the duplicate pass, so the succession pass sees the records it merged as merged.
  defp succession_stage(acc, actor, max_successions) do
    {:ok, counts} = SourceSuccession.run(actor: actor, max_successions: max_successions)

    %{
      acc
      | succession_merges: counts.merged,
        successions_skipped: counts.skipped,
        successions_deferred: counts.deferred,
        succession_reviews: counts.reviewed,
        max_successions_configured: counts.max_successions
    }
  end

  @doc false
  def build_run_stats(acc, context) do
    %{
      duplicate_identifier_count: acc.duplicate_identifier_count,
      duplicate_components: acc.duplicate_components,
      mergeable_components: acc.mergeable_components,
      blocked_components: acc.blocked_components,
      blocked_devices: acc.blocked_devices,
      largest_blocked_component: acc.largest_blocked_component,
      merges: acc.merges,
      errors: acc.errors,
      blocked_merges: acc.blocked_merges,
      blocked_unchanged: acc.blocked_unchanged,
      max_merges_configured: context.max_merges,
      merge_cap_reached: merge_cap_reached?(context.max_merges, acc.merges),
      succession_merges: acc.succession_merges,
      successions_skipped: acc.successions_skipped,
      successions_deferred: acc.successions_deferred,
      succession_reviews: acc.succession_reviews,
      max_successions_configured: acc.max_successions_configured,
      duration_ms: System.monotonic_time(:millisecond) - context.started_monotonic
    }
  end

  # A failed run-record write must never fail, roll back, or abort the sweep.
  # Same reasoning the device revival audit trigger already carries: an audit
  # that can reject the operation it observes gives somebody a motive to switch
  # it off, and the bypass becomes the default. A missing diagnostic beats a
  # blocked reconciliation.
  defp record_run(context, status, stats, acc, error) do
    actor = SystemActor.system(:identity_reconciliation)

    attrs =
      stats
      |> Map.delete(:duration_ms)
      |> Map.merge(%{
        run_id: context.run_id,
        started_at: context.started_at,
        completed_at: DateTime.utc_now(),
        duration_ms: stats.duration_ms,
        status: status,
        error_summary: error_summary(error),
        blocked_component_devices: acc.blocked_component_devices,
        trigger: context.trigger,
        job_schedule_id: context.job_schedule_id
      })

    ReconciliationRun.record(attrs, actor: actor)
    prune_run_records(actor)
    :ok
  rescue
    write_error ->
      Logger.warning(
        "Failed to record identity reconciliation run #{context.run_id}: #{inspect(write_error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Failed to record identity reconciliation run #{context.run_id}: #{inspect({kind, reason})}"
      )

      :ok
  end

  # Neither the event nor the gauges can fail the run: a telemetry handler that raises is
  # detached, and the gauges rescue their own reads.
  defp report_run(context, status, stats) do
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :run],
      Map.take(stats, @run_measurements),
      %{status: status, trigger: context.trigger}
    )

    PopulationGauges.emit_inventory()
  end

  defp prune_run_records(actor) do
    cutoff = DateTime.shift(DateTime.utc_now(), day: -run_retention_days())

    ReconciliationRun
    |> Ash.Query.for_read(:older_than, %{cutoff: cutoff}, actor: actor)
    |> Ash.bulk_destroy(:destroy, %{},
      actor: actor,
      strategy: [:atomic, :stream],
      return_errors?: false,
      stop_on_error?: false
    )

    :ok
  end

  defp error_summary(nil), do: nil

  defp error_summary(error) when is_exception(error) do
    error |> Exception.message() |> truncate_summary()
  end

  defp error_summary(error), do: error |> inspect() |> truncate_summary()

  defp truncate_summary(text) when byte_size(text) <= 2_000, do: text
  defp truncate_summary(text), do: binary_part(text, 0, 2_000) <> "..."

  @doc false
  def normalize_trigger(:manual), do: :manual
  def normalize_trigger("manual"), do: :manual
  def normalize_trigger(_), do: :scheduled

  # The scheduled job runs every few minutes; cap the database work performed
  # by one run. This is an operational bound, not an identity-safety control:
  # evidence validation above must make every merge safe before it reaches the
  # cap.
  defp default_max_merges do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_merges_per_run, 200)
  end

  # Retention for the run records. A few hundred rows a day at the current
  # cadence; unbounded growth in a diagnostics table is how a diagnostic becomes
  # an incident.
  defp run_retention_days do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:run_retention_days, 30)
  end

  # How many blocked components a single run record captures membership for.
  defp blocked_component_capture_limit do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:blocked_component_capture_limit, 100)
  end

  # How long an unchanged blocked component is skipped before it is evaluated again anyway
  # (`BlockFingerprint.recorded/2`). The bound covers what the fingerprint cannot see: an input
  # it misses, or a change between the read and the attempt.
  defp blocked_recheck_seconds do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:blocked_recheck_seconds, 86_400)
  end

  @doc false
  def normalize_max_merges(n) when is_integer(n) and n > 0, do: n
  def normalize_max_merges(_), do: default_max_merges()

  @doc false
  def merge_cap_reached?(max_merges, count)
      when is_integer(max_merges) and max_merges > 0 and is_integer(count) do
    count >= max_merges
  end

  def merge_cap_reached?(_max_merges, _count), do: false

  # Duplicate identifier groups straight from the database: one row per
  # (type, value, partition) mapped to more than one device. Excludes
  # service-component devices, malformed MAC values, and locally-administered
  # MACs (medium confidence must never merge devices on its own).
  defp duplicate_identifier_groups do
    import Ecto.Query

    # identifier_type is an Ash.Type.Atom enum column, so the query must use
    # atoms — passing strings makes Ecto fail to dump them to the EctoType.
    types = automatic_merge_identifier_types()

    query =
      from(di in DeviceIdentifier,
        where: di.identifier_type in ^types,
        where: not like(di.device_id, "serviceradar:%"),
        where:
          di.identifier_type != :mac or
            fragment("? ~ '^[0-9A-F]{12}$'", di.identifier_value),
        group_by: [di.identifier_type, di.identifier_value, di.partition],
        having: count(fragment("DISTINCT ?", di.device_id)) > 1,
        select:
          {di.identifier_type, di.identifier_value, di.partition,
           fragment("array_agg(DISTINCT ?)", di.device_id)}
      )

    query
    |> ServiceRadar.Repo.all()
    |> Enum.reject(fn {type, value, _partition, _ids} ->
      to_string(type) == "mac" and Mac.locally_administered_mac?(value)
    end)
    |> Enum.map(fn {type, value, partition, device_ids} ->
      {{partition, type, value}, MapSet.new(device_ids)}
    end)
  end

  # Live devices reciprocally owned by the SAME agent are the same host.
  #
  # `ocsf_devices.agent_id` is the reciprocal anchor `AgentAnchor` documents as
  # authoritative: it names the agent whose host this device IS, and an agent runs on
  # exactly one host. It is emphatically NOT "discovered by" -- a sweeping agent leaves
  # it null on every device it merely observed.
  #
  # This grouping is needed because the anchor lives in two places and the identifier
  # scan above only sees one of them. A device row can carry the `agent_id` COLUMN
  # while having no `agent_id` identifier row (rows predating identifier registration
  # never got backfilled). When such a host's IP changed, the resolver found no
  # matching identifier, minted a NEW device, and anchored that one -- leaving two live
  # devices for one machine, permanently, because they shared no identifier value for
  # the sweep to group on.
  defp agent_anchor_sibling_groups do
    import Ecto.Query

    from(d in Device,
      where: not is_nil(d.agent_id),
      where: d.agent_id != "",
      # A tombstoned device is not an anchor.
      where: is_nil(d.deleted_at),
      where: not like(d.uid, "serviceradar:%"),
      select: {d.agent_id, d.uid}
    )
    |> ServiceRadar.Repo.all()
    |> Enum.group_by(fn {agent_id, _uid} -> agent_id end, fn {_agent_id, uid} -> uid end)
    |> Enum.filter(fn {_agent_id, uids} -> uids |> Enum.uniq() |> length() > 1 end)
    |> Enum.map(fn {agent_id, uids} -> {{:agent_id, agent_id}, MapSet.new(uids)} end)
  end

  # Same 48-bit station, opposite IEEE local bit (UniFi WAN F4 + SNMP LAN F6).
  # These never share an identifier value, so the exact-value grouping above
  # cannot see them. Pairing is the identity rule, not a one-off merge.
  defp hardware_mac_sibling_groups do
    import Ecto.Query

    rows =
      ServiceRadar.Repo.all(
        from(di in DeviceIdentifier,
          where: di.identifier_type == :mac,
          # Exclude service-component IDs (`serviceradar:core`, …). Inventory
          # devices use `sr:<uuid>` and must remain in this scan.
          where: not like(di.device_id, "serviceradar:%"),
          where: fragment("? ~ '^[0-9A-F]{12}$'", di.identifier_value),
          select: {di.identifier_value, di.device_id, di.partition}
        )
      )

    rows
    |> Enum.group_by(fn {_mac, _device_id, partition} -> partition end)
    |> Enum.flat_map(fn {partition, partition_rows} ->
      hardware_mac_sibling_groups_from_rows(partition, partition_rows)
    end)
  end

  @doc false
  # Pure half of hardware_mac_sibling_groups/0, so the pairing is testable without a
  # database. A pair is keyed by its universally administered member, the lower of the two
  # values, not by whichever row the unordered scan returned first: the key is the
  # component's evidence, which `BlockFingerprint` covers, and a key that followed row order
  # would make a blocked pair look changed between runs.
  @spec hardware_mac_sibling_groups_from_rows(String.t() | nil, [
          {String.t(), String.t(), String.t() | nil}
        ]) :: [{{String.t() | nil, :mac_sibling, String.t()}, MapSet.t()}]
  def hardware_mac_sibling_groups_from_rows(partition, rows) when is_list(rows) do
    by_mac = Map.new(rows, fn {mac, device_id, _partition} -> {mac, device_id} end)

    rows
    |> Enum.reduce({[], MapSet.new()}, fn {mac, device_id, _partition}, {groups, seen} ->
      sibling = Mac.hardware_mac_sibling(mac)

      cond do
        sibling == nil ->
          {groups, seen}

        MapSet.member?(seen, {mac, sibling}) or MapSet.member?(seen, {sibling, mac}) ->
          {groups, seen}

        true ->
          case Map.get(by_mac, sibling) do
            other_id when is_binary(other_id) and other_id != device_id ->
              group =
                {{partition, :mac_sibling, Enum.min([mac, sibling])},
                 MapSet.new([device_id, other_id])}

              {[group | groups], MapSet.put(seen, {mac, sibling})}

            _ ->
              {groups, seen}
          end
      end
    end)
    |> elem(0)
  end

  # A MAC that lives on `ocsf_devices.mac` but is registered to a DIFFERENT
  # device whose CURRENT MAC column still carries the same value. None of the
  # groupings above can see this pair:
  #
  #   * `duplicate_identifier_groups/0` looks for one identifier value owned by
  #     more than one device, which `device_identifiers_unique_identifier_index`
  #     (UNIQUE on identifier_type, identifier_value, partition) makes
  #     impossible -- a second device can never register the same MAC.
  #   * `hardware_mac_sibling_groups/0` pairs two *registered* MACs differing in
  #     the IEEE local bit; here only one side is registered at all.
  #
  # So a device carrying a MAC it never registered stays split from the device
  # that did register it, indefinitely. The current-column corroboration is
  # essential: merge survivors accumulate historical identifiers from every
  # source row, and treating any historical MAC as current creates transitive
  # components of unrelated devices.
  #
  # Same evidence bar as the rest of this module: globally-unique MACs only. A
  # multi-MAC column fails the 12-hex regex and is skipped rather than guessed
  # at, and the merge still goes through MergeEngine's global guards.
  defp column_mac_groups do
    import Ecto.Query

    rows =
      ServiceRadar.Repo.all(
        from(d in Device,
          join: di in DeviceIdentifier,
          on:
            di.identifier_type == :mac and
              fragment("? = upper(translate(?, ':-.', ''))", di.identifier_value, d.mac),
          where: is_nil(d.deleted_at),
          where: not is_nil(d.mac) and d.mac != "",
          where: not like(d.uid, "serviceradar:%"),
          where: not like(di.device_id, "serviceradar:%"),
          join: identifier_owner in Device,
          on: identifier_owner.uid == di.device_id,
          where: is_nil(identifier_owner.deleted_at),
          where: di.device_id != d.uid,
          where: d.partition == identifier_owner.partition,
          where: d.partition == di.partition,
          where:
            fragment(
              "upper(translate(?, ':-.', '')) = upper(translate(?, ':-.', ''))",
              identifier_owner.mac,
              d.mac
            ),
          where: fragment("upper(translate(?, ':-.', '')) ~ '^[0-9A-F]{12}$'", d.mac),
          select:
            {fragment("upper(translate(?, ':-.', ''))", d.mac), d.uid, di.device_id, d.partition,
             identifier_owner.partition, di.partition, identifier_owner.mac}
        )
      )

    column_mac_groups_from_rows(rows)
  end

  @doc false
  # Pure half of column_mac_groups/0, split out so the evidence bar is testable
  # without a database. Locally-administered MACs are rejected here as well as
  # being unreachable through the join today -- a randomized phone MAC must
  # never merge two devices, and that guarantee should not depend on which rows
  # the query happens to return.
  @spec column_mac_groups_from_rows([
          {
            String.t(),
            String.t(),
            String.t(),
            String.t() | nil,
            String.t() | nil,
            String.t() | nil,
            String.t() | nil
          }
        ]) :: [
          {{String.t(), atom(), String.t()}, MapSet.t()}
        ]
  def column_mac_groups_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.flat_map(fn
      {mac, uid, owner, device_partition, owner_partition, identifier_partition, owner_mac} ->
        normalized_mac = Mac.normalize_mac(mac)

        if is_binary(normalized_mac) and
             not Mac.locally_administered_mac?(normalized_mac) and
             same_partition?(device_partition, owner_partition, identifier_partition) and
             Mac.normalize_mac_list(owner_mac) == [normalized_mac] do
          [
            {{normalize_partition(device_partition), :mac_column, normalized_mac},
             MapSet.new([uid, owner])}
          ]
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  defp same_partition?(device_partition, owner_partition, identifier_partition) do
    partition = normalize_partition(device_partition)

    partition == normalize_partition(owner_partition) and
      partition == normalize_partition(identifier_partition)
  end

  defp normalize_partition(partition) when partition in [nil, ""], do: "default"
  defp normalize_partition(partition), do: partition

  # One chassis reached at two addresses becomes two device rows anchored by
  # DIFFERENT interface MACs, so they share no identifier and every other group
  # source here correctly finds nothing. The evidence that they are one device is
  # that one of them reports the other's anchor MAC on its OWN interface table,
  # over authenticated SNMP.
  #
  # This is not "merge on a shared MAC" -- a MAC merely OBSERVED (a neighbour or
  # ARP table entry, especially an interface MAC seen by mapper) is not identity.
  # The distinction is ownership: a neighbour table says what a device can see,
  # an interface table says what it IS.
  #
  # Chosen over calling AliasGuard from BatchResolver, and the measurement is why.
  # On a 126-device deployment that alternative would have merged 6 pairs, and 5
  # of them had NO MAC evidence on either side -- four keyed on a `fe80::`
  # link-local alias, which is not unique beyond a link.
  # `distinct_strong_identity_conflict?/3` cannot stop those: it returns false
  # when either side has no MACs, because unknown is not distinct. This source
  # merges only where positive hardware evidence exists, which on the same
  # deployment was exactly one pair -- the chassis.
  defp interface_mac_chassis_groups do
    import Ecto.Query

    rows =
      ServiceRadar.Repo.all(
        from(im in DeviceInterfaceMac,
          join: di in DeviceIdentifier,
          on: di.identifier_type == :mac and di.identifier_value == im.mac,
          join: owner in Device,
          on: owner.uid == im.device_id and is_nil(owner.deleted_at),
          join: other in Device,
          on: other.uid == di.device_id and is_nil(other.deleted_at),
          where: di.device_id != im.device_id,
          where: not like(im.device_id, "serviceradar:%"),
          where: not like(di.device_id, "serviceradar:%"),
          select: {im.mac, im.device_id, di.device_id, di.partition}
        )
      )

    interface_mac_chassis_groups_from_rows(rows)
  end

  @doc false
  # Pure half of interface_mac_chassis_groups/0, so the evidence bar is testable
  # without a database. Locally-administered MACs are rejected here as well as by
  # the writer: tap/veth/dummy addresses are synthesised, not hardware, and that
  # guarantee must not depend on which rows the query happens to return.
  @spec interface_mac_chassis_groups_from_rows([
          {String.t(), String.t(), String.t(), String.t()}
        ]) :: [{{String.t(), atom(), String.t()}, MapSet.t()}]
  def interface_mac_chassis_groups_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reject(fn {mac, _owner, _other, _partition} ->
      Mac.locally_administered_mac?(mac)
    end)
    |> Enum.map(fn {mac, owner, other, partition} ->
      {{partition, :interface_mac_chassis, mac}, MapSet.new([owner, other])}
    end)
    |> Enum.uniq()
  end

  @doc false
  def automatic_merge_identifier_types do
    Ids.identifier_priority() -- [:hardware_serial]
  end

  @doc false
  # A change to what this classifies as blocked, or to `MergePolicy`, must bump
  # `BlockFingerprint`'s rule version, so that the components blocked under the old rules are
  # evaluated again.
  def classify_duplicate_components(duplicate_entries) when is_list(duplicate_entries) do
    components =
      duplicate_entries
      |> build_duplicate_components()
      |> Enum.filter(&(length(&1.device_ids) > 1))
      |> Enum.sort_by(& &1.device_ids)

    {size_ok, size_blocked} =
      Enum.split_with(components, &(length(&1.device_ids) == 2))

    {policy_ok, policy_blocked} =
      Enum.split_with(size_ok, fn component ->
        matches = Enum.map(component.evidence, &{&1.type, %{value: &1.value}})
        MergePolicy.merge_allowed_for_matches?(matches)
      end)

    %{mergeable: policy_ok, blocked: size_blocked ++ policy_blocked}
  end

  defp build_duplicate_components(duplicate_entries) do
    parents = build_duplicate_parents(duplicate_entries)
    groups = build_duplicate_groups(parents)

    evidence_by_root =
      Enum.reduce(duplicate_entries, %{}, fn {key, device_ids}, acc ->
        ids = device_ids |> MapSet.to_list() |> Enum.sort()

        case List.first(ids) do
          nil ->
            acc

          first ->
            root = find_device_root(parents, first)
            evidence = duplicate_evidence(key, ids)
            Map.update(acc, root, [evidence], &[evidence | &1])
        end
      end)

    Enum.map(groups, fn {root, device_ids} ->
      evidence =
        evidence_by_root
        |> Map.get(root, [])
        |> Enum.uniq()
        |> Enum.sort_by(&evidence_sort_key/1)

      %{device_ids: Enum.sort(device_ids), evidence: evidence}
    end)
  end

  defp duplicate_evidence({partition, type, value}, device_ids) do
    %{partition: partition, type: type, value: value, device_ids: device_ids}
  end

  defp duplicate_evidence({type, value}, device_ids) do
    %{partition: nil, type: type, value: value, device_ids: device_ids}
  end

  defp duplicate_evidence(key, device_ids) do
    %{partition: nil, type: :unknown, value: inspect(key), device_ids: device_ids}
  end

  defp evidence_sort_key(evidence) do
    {to_string(evidence.partition || ""), to_string(evidence.type), to_string(evidence.value)}
  end

  defp build_duplicate_parents(duplicate_entries) do
    Enum.reduce(duplicate_entries, %{}, fn {_key, device_ids}, acc ->
      ids = device_ids |> MapSet.to_list() |> Enum.uniq()
      acc = Enum.reduce(ids, acc, &Map.put_new(&2, &1, &1))
      union_device_group(ids, acc)
    end)
  end

  defp union_device_group([first | rest], acc) do
    Enum.reduce(rest, acc, fn id, parents -> union_devices(parents, first, id) end)
  end

  defp union_device_group(_ids, acc), do: acc

  defp build_duplicate_groups(parents) do
    parents
    |> Map.keys()
    |> Enum.reduce(%{}, fn device_id, acc ->
      root = find_device_root(parents, device_id)
      Map.update(acc, root, [device_id], &[device_id | &1])
    end)
  end

  defp find_device_root(parents, device_id) do
    parent = Map.get(parents, device_id, device_id)

    if parent == device_id do
      device_id
    else
      find_device_root(parents, parent)
    end
  end

  defp union_devices(parents, device_a, device_b) do
    root_a = find_device_root(parents, device_a)
    root_b = find_device_root(parents, device_b)

    if root_a == root_b do
      parents
    else
      Map.put(parents, root_b, root_a)
    end
  end

  # The mergeable components are pairs (`classify_duplicate_components/1`). A pair a guard
  # blocked is skipped while its fingerprint is unchanged: it counts as blocked and unchanged,
  # and is neither attempted nor recorded again. Only a merge counts toward the cap.
  defp merge_components(components, actor, context) do
    counts = %{merges: 0, errors: 0, blocked_merges: 0, blocked_unchanged: 0}

    components
    |> fingerprint_chunks()
    |> Enum.reduce_while(counts, fn chunk, counts ->
      counts =
        chunk
        |> merge_candidates(actor, context.fingerprint_opts)
        |> Enum.reduce_while(counts, &merge_candidate(&1, &2, actor, context.max_merges))

      if merge_cap_reached?(context.max_merges, counts.merges),
        do: {:halt, counts},
        else: {:cont, counts}
    end)
  end

  # The survivor is part of the fingerprint only where the outcome depends on the direction
  # (`BlockFingerprint.directional?/2`); elsewhere it is chosen when the pair is attempted.
  defp merge_candidates(chunk, actor, fingerprint_opts) do
    fingerprint_candidates(chunk, fingerprint_opts, fn component, inputs ->
      survivor =
        if BlockFingerprint.directional?(component.device_ids, inputs),
          do: choose_canonical_device_id(component.device_ids, actor)

      {survivor, pair_block_keys(component.device_ids)}
    end)
  end

  defp pair_block_keys([device_a, device_b]),
    do: MergeEngine.block_decision_keys(device_a, device_b)

  defp pair_block_keys(_device_ids), do: []

  defp merge_candidate(candidate, counts, actor, max_merges) do
    cond do
      merge_cap_reached?(max_merges, counts.merges) ->
        {:halt, counts}

      candidate.unchanged? ->
        {:cont,
         %{
           counts
           | blocked_merges: counts.blocked_merges + 1,
             blocked_unchanged: counts.blocked_unchanged + 1
         }}

      true ->
        {:cont, attempt_merge(candidate, counts, actor, max_merges)}
    end
  end

  defp attempt_merge(%{component: component} = candidate, counts, actor, max_merges) do
    canonical_id = candidate.survivor || choose_canonical_device_id(component.device_ids, actor)

    component.device_ids
    |> Enum.reject(&(&1 == canonical_id))
    |> Enum.reduce_while(counts, fn from_id, counts ->
      if merge_cap_reached?(max_merges, counts.merges) do
        {:halt, counts}
      else
        outcome = merge_component_device(from_id, canonical_id, candidate, actor)
        {:cont, count_merge(outcome, counts)}
      end
    end)
  end

  defp count_merge(:merged, counts), do: %{counts | merges: counts.merges + 1}

  defp count_merge(:blocked, counts), do: %{counts | blocked_merges: counts.blocked_merges + 1}

  defp count_merge(:error, counts), do: %{counts | errors: counts.errors + 1}

  defp merge_component_device(from_id, canonical_id, %{component: component} = candidate, actor) do
    case MergeEngine.merge_devices(from_id, canonical_id,
           actor: actor,
           reason: "identifier_backfill",
           details: %{
             source: "scheduled_reconciliation",
             component_size: length(component.device_ids),
             evidence: component.evidence
           },
           fingerprint: candidate.fingerprint
         ) do
      :ok ->
        :merged

      # A guard refused the merge, before the transaction or under its locks. The engine logged
      # and recorded it; a refusal is the guard working, not a failed merge.
      {:error, {:merge_blocked, _guard}} ->
        :blocked

      {:error, {:source_authority_conflict, _conflict}} ->
        :blocked

      {:error, reason} ->
        Logger.warning(
          "Failed to merge device #{from_id} into #{canonical_id}: #{inspect(reason)}"
        )

        :error
    end
  end

  # Consecutive components holding at most `@fingerprint_chunk_devices` devices together, so
  # that one read covers each chunk. Lazy, so a run that reaches its merge cap reads no further.
  defp fingerprint_chunks(components) do
    Stream.chunk_while(
      components,
      {[], 0},
      fn component, {chunk, size} ->
        devices = length(component.device_ids)

        if chunk != [] and size + devices > @fingerprint_chunk_devices,
          do: {:cont, Enum.reverse(chunk), {[component], devices}},
          else: {:cont, {[component | chunk], size + devices}}
      end,
      fn
        {[], _size} -> {:cont, {[], 0}}
        {chunk, _size} -> {:cont, Enum.reverse(chunk), {[], 0}}
      end
    )
  end

  # Each component of `chunk` with its fingerprint, the keys of the decisions a block of it
  # records, and whether one of them recorded the same fingerprint recently. `prepare` returns
  # the survivor the fingerprint covers (or nil) and the keys. A failed read leaves the chunk
  # without fingerprints, so its components are evaluated and recorded as if new.
  defp fingerprint_candidates(chunk, opts, prepare) do
    inputs = chunk |> Enum.flat_map(& &1.device_ids) |> BlockFingerprint.load()

    candidates =
      Enum.map(chunk, fn component ->
        {survivor, keys} = prepare.(component, inputs)

        fingerprint =
          BlockFingerprint.fingerprint(component, inputs,
            survivor: survivor,
            rule_version: Keyword.get(opts, :rule_version, BlockFingerprint.rule_version())
          )

        %{component: component, survivor: survivor, keys: keys, fingerprint: fingerprint}
      end)

    recorded =
      candidates
      |> Enum.flat_map(& &1.keys)
      |> BlockFingerprint.recorded(Keyword.get(opts, :recheck_seconds, blocked_recheck_seconds()))

    Enum.map(candidates, fn candidate ->
      unchanged? = Enum.any?(candidate.keys, &(Map.get(recorded, &1) == candidate.fingerprint))
      Map.put(candidate, :unchanged?, unchanged?)
    end)
  rescue
    error ->
      Logger.warning(
        "Failed to read the evidence of #{length(chunk)} duplicate component(s); " <>
          "evaluating them as changed: #{inspect(error)}"
      )

      Enum.map(
        chunk,
        &%{component: &1, survivor: nil, keys: [], fingerprint: nil, unchanged?: false}
      )
  end

  @doc false
  # Returns the size of the largest blocked component. It used to return `:ok`,
  # which meant the number was computed for one log line and then discarded --
  # nothing downstream could persist it.
  def report_blocked_components([]), do: 0

  def report_blocked_components(components) do
    blocked_devices = Enum.sum(Enum.map(components, &length(&1.device_ids)))
    largest_component = components |> Enum.map(&length(&1.device_ids)) |> Enum.max()

    Logger.warning(
      "Blocked #{length(components)} ambiguous duplicate components " <>
        "covering #{blocked_devices} devices (largest: #{largest_component})"
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :component, :blocked],
      %{count: length(components), device_count: blocked_devices},
      %{reason: :ambiguous_transitive_component, largest_component: largest_component}
    )

    largest_component
  end

  @doc false
  # Each blocked component is an identity decision the sweep declined (#4613) and a candidate
  # set for a de-duplication task (#4604). Every component is recorded, however many there are:
  # each is one upserted row, so a repeat sweep adds none. Only the run record's membership
  # snapshot is capped.
  #
  # A component recorded recently with the same fingerprint (`BlockFingerprint`) is not
  # recorded again, so the decision's occurrence count measures evidence changes, not runs.
  # Returns the number of such unchanged components. `opts`: `:rule_version` and
  # `:recheck_seconds`.
  def record_blocked_components(components, opts \\ []) when is_list(components) do
    {unchanged, changed} =
      components
      |> fingerprint_chunks()
      |> Enum.flat_map(
        &fingerprint_candidates(&1, opts, fn component, _inputs ->
          {nil, [component_block_key(component)]}
        end)
      )
      |> Enum.split_with(& &1.unchanged?)

    changed
    |> Enum.map(fn %{component: component, fingerprint: fingerprint} ->
      %{
        kind: :component_block,
        reason: @component_block_reason,
        device_uids: component.device_ids,
        source: "duplicate_sweep",
        evidence: component_block_evidence(component, fingerprint)
      }
    end)
    |> DecisionLog.record_many()

    length(unchanged)
  end

  defp component_block_key(component),
    do:
      IdentityDecision.decision_key(
        :component_block,
        @component_block_reason,
        component.device_ids,
        nil
      )

  defp component_block_evidence(component, nil),
    do: %{"component_size" => length(component.device_ids)}

  defp component_block_evidence(component, fingerprint),
    do: %{"component_size" => length(component.device_ids), "fingerprint" => fingerprint}

  @doc false
  # Membership only. The evidence that joins these devices is derived at query
  # time from `device_identifiers` so it stays consistent with the identifiers it
  # describes; snapshotting it here would write N rows per component per run and
  # then drift from the very table it claims to explain.
  def blocked_component_membership(components, capture_limit)
      when is_list(components) and is_integer(capture_limit) and capture_limit > 0 do
    captured = Enum.take(components, capture_limit)
    entries = Enum.map(captured, &%{"device_ids" => &1.device_ids})
    omitted = length(components) - length(captured)

    if omitted > 0 do
      entries ++ [%{"truncated" => true, "omitted_components" => omitted}]
    else
      entries
    end
  end

  defp choose_canonical_device_id(device_ids, actor) do
    candidates = Enum.filter(device_ids, &Ids.serviceradar_uuid?/1)
    candidates = if candidates == [], do: device_ids, else: candidates

    uaa_sibling_survivor(candidates, actor) ||
      Resolver.most_recent_device_id(candidates, actor) ||
      List.first(candidates)
  end

  # A UniFi/SNMP NIC pair must keep the universally-administered MAC as the
  # survivor even if the LAA SNMP sighting is newer.
  defp uaa_sibling_survivor(device_ids, actor) when length(device_ids) == 2 do
    [device_a, device_b] = device_ids
    macs_a = device_macs(device_a, actor)
    macs_b = device_macs(device_b, actor)

    cond do
      not Mac.any_hardware_mac_siblings?(macs_a, macs_b) ->
        nil

      has_universal_mac?(macs_a) and not has_universal_mac?(macs_b) ->
        device_a

      has_universal_mac?(macs_b) and not has_universal_mac?(macs_a) ->
        device_b

      true ->
        nil
    end
  end

  defp uaa_sibling_survivor(_device_ids, _actor), do: nil

  defp has_universal_mac?(macs) do
    Enum.any?(macs, &(not Mac.locally_administered_mac?(&1)))
  end

  defp device_macs(device_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.filter(device_id == ^device_id and identifier_type == :mac)
    |> Ash.read(query_opts)
    |> case do
      {:ok, identifiers} -> Enum.map(identifiers, & &1.identifier_value)
      _ -> []
    end
  rescue
    _ -> []
  end
end
