defmodule ServiceRadar.Inventory.Remediation.AwxProxmoxUnmerge do
  @moduledoc """
  Step `awx-proxmox-unmerge`: the data repair that change `fix-awx-proxmox-guest-binding-evidence`
  left for later (OpenSpec `remediate-awx-proxmox-guest-merges`).

  Before that change an AWX host imported from a Proxmox inventory bound to a guest on node name
  and VMID alone, across clusters that reuse both, and a locally administered MAC counted as
  corroboration. The AWX reconciliation then merged the guest's device, the device holding the
  guest's MACs and the AWX record (`MergeEngine.merge_devices/3`, reason
  `awx_proxmox_network_match`, or `awx_host_network_match` without a guest), so every such merge
  has a reversible merge audit row. The change closed the path; this step undoes what it left.

  1. **Select and confirm.** Every merge audit row of the two AWX reasons is judged by
     `Decisions.awx_merge_evidence/1` on the AWX host ids and Proxmox guest identities each side
     owns. Only a merge proved to join different machines qualifies; anything ambiguous is
     reported and left in place. `Decisions.plan_awx_proxmox_unmerge/3` orders the qualifying
     merges newest first, a merge after the merge that took its survivor away, and reports
     instead of undoing whatever a non-qualifying merge blocks.
  2. **Unmerge.** Each merge is undone by its audit id (`MergeEngine.unmerge_device/2` with
     `:event_id`) in one transaction per merge, after the device rows are locked and the plan is
     rechecked for that merge on the state under the locks. The unmerge writes the `unmerge`
     audit row that arms the merge cooldown for the pair, and the step records the pair as
     distinct (`Deduplication.assert_distinct/4`), which no automatic merge path passes.
  3. **MAC cleanup.** After the unmerges, the MAC identifier rows an AWX update copied from the
     wrong guest onto either record are moved to `device_identifier_archive` with reason
     `awx_wrong_guest_mac` (`Decisions.plan_awx_wrong_guest_macs/1` decides which), and are
     re-queried afterwards.

  Dry run by default and explicit-only: the step is never in the default run, and its execute is
  refused unless the release runtime configuration sets `enable_awx_proxmox_unmerge_execute`.
  Execute writes a synced preflight manifest entry before each transaction, the action entries
  inside it, and a committed marker after it. `source-id-rollback` reverses the actions from that
  manifest, and `awx-proxmox-verify` (`AwxProxmoxVerification`) checks afterwards that the pairs
  stayed apart.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DistinctDeviceAssertion
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "awx-proxmox-unmerge"
  @unmerged_by "dire_remediation:awx-proxmox-unmerge"
  @archive_reason "awx_wrong_guest_mac"
  @default_candidate_limit 5_000
  @default_report_limit 500
  @transaction_resources [Device, DeviceIdentifier, MergeAudit, DistinctDeviceAssertion]

  @doc "The `unmerged_by` the step's unmerge audit rows carry."
  def unmerged_by, do: @unmerged_by

  @doc "The `archive_reason` of the MAC rows the step archives."
  def archive_reason, do: @archive_reason

  @doc false
  def run(mode, opts, manifest, actor) do
    data = load(opts)
    plan = plan(data, opts)
    base = base_report(data, plan, opts)

    case mode do
      :dry_run -> dry_run(data, plan, base, opts)
      :execute -> execute(data, plan, base, opts, manifest, actor)
    end
  end

  # -- planning ---------------------------------------------------------------

  @doc false
  # Everything the plan reads: the AWX merges (newest first, at most the candidate limit), every
  # merge audit row touching their two records, those records, their identifiers, and the guests
  # the merges bound.
  def load(opts) do
    limit = Keyword.get(opts, :awx_proxmox_unmerge_candidate_limit, @default_candidate_limit)

    %{rows: rows} =
      query!(
        """
        SELECT event_id::text, from_device_id, to_device_id, reason, details, created_at
        FROM platform.merge_audit
        WHERE reason = ANY($1::text[])
        ORDER BY created_at DESC NULLS LAST, event_id
        LIMIT $2
        """,
        [Decisions.awx_merge_reasons(), limit + 1]
      )

    awx = rows |> Enum.take(limit) |> Enum.map(&audit_row/1)
    load_around(awx, length(rows) > limit)
  end

  defp load_around(awx, truncated?) do
    uids = awx |> Enum.flat_map(&[&1.from_uid, &1.to_uid]) |> Enum.uniq()
    related = related_merges(uids)
    identifiers = identifiers_by_device(uids)

    guest_refs =
      awx |> Enum.map(& &1.details["guest_provider_ref"]) |> Enum.filter(&is_binary/1)

    merges = Enum.reject(related, &(&1.reason == "unmerge"))

    %{
      awx: awx,
      audits: Map.new(awx, &{&1.event_id, &1}),
      related: related,
      merges_into: Enum.group_by(merges, & &1.to_uid),
      merges_from: Enum.group_by(merges, & &1.from_uid),
      reversed: reversed_event_ids(related),
      devices: devices(uids),
      identifiers: identifiers,
      guests: guests(Enum.uniq(guest_refs)),
      interface_macs: interface_macs(uids),
      truncated?: truncated?
    }
  end

  defp audit_row([event_id, from_uid, to_uid, reason, details, created_at]) do
    %{
      event_id: event_id,
      from_uid: from_uid,
      to_uid: to_uid,
      reason: reason,
      details: details || %{},
      created_at: utc(created_at)
    }
  end

  # `merge_audit.created_at` is a timestamp without a time zone, in UTC; a row without one sorts
  # oldest.
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at
  defp utc(_at), do: ~U[1970-01-01 00:00:00Z]

  defp related_merges([]), do: []

  defp related_merges(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT event_id::text, from_device_id, to_device_id, reason, details, created_at
        FROM platform.merge_audit
        WHERE from_device_id = ANY($1::text[]) OR to_device_id = ANY($1::text[])
        """,
        [uids]
      )

    Enum.map(rows, &audit_row/1)
  end

  defp reversed_event_ids(related) do
    for %{reason: "unmerge", details: details} <- related,
        id = details["original_merge_event_id"],
        is_binary(id),
        into: MapSet.new(),
        do: id
  end

  defp devices([]), do: %{}

  defp devices(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT uid, deleted_at IS NOT NULL, deleted_reason, hostname, ip, mac,
               COALESCE(metadata->'awx', 'null'::jsonb)
        FROM platform.ocsf_devices
        WHERE uid = ANY($1::text[])
        """,
        [uids]
      )

    Map.new(rows, fn [uid, deleted?, deleted_reason, hostname, ip, mac, awx] ->
      {uid,
       %{
         uid: uid,
         deleted?: deleted?,
         deleted_reason: deleted_reason,
         hostname: hostname,
         ip: ip,
         mac: mac,
         awx: if(is_map(awx), do: awx)
       }}
    end)
  end

  defp identifiers_by_device([]), do: %{}

  defp identifiers_by_device(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT id, device_id, identifier_type::text, identifier_value, partition, source,
               metadata->>'integration_type', metadata->>'sync_service_id',
               metadata->>'hypervisor_provider_ref', first_seen, last_seen
        FROM platform.device_identifiers
        WHERE device_id = ANY($1::text[])
        ORDER BY device_id, identifier_type, id
        """,
        [uids]
      )

    rows
    |> Enum.map(fn [
                     id,
                     device_id,
                     type,
                     value,
                     partition,
                     source,
                     itype,
                     sync_id,
                     ref,
                     first,
                     last
                   ] ->
      %{
        id: id,
        device_id: device_id,
        type: type,
        value: value,
        partition: partition,
        source: source,
        integration_type: itype,
        sync_service_id: sync_id,
        reported_guest_ref: ref,
        first_seen: first,
        last_seen: last
      }
    end)
    |> Enum.group_by(& &1.device_id)
  end

  defp guests([]), do: %{}

  defp guests(refs) do
    %{rows: rows} =
      query!(
        """
        SELECT g.provider_ref, g.device_uid,
               COALESCE(
                 ARRAY(
                   SELECT n.mac_address
                   FROM platform.virtualization_network_interfaces n
                   WHERE n.guest_id = g.id
                     AND n.mac_address IS NOT NULL
                     AND btrim(n.mac_address) <> ''
                 ),
                 ARRAY[]::text[]
               )
        FROM platform.virtualization_guests g
        WHERE g.provider_ref = ANY($1::text[])
        """,
        [refs]
      )

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn
      {ref, [[_ref, device_uid, macs]]} ->
        {ref, %{provider_ref: ref, device_uid: device_uid, macs: macs || []}}

      # More than one guest row for one reference: which NICs are the guest's is not known.
      {ref, _several} ->
        {ref, %{provider_ref: ref, device_uid: nil, macs: [], ambiguous?: true}}
    end)
  end

  defp interface_macs([]), do: %{}

  defp interface_macs(uids) do
    %{rows: rows} =
      query!(
        "SELECT device_id, mac FROM platform.device_interface_macs WHERE device_id = ANY($1::text[])",
        [uids]
      )

    Enum.group_by(rows, &hd/1, &List.last/1)
  end

  @doc false
  def plan(data, opts) do
    merges = Enum.map(data.awx, &merge_input(&1, data))

    others =
      for uid <- data.awx |> Enum.map(& &1.to_uid) |> Enum.uniq(),
          merge <- Map.get(data.merges_into, uid, []),
          merge.reason not in Decisions.awx_merge_reasons(),
          not MapSet.member?(data.reversed, merge.event_id),
          do: Map.take(merge, [:event_id, :created_at, :reason, :from_uid, :to_uid])

    Decisions.plan_awx_proxmox_unmerge(merges, others,
      event_ids: Keyword.get(opts, :awx_proxmox_unmerge_event_ids, [])
    )
  end

  defp merge_input(audit, data) do
    from = Map.get(data.devices, audit.from_uid)
    to = Map.get(data.devices, audit.to_uid)
    into_survivor = Map.get(data.merges_into, audit.to_uid, [])

    absorbed_before =
      into_survivor
      |> Enum.filter(
        &(&1.event_id != audit.event_id and
            DateTime.before?(&1.created_at, audit.created_at))
      )
      |> Enum.flat_map(&(source_identifiers(&1.details) || []))

    to_state = to_state(to, data)

    to_own =
      data
      |> own_rows(audit.to_uid, survivor_identifiers(data, audit.to_uid, to_state))
      |> Enum.map(&Map.take(&1, [:type, :value, :partition]))

    %{
      event_id: audit.event_id,
      created_at: audit.created_at,
      reason: audit.reason,
      from_uid: audit.from_uid,
      to_uid: audit.to_uid,
      guest_provider_ref: audit.details["guest_provider_ref"],
      corroboration: audit.details["corroboration"],
      awx_integration_id: audit.details["awx_integration_id"],
      source_identifiers: source_identifiers(audit.details),
      from_mac: from && from.mac,
      to_own_identifiers: to_own,
      to_absorbed_before: absorbed_before,
      to_mac: to && to.mac,
      reversed?: MapSet.member?(data.reversed, audit.event_id),
      from_state: from_state(from),
      superseded?:
        data.merges_from
        |> Map.get(audit.from_uid, [])
        |> Enum.any?(fn other ->
          other.event_id != audit.event_id and
            DateTime.compare(other.created_at, audit.created_at) != :lt
        end),
      to_state: to_state
    }
  end

  # What the survivor holds: its rows, or, once a later merge took it away, what that merge
  # recorded it owned.
  defp survivor_identifiers(data, uid, {:merged, event_id}) do
    data.merges_from
    |> Map.get(uid, [])
    |> Enum.find(&(&1.event_id == event_id))
    |> then(&(source_identifiers(&1.details) || []))
  end

  defp survivor_identifiers(data, uid, _state), do: Map.get(data.identifiers, uid, [])

  defp source_identifiers(details) do
    case details["source_identifiers"] do
      entries when is_list(entries) ->
        for %{} = entry <- entries,
            do: %{type: entry["type"], value: entry["value"], partition: entry["partition"]}

      _ ->
        nil
    end
  end

  defp from_state(nil), do: :missing
  defp from_state(%{deleted?: false}), do: :live
  defp from_state(%{deleted_reason: "merged"}), do: :merged
  defp from_state(_device), do: :deleted

  defp to_state(nil, _data), do: :missing
  defp to_state(%{deleted?: false}, _data), do: :live

  # The survivor's own merge away, the newest one no unmerge reversed.
  defp to_state(%{deleted_reason: "merged", uid: uid}, data) do
    data.merges_from
    |> Map.get(uid, [])
    |> Enum.reject(&MapSet.member?(data.reversed, &1.event_id))
    |> Enum.max_by(&DateTime.to_unix(&1.created_at, :microsecond), fn -> nil end)
    |> case do
      nil -> :deleted
      merge -> {:merged, merge.event_id}
    end
  end

  defp to_state(_device, _data), do: :deleted

  # -- MAC cleanup planning ---------------------------------------------------

  @doc false
  # The MAC rows of the records of every bad merge that is (or, in the dry run, is planned to be)
  # undone, on `rows_by_device` (the current rows, or the dry run's projection of them).
  def plan_macs(data, plan, rows_by_device, scope, opts) do
    selected = opts |> Keyword.get(:awx_proxmox_unmerge_event_ids, []) |> MapSet.new()

    bad =
      Enum.filter(plan.report, fn entry ->
        entry.bad? and entry.disposition in scope and is_binary(guest_ref(entry, data)) and
          (MapSet.size(selected) == 0 or MapSet.member?(selected, entry.event_id))
      end)

    bad
    |> Enum.flat_map(fn entry ->
      ref = guest_ref(entry, data)
      guest = Map.get(data.guests, ref)
      facts = entry.evidence.facts

      for {uid, other_is_guest?} <- [
            {entry.from_uid, facts.to_is_guest},
            {entry.to_uid, facts.guest != nil and MapSet.member?(facts.from_guests, facts.guest)}
          ] do
        {uid, ref, entry.event_id, guest, other_is_guest?}
      end
    end)
    |> Enum.group_by(fn {uid, ref, _event, _guest, _other} -> {uid, ref} end)
    |> Enum.flat_map(fn {{uid, ref}, group} ->
      {_uid, _ref, _event, guest, _other} = hd(group)
      event_ids = group |> Enum.map(&elem(&1, 2)) |> Enum.sort()
      other_is_guest? = Enum.any?(group, &elem(&1, 4))
      plan_device_macs(data, rows_by_device, uid, ref, guest, event_ids, other_is_guest?)
    end)
  end

  defp guest_ref(entry, data) do
    case Map.get(data.audits, entry.event_id) do
      nil -> nil
      audit -> audit.details["guest_provider_ref"]
    end
  end

  defp plan_device_macs(_data, _rows, _uid, ref, nil, event_ids, _other) do
    [%{provider_ref: ref, merge_event_ids: event_ids, skipped: :guest_not_found}]
  end

  defp plan_device_macs(_data, _rows, _uid, ref, %{ambiguous?: true}, event_ids, _other) do
    [%{provider_ref: ref, merge_event_ids: event_ids, skipped: :guest_not_unique}]
  end

  defp plan_device_macs(data, rows_by_device, uid, ref, guest, event_ids, other_is_guest?) do
    rows = Map.get(rows_by_device, uid, [])
    own_rows = own_rows(data, uid, rows)
    device = Map.get(data.devices, uid) || %{}

    input = %{
      guest: %{
        provider_ref: ref,
        key: Decisions.awx_guest_key(ref),
        device_uid: guest.device_uid,
        macs: guest.macs
      },
      device: %{
        uid: uid,
        own_guest_keys: own_guest_keys(own_rows),
        other_side_is_guest?: other_is_guest?,
        interface_macs: Map.get(data.interface_macs, uid, []),
        awx_declared_macs: awx_declared_macs(device[:awx]),
        absorbed_macs: absorbed_macs(data, uid)
      },
      rows: Enum.filter(rows, &(&1.type == "mac"))
    }

    input
    |> Decisions.plan_awx_wrong_guest_macs()
    |> Enum.map(&Map.merge(&1, %{device_uid: uid, provider_ref: ref, merge_event_ids: event_ids}))
  end

  # The record's identifiers that no unreversed merge brought it.
  defp own_rows(data, uid, rows) do
    absorbed =
      data
      |> unreversed_merges_into(uid)
      |> Enum.flat_map(&(source_identifiers(&1.details) || []))
      |> MapSet.new(&{&1.type, &1.value})

    Enum.reject(rows, &MapSet.member?(absorbed, {&1.type, &1.value}))
  end

  defp absorbed_macs(data, uid) do
    for merge <- unreversed_merges_into(data, uid),
        %{type: "mac", value: value} <- source_identifiers(merge.details) || [],
        do: value
  end

  defp unreversed_merges_into(data, uid) do
    data.merges_into
    |> Map.get(uid, [])
    |> Enum.reject(&MapSet.member?(data.reversed, &1.event_id))
  end

  defp own_guest_keys(rows) do
    for %{type: "integration_id", value: value} <- rows,
        key = Decisions.awx_guest_key(value),
        not is_nil(key),
        into: MapSet.new(),
        do: key
  end

  # The MACs the AWX host declares in its own inventory variables (the record's `metadata.awx`),
  # never the MAC list a guest binding added to the update.
  defp awx_declared_macs(awx) when is_map(awx) do
    case HypervisorEnrichmentIngestor.extract_awx_proxmox_info(%{"awx" => awx}) do
      %{macs: macs} -> macs
      _ -> []
    end
  end

  defp awx_declared_macs(_awx), do: []

  # -- dry run ----------------------------------------------------------------

  defp dry_run(data, plan, base, opts) do
    projected =
      data.identifiers
      |> Map.values()
      |> List.flatten()
      |> Decisions.project_awx_unmerges(plan.unmerge)
      |> Enum.group_by(& &1.device_id)

    macs = plan_macs(data, plan, projected, [:unmerge, :already_unmerged], opts)
    Map.merge(base, mac_report(macs, opts))
  end

  defp base_report(data, plan, opts) do
    limit = Keyword.get(opts, :awx_proxmox_unmerge_report_limit, @default_report_limit)
    unmerge_ids = MapSet.new(plan.unmerge, & &1.event_id)
    by_id = Map.new(plan.report, &{&1.event_id, &1})

    unmerge_plan =
      plan.unmerge
      |> Enum.with_index(1)
      |> Enum.map(fn {merge, order} ->
        by_id |> Map.fetch!(merge.event_id) |> describe(data) |> Map.put(:order, order)
      end)

    reported =
      plan.report
      |> Enum.reject(&MapSet.member?(unmerge_ids, &1.event_id))
      |> Enum.sort_by(&{to_string(&1.disposition), &1.event_id})

    %{
      awx_merges: length(data.awx),
      candidate_limit_reached: data.truncated?,
      proved_different_machines: Enum.count(plan.report, & &1.bad?),
      dispositions: Enum.frequencies_by(plan.report, &to_string(&1.disposition)),
      planned_unmerges: length(plan.unmerge),
      unmerge_plan: unmerge_plan,
      reported_merges: reported |> Enum.take(limit) |> Enum.map(&describe(&1, data))
    }
  end

  defp describe(entry, data) do
    details =
      case Map.get(data.audits, entry.event_id) do
        nil -> %{}
        audit -> audit.details
      end

    evidence = entry.evidence
    facts = evidence && evidence.facts

    %{
      event_id: entry.event_id,
      created_at: entry.created_at,
      reason: entry.reason,
      disposition: to_string(entry.disposition),
      blocked_by: entry.blocked_by,
      follows_bad_merges: entry.follows_bad_merges,
      proofs: (evidence && Enum.map(evidence.proofs, &to_string/1)) || [],
      corroboration: details["corroboration"],
      awx_integration_id: details["awx_integration_id"],
      guest_provider_ref: details["guest_provider_ref"],
      guest: facts && render_key(facts.guest),
      from: side(entry.from_uid, data, details, facts, :from),
      to: side(entry.to_uid, data, details, facts, :to)
    }
  end

  defp side(uid, data, details, facts, which) do
    device = Map.get(data.devices, uid) || %{}

    base = %{
      uid: uid,
      hostname: device[:hostname],
      ip: device[:ip],
      deleted_reason: device[:deleted_reason]
    }

    base =
      case which do
        :from ->
          Map.merge(base, %{
            hostname_at_merge: details["from_device_hostname"],
            ip_at_merge: details["from_device_ip"]
          })

        :to ->
          Map.put(base, :ip_before_merge, details["to_device_ip_before"])
      end

    if facts do
      {hosts, guests, macs} =
        case which do
          :from -> {facts.from_awx_hosts, facts.from_guests, facts.from_universal_macs}
          :to -> {facts.to_awx_hosts, facts.to_guests, facts.to_universal_macs}
        end

      Map.merge(base, %{
        awx_hosts: hosts |> Enum.map(fn {c, h} -> "#{c}/#{h}" end) |> Enum.sort(),
        proxmox_guests: guests |> Enum.map(&render_key/1) |> Enum.sort(),
        universal_macs: Enum.sort(macs)
      })
    else
      base
    end
  end

  defp render_key({cluster, vmid}), do: "#{cluster}/#{vmid}"
  defp render_key(_key), do: nil

  defp mac_report(macs, opts) do
    limit = Keyword.get(opts, :awx_proxmox_unmerge_report_limit, @default_report_limit)
    {skipped, rows} = Enum.split_with(macs, &Map.has_key?(&1, :skipped))
    {remove, keep} = Enum.split_with(rows, &(&1.decision == :remove))
    history = archive_history(Enum.map(remove, & &1.value))

    %{
      planned_mac_removals: length(remove),
      mac_rows_kept: Enum.frequencies_by(keep, &to_string(&1.reason)),
      mac_guests_skipped: Enum.frequencies_by(skipped, &to_string(&1.skipped)),
      mac_cleanup_plan: Enum.map(remove, &describe_mac(&1, history)),
      mac_kept_sample: keep |> Enum.take(limit) |> Enum.map(&describe_mac(&1, %{}))
    }
  end

  defp describe_mac(row, history) do
    row
    |> Map.take([
      :id,
      :device_uid,
      :value,
      :partition,
      :source,
      :integration_type,
      :sync_service_id,
      :reported_guest_ref,
      :first_seen,
      :last_seen,
      :provider_ref,
      :merge_event_ids
    ])
    |> Map.merge(%{
      reason: row.reason && to_string(row.reason),
      archive_history: Map.get(history, row.value, [])
    })
  end

  defp archive_history([]), do: %{}

  defp archive_history(values) do
    %{rows: rows} =
      query!(
        """
        SELECT identifier_value, device_id, archive_reason, archived_at
        FROM (
          SELECT a.*, row_number() OVER (
                   PARTITION BY a.identifier_value ORDER BY a.archived_at DESC
                 ) AS position
          FROM platform.device_identifier_archive a
          WHERE a.identifier_type = 'mac' AND a.identifier_value = ANY($1::text[])
        ) history
        WHERE position <= 5
        """,
        [Enum.uniq(values)]
      )

    Enum.group_by(rows, &hd/1, fn [_value, device_id, reason, at] ->
      "#{device_id} #{reason} #{at}"
    end)
  end

  # -- execute ----------------------------------------------------------------

  defp execute(data, plan, base, opts, manifest, actor) do
    cond do
      not execute_enabled?(opts) ->
        blocked(base, :awx_proxmox_unmerge_execute_disabled)

      data.truncated? ->
        blocked(base, :candidate_limit_reached)

      Manifest.ensure_writable(manifest) != :ok ->
        Map.merge(base, %{manifest_failures: 1, halted: "manifest"})

      true ->
        run = %{
          manifest: manifest,
          actor: actor,
          opts: opts,
          manifest_errors: :counters.new(1, [])
        }

        state = Enum.reduce_while(plan.unmerge, initial_state(), &unmerge_one(&1, &2, run))
        state = if state.halted, do: state, else: clean_macs(state, opts, run)

        base
        |> Map.merge(state)
        |> Map.put(:execution_blocked, false)
        |> then(&if(&1.halted, do: &1, else: Map.delete(&1, :halted)))
    end
  end

  defp initial_state do
    %{
      unmerged: 0,
      distinct_asserted: 0,
      unmerge_skipped: %{},
      unmerge_failures: 0,
      mac_rows_archived: 0,
      mac_rows_stale: 0,
      mac_cleanup_failures: 0,
      mac_rows_still_present: 0,
      manifest_failures: 0,
      halted: nil
    }
  end

  defp blocked(base, reason) do
    Map.merge(base, %{
      execution_blocked: true,
      execution_blocked_reason: to_string(reason),
      unmerged: 0,
      mac_rows_archived: 0
    })
  end

  defp execute_enabled?(opts) do
    runtime? =
      :serviceradar_core
      |> Application.get_env(ServiceRadar.Inventory.Remediation.DireRemediation, [])
      |> Keyword.get(:enable_awx_proxmox_unmerge_execute, false)

    runtime? and Keyword.get(opts, :awx_proxmox_unmerge_execute_enabled, false)
  end

  defp unmerge_one(merge, state, run) do
    token = Ecto.UUID.generate()

    preflight =
      Manifest.record(
        run.manifest,
        @step,
        :candidate_preflight,
        "platform.merge_audit",
        [
          merge.event_id
        ],
        %{
          phase: "preflight",
          candidate_token: token,
          from_device_uid: merge.from_uid,
          to_device_uid: merge.to_uid
        }
      )

    with :ok <- preflight,
         {:ok, outcome} <- safely(fn -> unmerge_transaction(merge, token, run) end) do
      case outcome do
        {:unmerged, asserted?} ->
          committed(state, run, merge.event_id, token, fn state ->
            %{
              state
              | unmerged: state.unmerged + 1,
                distinct_asserted: state.distinct_asserted + if(asserted?, do: 1, else: 0)
            }
          end)

        {:refused, reason} ->
          {:cont, skip(state, reason)}
      end
    else
      {:error, reason} ->
        manifest_failure? =
          preflight != :ok or :counters.get(run.manifest_errors, 1) > 0

        Logger.warning("#{@step}: unmerge of #{merge.event_id} failed: #{inspect(reason)}")

        if manifest_failure? do
          {:halt,
           %{
             state
             | unmerge_failures: state.unmerge_failures + 1,
               manifest_failures: state.manifest_failures + 1,
               halted: "manifest"
           }}
        else
          {:cont, %{state | unmerge_failures: state.unmerge_failures + 1}}
        end
    end
  end

  defp committed(state, run, event_id, token, update) do
    state = update.(state)

    case Manifest.record(
           run.manifest,
           @step,
           :candidate_committed,
           "platform.merge_audit",
           [
             event_id
           ],
           %{phase: "committed", candidate_token: token}
         ) do
      :ok ->
        {:cont, state}

      {:error, reason} ->
        Logger.error("#{@step}: #{event_id} committed but its marker failed: #{inspect(reason)}")
        {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
    end
  end

  defp skip(state, reason) do
    %{state | unmerge_skipped: Map.update(state.unmerge_skipped, to_string(reason), 1, &(&1 + 1))}
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  # One transaction per merge: lock both records, recheck the plan for this merge on the state
  # under the locks, undo it by its audit id, record the pair distinct, and write the action entry
  # before commit. A refusal is a value and commits nothing, since nothing was written.
  defp unmerge_transaction(merge, token, run) do
    @transaction_resources
    |> Ash.transact(fn ->
      lock_devices([merge.from_uid, merge.to_uid])

      with :ok <- revalidate(merge, run.opts),
           :ok <- do_unmerge(merge, run.actor),
           {:ok, unmerge_event_id} <- unmerge_event_id(merge.event_id),
           {:ok, assertion_id} <- assert_distinct(merge, run.actor),
           :ok <- record_unmerge(merge, unmerge_event_id, assertion_id, token, run) do
        {:unmerged, not is_nil(assertion_id)}
      else
        {:refused, reason} -> {:refused, reason}
        {:error, _} = error -> error
      end
    end)
    |> case do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, outcome} -> {:ok, outcome}
      {:error, _} = error -> error
    end
  end

  defp lock_devices(uids) do
    query!(
      """
      SELECT uid FROM platform.ocsf_devices
      WHERE uid = ANY($1::text[])
      ORDER BY uid
      FOR NO KEY UPDATE
      """,
      [uids |> Enum.uniq() |> Enum.sort()]
    )
  end

  # The plan for this merge alone, on the state read under the locks: it must still prove two
  # different machines and still be the merge to undo next.
  defp revalidate(merge, opts) do
    %{rows: rows} =
      query!(
        """
        SELECT event_id::text, from_device_id, to_device_id, reason, details, created_at
        FROM platform.merge_audit
        WHERE event_id = CAST($1 AS uuid)
        """,
        [merge.event_id]
      )

    data = load_around(Enum.map(rows, &audit_row/1), false)

    case plan(data, opts) do
      %{unmerge: [%{event_id: id}]} when id == merge.event_id ->
        :ok

      %{report: [entry | _]} ->
        {:refused, entry.disposition || :stale_plan}

      _ ->
        {:refused, :stale_plan}
    end
  end

  defp do_unmerge(merge, actor) do
    case MergeEngine.unmerge_device(merge.from_uid,
           actor: actor,
           unmerged_by: @unmerged_by,
           event_id: merge.event_id
         ) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:refused, reason}
      {:error, _} = error -> error
    end
  end

  defp unmerge_event_id(event_id) do
    case query!(
           """
           SELECT event_id::text FROM platform.merge_audit
           WHERE reason = 'unmerge' AND details->>'original_merge_event_id' = $1
           ORDER BY created_at DESC NULLS LAST
           LIMIT 1
           """,
           [event_id]
         ) do
      %{rows: [[id]]} -> {:ok, id}
      _ -> {:error, :unmerge_audit_missing}
    end
  end

  # The evidence proved two machines, so no automatic merge may join them again; the cooldown
  # the unmerge row arms lasts only a day. An assertion that already existed is left as it is
  # and is not the step's to roll back.
  defp assert_distinct(merge, actor) do
    if Deduplication.asserted_distinct?(merge.from_uid, merge.to_uid) do
      {:ok, nil}
    else
      case Deduplication.assert_distinct(
             merge.from_uid,
             merge.to_uid,
             "AWX/Proxmox guest-binding unmerge of merge #{merge.event_id}",
             actor
           ) do
        {:ok, assertion} -> {:ok, assertion.id}
        {:error, _} = error -> error
      end
    end
  end

  defp record_unmerge(merge, unmerge_event_id, assertion_id, token, run) do
    entry = %{
      action: :awx_unmerge,
      table: "platform.merge_audit",
      ids: [merge.event_id],
      extra: %{
        phase: "prepared",
        candidate_token: token,
        from_device_uid: merge.from_uid,
        to_device_uid: merge.to_uid,
        unmerge_event_id: unmerge_event_id,
        distinct_assertion_id: assertion_id
      }
    }

    case Manifest.record_batch(run.manifest, @step, [entry]) do
      :ok ->
        :ok

      {:error, reason} ->
        :counters.add(run.manifest_errors, 1, 1)
        {:error, {:manifest_prepare_failed, reason}}
    end
  end

  # -- execute: MAC cleanup ---------------------------------------------------

  # After the unmerges, on the state they left: the rows the plan proves came from the wrong guest,
  # archived one record at a time, then re-queried.
  defp clean_macs(state, opts, run) do
    data = load(opts)
    plan = plan(data, opts)
    macs = plan_macs(data, plan, data.identifiers, [:already_unmerged], opts)

    removals =
      macs
      |> Enum.filter(&(Map.get(&1, :decision) == :remove))
      |> Enum.group_by(& &1.device_uid)

    {state, archived_ids} =
      Enum.reduce_while(removals, {state, []}, fn {uid, rows}, {state, ids} ->
        {action, state, archived} = archive_device_macs(uid, rows, state, run)
        {action, {state, archived ++ ids}}
      end)

    still_present = still_present(archived_ids)

    %{
      state
      | mac_rows_still_present: still_present,
        mac_cleanup_failures: state.mac_cleanup_failures + still_present
    }
  end

  defp archive_device_macs(uid, rows, state, run) do
    token = Ecto.UUID.generate()
    ids = Enum.map(rows, & &1.id)

    preflight =
      Manifest.record(
        run.manifest,
        @step,
        :candidate_preflight,
        "platform.device_identifiers",
        ids,
        %{
          phase: "preflight",
          candidate_token: token,
          device_uid: uid
        }
      )

    with :ok <- preflight,
         {:ok, archived} <- safely(fn -> archive_transaction(uid, rows, token, run) end) do
      {action, state} =
        committed(state, run, uid, token, fn state ->
          %{
            state
            | mac_rows_archived: state.mac_rows_archived + length(archived),
              mac_rows_stale: state.mac_rows_stale + length(ids) - length(archived)
          }
        end)

      {action, state, archived}
    else
      {:error, reason} ->
        Logger.warning("#{@step}: MAC cleanup of #{uid} failed: #{inspect(reason)}")

        if preflight != :ok or :counters.get(run.manifest_errors, 1) > 0 do
          state = %{
            state
            | mac_cleanup_failures: state.mac_cleanup_failures + 1,
              manifest_failures: state.manifest_failures + 1,
              halted: "manifest"
          }

          {:halt, state, []}
        else
          {:cont, %{state | mac_cleanup_failures: state.mac_cleanup_failures + 1}, []}
        end
    end
  end

  # Under the record's lock, a row moves only while it is still the AWX-written row of the guest
  # MAC the plan judged; a row that changed since is left and counted as stale.
  defp archive_transaction(uid, rows, token, run) do
    [Device, DeviceIdentifier]
    |> Ash.transact(fn ->
      lock_devices([uid])
      expected = Map.new(rows, &{&1.id, &1.value})

      %{rows: current} =
        query!(
          """
          SELECT id, identifier_value FROM platform.device_identifiers
          WHERE id = ANY($1::bigint[]) AND device_id = $2 AND identifier_type = 'mac'
            AND source = 'sync_ingestor' AND metadata->>'integration_type' = 'awx'
          FOR UPDATE
          """,
          [Map.keys(expected), uid]
        )

      ids = for [id, value] <- current, Map.get(expected, id) == value, do: id

      with ^ids <- archive(uid, ids),
           :ok <- bump_revision(uid, ids, run.actor),
           :ok <- record_archive(uid, rows, ids, token, run) do
        {:ok, ids}
      else
        {:error, _} = error -> error
        moved when is_integer(moved) -> {:error, {:archive_incomplete, moved, length(ids)}}
      end
    end)
    |> case do
      {:ok, {:ok, ids}} -> {:ok, ids}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  defp archive(_uid, []), do: []

  defp archive(uid, ids) do
    moved = SourceRetirement.archive_identifiers(uid, ids, DateTime.utc_now(), @archive_reason)
    if moved == length(ids), do: ids, else: moved
  end

  defp bump_revision(_uid, [], _actor), do: :ok

  defp bump_revision(uid, _ids, actor) do
    with {:ok, %Device{} = device} <- Device.get_by_uid(uid, false, actor: actor),
         {:ok, _} <- Device.bump_identity_revision(device, actor: actor) do
      :ok
    else
      {:error, _} = error -> error
      other -> {:error, {:identity_revision_bump_failed, uid, other}}
    end
  end

  defp record_archive(_uid, _rows, [], _token, _run), do: :ok

  defp record_archive(uid, rows, ids, token, run) do
    moved = Enum.filter(rows, &(&1.id in ids))

    entry = %{
      action: :archive_wrong_guest_mac,
      table: "platform.device_identifiers",
      ids: ids,
      extra: %{
        phase: "prepared",
        candidate_token: token,
        device_uid: uid,
        archive_reason: @archive_reason,
        values: Enum.map(moved, & &1.value),
        provider_refs: moved |> Enum.map(& &1.provider_ref) |> Enum.uniq(),
        merge_event_ids: moved |> Enum.flat_map(& &1.merge_event_ids) |> Enum.uniq()
      }
    }

    case Manifest.record_batch(run.manifest, @step, [entry]) do
      :ok ->
        :ok

      {:error, reason} ->
        :counters.add(run.manifest_errors, 1, 1)
        {:error, {:manifest_prepare_failed, reason}}
    end
  end

  defp still_present([]), do: 0

  defp still_present(ids) do
    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM platform.device_identifiers WHERE id = ANY($1::bigint[])",
        [ids]
      )

    count
  end

  # -- rollback ---------------------------------------------------------------

  @doc """
  Return MAC rows the step archived (`archive_wrong_guest_mac`) to `device_uid`, for
  `source-id-rollback`: each row comes back while it is still archived with the step's reason
  for that record, the record is live, and no record holds its value now. Returns
  `{:ok, returned_ids}`; the others are left.
  """
  @spec restore_archived_macs(String.t(), [integer()]) :: {:ok, [integer()]} | {:error, term()}
  def restore_archived_macs(device_uid, ids) when is_binary(device_uid) and is_list(ids) do
    %{rows: rows} =
      query!(
        """
        WITH returned AS (
          INSERT INTO platform.device_identifiers
            (id, device_id, identifier_type, identifier_value, partition, confidence, source,
             first_seen, last_seen, verified, metadata)
          SELECT a.id, a.device_id, a.identifier_type, a.identifier_value, a.partition,
                 a.confidence, a.source, a.first_seen AT TIME ZONE 'UTC',
                 a.last_seen AT TIME ZONE 'UTC', a.verified, a.metadata
          FROM platform.device_identifier_archive AS a
          JOIN platform.ocsf_devices AS d ON d.uid = a.device_id AND d.deleted_at IS NULL
          WHERE a.id = ANY($2::bigint[]) AND a.device_id = $1 AND a.archive_reason = $3
          ON CONFLICT DO NOTHING
          RETURNING id
        )
        DELETE FROM platform.device_identifier_archive AS a
        USING returned
        WHERE a.id = returned.id
        RETURNING a.id
        """,
        [device_uid, ids, @archive_reason]
      )

    {:ok, rows |> Enum.map(&hd/1) |> Enum.sort()}
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
