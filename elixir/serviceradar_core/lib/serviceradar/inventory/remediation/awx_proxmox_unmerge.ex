defmodule ServiceRadar.Inventory.Remediation.AwxProxmoxUnmerge do
  @moduledoc """
  Step `awx-proxmox-unmerge`: the data repair that change `fix-awx-proxmox-guest-binding-evidence`
  left for later (OpenSpec `remediate-awx-proxmox-guest-merges`).

  Before that change an AWX host imported from a Proxmox inventory bound to a guest on node name
  and VMID alone, across clusters that reuse both, and a locally administered MAC counted as
  corroboration. The AWX reconciliation then merged the guest's device, the device holding the
  guest's MACs and the AWX record (`MergeEngine.merge_devices/3`, reason
  `awx_proxmox_network_match`, or `awx_host_network_match` without a guest). The survivor kept
  the other machine's MACs, addresses and Proxmox references, and went on absorbing correct
  records through other merge paths (`hypervisor_guest_network_match`, `identifier_backfill`,
  ...). Every one of those merges has a reversible merge audit row. The change closed the AWX
  path; this step undoes what the records accumulated.

  1. **Select and confirm, at run time.** The step reads the AWX merges and, around their
     records, every merge of any reason, widening to the records the plan implicates until
     nothing new is implicated. `Decisions.plan_awx_proxmox_unmerge/3` judges them in time order:
     an AWX merge on its own evidence (`Decisions.awx_merge_evidence/1`), and any merge touching
     a record a bad merge poisoned on the chain rule (a second Proxmox guest identity, or match
     evidence that only the poison brought). Anything it cannot prove is reported and left.
  2. **Unmerge, one unit at a time.** The bad merges sharing records form a unit, undone newest
     first in one transaction, after the records are locked and the unit is planned again on the
     state under the locks; a refusal anywhere rolls the whole unit back. Each unmerge
     (`MergeEngine.unmerge_device/2` with `:event_id`) writes the `unmerge` audit row that arms
     the pair's merge cooldown, and the step records the pair as distinct
     (`Deduplication.assert_distinct/4`). Every planned unit ends in one reported outcome
     (applied, skipped with its reason, failed, or not run after a halt), and outcomes that do
     not add up to the planned units fail the run (`unit_accounting_failures`).
  3. **Wrong-guest MACs.** After the unmerges, the MAC rows an AWX update copied from the wrong
     guest (`Decisions.plan_awx_wrong_guest_macs/1`) go back to the guest's own record when
     exactly one live record holds the guest, are archived (`device_identifier_archive`, reason
     `awx_wrong_guest_mac`) when none does, and are kept when several do; moved and archived rows
     are re-queried afterwards.

  Dry run by default and explicit-only: the step is never in the default run, and its execute is
  refused unless the release runtime configuration sets `enable_awx_proxmox_unmerge_execute`.
  Execute writes a synced preflight manifest entry before each transaction, the action entries
  inside it, and a committed marker after it. `source-id-rollback` reverses the actions from that
  manifest, and `awx-proxmox-verify` (`AwxProxmoxVerification`) checks afterwards that the pairs
  stayed apart.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "awx-proxmox-unmerge"
  @unmerged_by "dire_remediation:awx-proxmox-unmerge"
  @archive_reason "awx_wrong_guest_mac"
  @default_candidate_limit 5_000
  @default_report_limit 500
  # The widening stops after this many rounds, or past this many records; the plan is then
  # incomplete (`candidate_limit_reached`) and execute refuses it.
  @max_rounds 8
  @max_records 50_000

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

  # -- loading ----------------------------------------------------------------

  @doc false
  # The AWX merges (newest first, at most the candidate limit), then everything around their
  # records, widened to every record the plan implicates.
  def load(opts) do
    limit = Keyword.get(opts, :awx_proxmox_unmerge_candidate_limit, @default_candidate_limit)

    %{rows: rows} =
      query!(
        """
        SELECT from_device_id, to_device_id
        FROM platform.merge_audit
        WHERE reason = ANY($1::text[])
        ORDER BY created_at DESC NULLS LAST, event_id
        LIMIT $2
        """,
        [Decisions.awx_merge_reasons(), limit + 1]
      )

    rows
    |> Enum.take(limit)
    |> List.flatten()
    |> MapSet.new()
    |> widen(length(rows) > limit, 1)
  end

  defp widen(uids, truncated?, round) do
    data = load_around(MapSet.to_list(uids), truncated?)
    implicated = implicated_records(data)

    wider =
      for merge <- data.merges,
          merge.from_uid in implicated or merge.to_uid in implicated,
          uid <- [merge.from_uid, merge.to_uid],
          into: uids,
          do: uid

    cond do
      MapSet.equal?(wider, uids) -> data
      round >= @max_rounds or MapSet.size(wider) > @max_records -> %{data | truncated?: true}
      true -> widen(wider, truncated?, round + 1)
    end
  end

  defp implicated_records(data) do
    data
    |> plan([])
    |> Map.fetch!(:report)
    |> Enum.flat_map(&[&1.from_uid, &1.to_uid])
    |> MapSet.new()
  end

  defp load_around(uids, truncated?) do
    related = related_merges(uids)
    merges = Enum.reject(related, &(&1.reason == "unmerge"))
    identifiers = identifiers_by_device(uids)

    refs =
      (Enum.flat_map(merges, &merge_guest_refs/1) ++
         for(rows <- Map.values(identifiers), row <- rows, do: row.value))
      |> Enum.filter(&IntegrationIdentity.v3?/1)
      |> Enum.uniq()

    %{
      merges: merges,
      audits: Map.new(merges, &{&1.event_id, &1}),
      merges_into: Enum.group_by(merges, & &1.to_uid),
      merges_from: Enum.group_by(merges, & &1.from_uid),
      reversed: reversed_event_ids(related),
      devices: devices(uids),
      identifiers: identifiers,
      guests: guests(refs),
      interface_macs: interface_macs(uids),
      truncated?: truncated?
    }
  end

  defp merge_guest_refs(merge) do
    named = merge.details["guest_provider_ref"]

    held =
      for %{type: "integration_id", value: value} <- source_identifiers(merge.details) || [],
          do: value

    Enum.filter([named | held], &is_binary/1)
  end

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

  # Each reversed merge's event id with the time of its earliest unmerge.
  defp reversed_event_ids(related) do
    for %{reason: "unmerge", details: details, created_at: at} <- related,
        id = details["original_merge_event_id"],
        is_binary(id),
        reduce: %{} do
      acc -> Map.update(acc, id, at, &Enum.min([&1, at], DateTime))
    end
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
    |> Enum.map(fn [id, device_id, type, value, partition, source, itype, sync, ref, first, last] ->
      %{
        id: id,
        device_id: device_id,
        type: type,
        value: value,
        partition: partition,
        source: source,
        integration_type: itype,
        sync_service_id: sync,
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
               ),
               COALESCE(
                 ARRAY(
                   SELECT split_part(nic_ip.value, '/', 1)
                   FROM platform.virtualization_network_interfaces n,
                        unnest(n.ip_addresses) AS nic_ip(value)
                   WHERE n.guest_id = g.id
                 ),
                 ARRAY[]::text[]
               )
        FROM platform.virtualization_guests g
        WHERE g.provider_ref = ANY($1::text[])
        """,
        [refs]
      )

    holders = guest_holders(refs)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn
      {ref, [[_ref, device_uid, macs, ips]]} ->
        {ref,
         %{
           provider_ref: ref,
           key: Decisions.awx_guest_key(ref),
           device_uid: device_uid,
           macs: macs || [],
           ips: ips || [],
           holders: Map.get(holders, ref, [])
         }}

      # More than one guest row for one reference: which NICs are the guest's is not known.
      {ref, _several} ->
        {ref,
         %{
           provider_ref: ref,
           key: Decisions.awx_guest_key(ref),
           device_uid: nil,
           macs: [],
           ips: [],
           holders: [],
           ambiguous?: true
         }}
    end)
  end

  # The live records holding each guest's identity: its reference, or a v2 id of the same
  # normalized cluster and VMID.
  defp guest_holders(refs) do
    values = Map.new(refs, &{&1, guest_identity_values(&1)})

    %{rows: rows} =
      query!(
        """
        SELECT di.identifier_value, di.device_id
        FROM platform.device_identifiers di
        JOIN platform.ocsf_devices d ON d.uid = di.device_id AND d.deleted_at IS NULL
        WHERE di.identifier_type = 'integration_id'
          AND di.identifier_value = ANY($1::text[])
        """,
        [values |> Map.values() |> List.flatten() |> Enum.uniq()]
      )

    by_value = Enum.group_by(rows, &hd/1, &List.last/1)

    Map.new(values, fn {ref, candidates} ->
      {ref, candidates |> Enum.flat_map(&Map.get(by_value, &1, [])) |> Enum.uniq()}
    end)
  end

  defp guest_identity_values(ref) do
    case Decisions.awx_guest_key(ref) do
      {cluster, vmid} ->
        v2 =
          for kind <- ["vm", "lxc"],
              id = IntegrationIdentity.proxmox_guest_id(cluster, kind, vmid),
              is_binary(id),
              do: id

        Enum.uniq([ref | v2])

      nil ->
        [ref]
    end
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

  # -- planning ---------------------------------------------------------------

  @doc false
  def plan(data, opts) do
    merges = Enum.map(data.merges, &merge_input(&1, data))

    context = %{
      own:
        Map.new(data.devices, fn {uid, device} ->
          {uid, own_identifiers(data, uid, device)}
        end),
      display_mac: Map.new(data.devices, fn {uid, device} -> {uid, device.mac} end),
      guests: data.guests
    }

    Decisions.plan_awx_proxmox_unmerge(merges, context,
      event_ids: Keyword.get(opts, :awx_proxmox_unmerge_event_ids, [])
    )
  end

  defp guest_macs(guests, ref) do
    case Map.get(guests, ref) do
      %{macs: macs} -> macs
      _none -> []
    end
  end

  defp reversed_by?(data, event_id, at) do
    case Map.fetch(data.reversed, event_id) do
      {:ok, unmerged_at} -> DateTime.compare(unmerged_at, at) != :gt
      :error -> false
    end
  end

  defp merge_input(audit, data) do
    from = Map.get(data.devices, audit.from_uid)
    to = Map.get(data.devices, audit.to_uid)

    absorbed_before =
      data.merges_into
      |> Map.get(audit.to_uid, [])
      |> Enum.filter(
        &(&1.event_id != audit.event_id and
            DateTime.compare(&1.created_at, audit.created_at) != :gt and
            not reversed_by?(data, &1.event_id, audit.created_at))
      )
      |> Enum.flat_map(&(source_identifiers(&1.details) || []))

    %{
      event_id: audit.event_id,
      created_at: audit.created_at,
      reason: audit.reason,
      from_uid: audit.from_uid,
      to_uid: audit.to_uid,
      guest_provider_ref: audit.details["guest_provider_ref"],
      corroboration: audit.details["corroboration"],
      awx_integration_id: audit.details["awx_integration_id"],
      evidence: recorded_evidence(audit.details["evidence"]),
      from_ip: audit.details["from_device_ip"],
      to_ip_before: audit.details["to_device_ip_before"],
      source_identifiers: source_identifiers(audit.details),
      from_mac: from && from.mac,
      to_own_identifiers: own_identifiers(data, audit.to_uid, to),
      to_absorbed_before: absorbed_before,
      to_mac: to && to.mac,
      guest_macs: guest_macs(data.guests, audit.details["guest_provider_ref"]),
      unmerged_at: Map.get(data.reversed, audit.event_id),
      from_state: from_state(from),
      superseded?:
        data.merges_from
        |> Map.get(audit.from_uid, [])
        |> Enum.any?(fn other ->
          other.event_id != audit.event_id and
            DateTime.compare(other.created_at, audit.created_at) != :lt
        end),
      to_state: to_state(to, data)
    }
  end

  defp recorded_evidence(entries) when is_list(entries), do: Enum.filter(entries, &is_map/1)
  defp recorded_evidence(_entries), do: nil

  # A record's own identifiers: what it holds, or once a merge took it away what that merge
  # recorded it owned, less what unreversed merges brought it.
  defp own_identifiers(_data, _uid, nil), do: []

  defp own_identifiers(data, uid, device) do
    rows =
      case to_state(device, data) do
        {:merged, event_id} ->
          data.audits |> Map.fetch!(event_id) |> then(&(source_identifiers(&1.details) || []))

        _state ->
          Map.get(data.identifiers, uid, [])
      end

    data
    |> own_rows(uid, rows)
    |> Enum.map(&Map.take(&1, [:type, :value, :partition]))
  end

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
    |> Enum.reject(&Map.has_key?(data.reversed, &1.event_id))
    |> Enum.max_by(&DateTime.to_unix(&1.created_at, :microsecond), fn -> nil end)
    |> case do
      nil -> :deleted
      merge -> {:merged, merge.event_id}
    end
  end

  defp to_state(_device, _data), do: :deleted

  # The record's identifiers that no unreversed merge brought it: a merge brought the row of the
  # `{type, value, partition}` it recorded, any partition when it recorded none.
  defp own_rows(data, uid, rows) do
    absorbed =
      data
      |> unreversed_merges_into(uid)
      |> Enum.flat_map(&(source_identifiers(&1.details) || []))
      |> MapSet.new(&{&1.type, &1.value, &1.partition})

    Enum.reject(rows, fn row ->
      MapSet.member?(absorbed, {row.type, row.value, row[:partition]}) or
        MapSet.member?(absorbed, {row.type, row.value, nil})
    end)
  end

  defp unreversed_merges_into(data, uid) do
    data.merges_into
    |> Map.get(uid, [])
    |> Enum.reject(&Map.has_key?(data.reversed, &1.event_id))
  end

  # -- MAC planning -----------------------------------------------------------

  @doc false
  # The guest MAC rows on both records of every bad merge that is (or, in the dry run, will be)
  # undone, judged on `rows_by_device` (the current rows, or the dry run's projection of them).
  def plan_macs(data, plan, rows_by_device, scope, opts) do
    selected = selected_events(plan, opts)
    holders = guest_holder_index(data, rows_by_device)

    plan.report
    |> Enum.filter(fn entry ->
      entry.bad? and entry.disposition in scope and
        (selected == :all or MapSet.member?(selected, entry.event_id))
    end)
    |> Enum.flat_map(fn entry ->
      audit = Map.fetch!(data.audits, entry.event_id)

      for ref <- Enum.uniq(merge_guest_refs(audit)),
          uid <- [entry.from_uid, entry.to_uid],
          do: {uid, ref, entry.event_id}
    end)
    |> Enum.group_by(fn {uid, ref, _event} -> {uid, ref} end, &elem(&1, 2))
    |> Enum.flat_map(fn {{uid, ref}, event_ids} ->
      plan_device_macs(data, rows_by_device, holders, {uid, ref}, Enum.sort(event_ids))
    end)
  end

  # Selection names merges; a unit runs whole, so every merge of a selected unit counts.
  defp selected_events(plan, opts) do
    case Keyword.get(opts, :awx_proxmox_unmerge_event_ids, []) do
      [] ->
        :all

      ids ->
        units =
          for entry <- plan.report,
              entry.event_id in ids,
              entry.unit,
              into: MapSet.new(),
              do: entry.unit

        for entry <- plan.report,
            entry.event_id in ids or entry.unit in units,
            into: MapSet.new(),
            do: entry.event_id
    end
  end

  defp plan_device_macs(data, rows_by_device, holder_index, {uid, ref}, event_ids) do
    case Map.get(data.guests, ref) do
      nil ->
        []

      %{ambiguous?: true} ->
        [%{provider_ref: ref, merge_event_ids: event_ids, skipped: :guest_not_unique}]

      guest ->
        rows = Map.get(rows_by_device, uid, [])
        device = Map.get(data.devices, uid) || %{}
        # The records holding the guest's identity: among the loaded ones as the unmerges leave
        # them, and any other live record that holds its reference.
        others = Enum.reject(guest.holders, &Map.has_key?(data.devices, &1))
        holders = Enum.uniq(Map.get(holder_index, guest.key, []) ++ others)

        input = %{
          guest: %{
            provider_ref: ref,
            key: guest.key,
            device_uid: guest.device_uid,
            macs: guest.macs,
            record_uid: single(holders -- [uid]),
            record_ambiguous?: length(holders -- [uid]) > 1
          },
          device: %{
            uid: uid,
            own_guest_keys: own_guest_keys(rows),
            other_side_is_guest?: Enum.any?(holders, &(&1 != uid)),
            interface_macs: Map.get(data.interface_macs, uid, []),
            awx_declared_macs: awx_declared_macs(device[:awx]),
            absorbed_macs: absorbed_macs(data, uid)
          },
          rows: Enum.filter(rows, &(&1.type == "mac"))
        }

        input
        |> Decisions.plan_awx_wrong_guest_macs()
        |> Enum.map(
          &Map.merge(&1, %{device_uid: uid, provider_ref: ref, merge_event_ids: event_ids})
        )
    end
  end

  defp single([one]), do: one
  defp single(_none_or_several), do: nil

  # Per guest identity, the loaded live records whose rows hold it as the unmerges leave them (on
  # `rows_by_device`, so in the dry run the records the unmerges will restore), a key a merge that
  # stays brought included.
  defp guest_holder_index(data, rows_by_device) do
    for {uid, rows} <- rows_by_device,
        live_after_unmerge?(data, uid, rows),
        key <- own_guest_keys(rows),
        reduce: %{} do
      index -> Map.update(index, key, [uid], &[uid | &1])
    end
  end

  # A record holding rows is live, or a merged tombstone the dry run's projection gives rows back.
  defp live_after_unmerge?(data, uid, rows) do
    case Map.get(data.devices, uid) do
      %{deleted?: false} -> true
      %{deleted_reason: "merged"} -> rows != []
      _other -> false
    end
  end

  defp absorbed_macs(data, uid) do
    for merge <- unreversed_merges_into(data, uid),
        %{type: "mac", value: value} <- source_identifiers(merge.details) || [],
        do: value
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

  # -- report -----------------------------------------------------------------

  defp dry_run(data, plan, base, opts) do
    projected =
      data.identifiers
      |> Map.values()
      |> List.flatten()
      |> Decisions.project_awx_unmerges(plan.unmerge)
      |> Enum.group_by(& &1.device_id)

    now = DateTime.utc_now()

    after_unmerges = %{
      data
      | reversed: Map.merge(data.reversed, Map.new(plan.unmerge, &{&1.event_id, now}))
    }

    macs = plan_macs(after_unmerges, plan, projected, [:unmerge, :already_unmerged], opts)
    Map.merge(base, mac_report(macs, opts))
  end

  defp base_report(data, plan, opts) do
    limit = Keyword.get(opts, :awx_proxmox_unmerge_report_limit, @default_report_limit)
    by_id = Map.new(plan.report, &{&1.event_id, &1})
    planned = MapSet.new(plan.unmerge, & &1.event_id)

    units =
      plan.units
      |> Enum.with_index(1)
      |> Enum.map(fn {unit, order} ->
        %{
          order: order,
          unit: unit.id,
          merges: Enum.map(unit.event_ids, &describe(Map.fetch!(by_id, &1), data))
        }
      end)

    reported =
      plan.report
      |> Enum.reject(&MapSet.member?(planned, &1.event_id))
      |> Enum.sort_by(&{to_string(&1.disposition), &1.event_id})

    %{
      merges_read: length(data.merges),
      candidate_limit_reached: data.truncated?,
      proved_different_machines: Enum.count(plan.report, & &1.bad?),
      dispositions: Enum.frequencies_by(plan.report, &to_string(&1.disposition)),
      planned_units: length(plan.units),
      planned_unmerges: length(plan.unmerge),
      unmerge_plan: units,
      reported_merges: reported |> Enum.take(limit) |> Enum.map(&describe(&1, data))
    }
  end

  defp describe(entry, data) do
    details =
      case Map.get(data.audits, entry.event_id) do
        nil -> %{}
        audit -> audit.details
      end

    facts = entry.evidence && entry.evidence.facts

    %{
      event_id: entry.event_id,
      created_at: entry.created_at,
      reason: entry.reason,
      disposition: to_string(entry.disposition),
      unit: entry.unit,
      blocked_by: entry.blocked_by,
      proofs: Enum.map(entry.proofs, &to_string/1),
      match_evidence: entry.match_evidence,
      corroboration: details["corroboration"],
      awx_integration_id: details["awx_integration_id"],
      guest_provider_ref: details["guest_provider_ref"],
      recorded_evidence: details["evidence"],
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
      Map.put(base, :proxmox_guests, guest_keys_of(uid, data))
    end
  end

  defp guest_keys_of(uid, data) do
    case Map.get(data.devices, uid) do
      nil ->
        []

      device ->
        data
        |> own_identifiers(uid, device)
        |> own_guest_keys()
        |> Enum.map(&render_key/1)
        |> Enum.sort()
    end
  end

  defp render_key({cluster, vmid}), do: "#{cluster}/#{vmid}"
  defp render_key(_key), do: nil

  defp mac_report(macs, opts) do
    limit = Keyword.get(opts, :awx_proxmox_unmerge_report_limit, @default_report_limit)
    {skipped, rows} = Enum.split_with(macs, &Map.has_key?(&1, :skipped))
    {act, keep} = Enum.split_with(rows, &(&1.decision in [:move, :remove]))
    history = archive_history(Enum.map(act, & &1.value))

    %{
      planned_mac_moves: Enum.count(act, &(&1.decision == :move)),
      planned_mac_removals: Enum.count(act, &(&1.decision == :remove)),
      mac_rows_kept: Enum.frequencies_by(keep, &to_string(&1.reason)),
      mac_guests_skipped: Enum.frequencies_by(skipped, &to_string(&1.skipped)),
      mac_cleanup_plan: Enum.map(act, &describe_mac(&1, history)),
      mac_kept_sample: keep |> Enum.take(limit) |> Enum.map(&describe_mac(&1, %{}))
    }
  end

  defp describe_mac(row, history) do
    row
    |> Map.take([
      :id,
      :device_uid,
      :target_uid,
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
      decision: to_string(row.decision),
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

        merges = Map.new(plan.unmerge, &{&1.event_id, &1})

        state =
          plan.units
          |> Enum.map(fn unit -> Enum.map(unit.event_ids, &Map.fetch!(merges, &1)) end)
          |> run_units(initial_state(), run)
          |> check_unit_accounting(length(plan.units))

        state = if state.halted, do: state, else: clean_macs(state, opts, run)

        base
        |> Map.merge(state)
        |> Map.put(:execution_blocked, false)
        |> then(&if(&1.halted, do: &1, else: Map.delete(&1, :halted)))
    end
  end

  defp initial_state do
    %{
      units_applied: 0,
      unmerged: 0,
      distinct_asserted: 0,
      units_skipped: %{},
      skipped_units: [],
      unit_failures: 0,
      units_not_run: 0,
      unit_accounting_failures: 0,
      mac_rows_moved: 0,
      mac_rows_archived: 0,
      mac_rows_stale: 0,
      mac_cleanup_failures: 0,
      mac_rows_not_settled: 0,
      manifest_failures: 0,
      halted: nil
    }
  end

  defp blocked(base, reason) do
    Map.merge(base, %{
      execution_blocked: true,
      execution_blocked_reason: to_string(reason),
      unmerged: 0,
      mac_rows_moved: 0,
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

  # Units in plan order. Each ends in exactly one outcome: applied, skipped (with its reason),
  # failed, or not run because an earlier unit halted the step.
  defp run_units([], state, _run), do: state

  defp run_units([merges | rest], state, run) do
    case unmerge_unit(merges, state, run) do
      {:cont, state} -> run_units(rest, state, run)
      {:halt, state} -> %{state | units_not_run: length(rest)}
    end
  end

  # Every planned unit must be counted once; a gap is a defect of the step and fails the run.
  defp check_unit_accounting(state, planned) do
    skipped = state.units_skipped |> Map.values() |> Enum.sum()
    accounted = state.units_applied + skipped + state.unit_failures + state.units_not_run

    if accounted == planned do
      state
    else
      Logger.error(
        "#{@step}: #{planned} unit(s) planned but #{accounted} accounted for " <>
          "(applied #{state.units_applied}, skipped #{skipped}, failed #{state.unit_failures}, " <>
          "not run #{state.units_not_run})"
      )

      %{state | unit_accounting_failures: 1}
    end
  end

  defp unmerge_unit(merges, state, run) do
    token = Ecto.UUID.generate()
    event_ids = Enum.map(merges, & &1.event_id)

    preflight =
      Manifest.record(
        run.manifest,
        @step,
        :candidate_preflight,
        "platform.merge_audit",
        event_ids,
        %{
          phase: "preflight",
          candidate_token: token,
          pairs: Enum.map(merges, &%{from_device_uid: &1.from_uid, to_device_uid: &1.to_uid})
        }
      )

    with :ok <- preflight,
         {:ok, asserted} <- safely(fn -> unit_transaction(merges, token, run) end) do
      committed(state, run, event_ids, token, fn state ->
        %{
          state
          | units_applied: state.units_applied + 1,
            unmerged: state.unmerged + length(merges),
            distinct_asserted: state.distinct_asserted + asserted
        }
      end)
    else
      {:error, {:refused, reason, replanned}} ->
        {:cont, skip(state, event_ids, reason, replanned)}

      {:error, reason} ->
        Logger.warning("#{@step}: unit #{inspect(event_ids)} failed: #{inspect(reason)}")
        failure(state, run, preflight, :unit_failures)
    end
  end

  defp failure(state, run, preflight, counter) do
    state = Map.update!(state, counter, &(&1 + 1))

    if preflight != :ok or :counters.get(run.manifest_errors, 1) > 0 do
      {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
    else
      {:cont, state}
    end
  end

  defp committed(state, run, ids, token, update) do
    state = update.(state)

    case Manifest.record(
           run.manifest,
           @step,
           :candidate_committed,
           "platform.merge_audit",
           ids,
           %{
             phase: "committed",
             candidate_token: token
           }
         ) do
      :ok ->
        {:cont, state}

      {:error, reason} ->
        Logger.error(
          "#{@step}: #{inspect(ids)} committed but its marker failed: #{inspect(reason)}"
        )

        {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
    end
  end

  defp skip(state, event_ids, reason, replanned) do
    Logger.warning(
      "#{@step}: unit #{inspect(event_ids)} skipped and rolled back: #{reason}" <>
        if(replanned == %{}, do: "", else: ", planned again as #{inspect(replanned)}")
    )

    %{
      state
      | units_skipped: Map.update(state.units_skipped, to_string(reason), 1, &(&1 + 1)),
        skipped_units:
          state.skipped_units ++
            [%{event_ids: event_ids, reason: to_string(reason), replanned: replanned}]
    }
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  # One transaction per unit: lock every record, plan the unit again on the state under the locks,
  # undo its merges in order and record each pair distinct, and write the action entries before
  # commit. Any refusal rolls back the whole unit, so a chain is never left half undone.
  defp unit_transaction(merges, token, run) do
    Repo.transaction(
      fn ->
        lock_devices(Enum.flat_map(merges, &[&1.from_uid, &1.to_uid]))
        revalidate_unit(merges, run.opts)

        entries =
          Enum.map(merges, fn merge ->
            do_unmerge(merge, run.actor)
            {:ok, unmerge_event_id} = unmerge_event_id(merge.event_id)
            assertion_id = assert_distinct(merge, run.actor)
            unmerge_entry(merge, unmerge_event_id, assertion_id, token)
          end)

        case Manifest.record_batch(run.manifest, @step, entries) do
          :ok ->
            Enum.count(entries, &(&1.extra.distinct_assertion_id != nil))

          {:error, reason} ->
            :counters.add(run.manifest_errors, 1, 1)
            Repo.rollback({:manifest_prepare_failed, reason})
        end
      end,
      timeout: :infinity
    )
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

  # The whole plan computed again, from the same AWX-seeded read as the dry run, on the state read
  # under the unit's locks: it must still hold one runnable unit of exactly these merges. A unit's
  # poison can arrive through merges outside it, so a read of its own records is not enough. This
  # costs one full read per unit.
  #
  # Units share no record and each verdict is judged on the history up to its merge, so the order
  # the units run in is not what changes a unit's plan; a write that landed since the plan (a
  # sync, an operator) is. The unit is then refused: `disposition_changed` when a merge of it is
  # no longer planned for an unmerge, with each merge's disposition now (`unrelated` when it is no
  # longer judged at all), or `unit_changed` when its merges are all still bad but the unit they
  # form differs.
  defp revalidate_unit(merges, opts) do
    ids = merges |> Enum.map(& &1.event_id) |> Enum.sort()
    data = load(opts)
    fresh = plan(data, opts)

    cond do
      data.truncated? ->
        Repo.rollback({:refused, :candidate_limit_reached, %{}})

      Enum.any?(fresh.units, &(Enum.sort(&1.event_ids) == ids)) ->
        :ok

      true ->
        dispositions = Map.new(fresh.report, &{&1.event_id, to_string(&1.disposition)})
        replanned = Map.new(ids, &{&1, Map.get(dispositions, &1, "unrelated")})

        reason =
          if Enum.all?(replanned, fn {_id, disposition} -> disposition == "unmerge" end),
            do: :unit_changed,
            else: :disposition_changed

        Repo.rollback({:refused, reason, replanned})
    end
  end

  defp do_unmerge(merge, actor) do
    case MergeEngine.unmerge_device(merge.from_uid,
           actor: actor,
           unmerged_by: @unmerged_by,
           event_id: merge.event_id
         ) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> Repo.rollback({:refused, reason, %{}})
      {:error, error} -> Repo.rollback({:unmerge_failed, merge.event_id, error})
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
      _ -> Repo.rollback({:unmerge_audit_missing, event_id})
    end
  end

  # The evidence proved two machines, so no automatic merge may join them again; the cooldown
  # the unmerge row arms lasts only a day. An assertion that already existed is left as it is
  # and is not the step's to roll back.
  defp assert_distinct(merge, actor) do
    if Deduplication.asserted_distinct?(merge.from_uid, merge.to_uid) do
      nil
    else
      case Deduplication.assert_distinct(
             merge.from_uid,
             merge.to_uid,
             "AWX/Proxmox guest-binding unmerge of merge #{merge.event_id}",
             actor
           ) do
        {:ok, assertion} -> assertion.id
        {:error, error} -> Repo.rollback({:assert_distinct_failed, merge.event_id, error})
      end
    end
  end

  defp unmerge_entry(merge, unmerge_event_id, assertion_id, token) do
    %{
      action: :awx_unmerge,
      table: "platform.merge_audit",
      ids: [merge.event_id],
      extra: %{
        phase: "prepared",
        candidate_token: token,
        reason: merge.reason,
        from_device_uid: merge.from_uid,
        to_device_uid: merge.to_uid,
        unmerge_event_id: unmerge_event_id,
        distinct_assertion_id: assertion_id
      }
    }
  end

  # -- execute: wrong-guest MACs -----------------------------------------------

  # After the unmerges, on the state they left: each proved row goes to its guest's record or to
  # the archive, one record at a time, and every row acted on is re-queried.
  defp clean_macs(state, opts, run) do
    data = load(opts)
    plan = plan(data, opts)

    groups =
      data
      |> plan_macs(plan, data.identifiers, [:already_unmerged], opts)
      |> Enum.filter(&(Map.get(&1, :decision) in [:move, :remove]))
      |> Enum.group_by(&{&1.device_uid, &1.decision, &1.target_uid})

    {state, done} =
      Enum.reduce_while(groups, {state, []}, fn {{uid, decision, target}, rows}, {state, done} ->
        {action, state, acted} = clean_device_macs(uid, decision, target, rows, state, run)
        {action, {state, acted ++ done}}
      end)

    unsettled = unsettled(done)

    %{
      state
      | mac_rows_not_settled: unsettled,
        mac_cleanup_failures: state.mac_cleanup_failures + unsettled
    }
  end

  defp clean_device_macs(uid, decision, target, rows, state, run) do
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
          device_uid: uid,
          target_uid: target,
          decision: decision
        }
      )

    with :ok <- preflight,
         {:ok, acted} <-
           safely(fn -> mac_transaction(uid, decision, target, rows, token, run) end) do
      counter = if decision == :move, do: :mac_rows_moved, else: :mac_rows_archived

      {action, state} =
        committed(state, run, ids, token, fn state ->
          state
          |> Map.update!(counter, &(&1 + length(acted)))
          |> Map.update!(:mac_rows_stale, &(&1 + length(ids) - length(acted)))
        end)

      {action, state, Enum.map(acted, &{&1, decision, target})}
    else
      {:error, reason} ->
        Logger.warning("#{@step}: MAC cleanup of #{uid} failed: #{inspect(reason)}")
        {action, state} = failure(state, run, preflight, :mac_cleanup_failures)
        {action, state, []}
    end
  end

  # Under the records' locks, a row is acted on only while it is still the guest MAC row the plan
  # judged, with the same provenance; a row that changed since is left and counted as stale.
  defp mac_transaction(uid, decision, target, rows, token, run) do
    Repo.transaction(fn ->
      lock_devices(Enum.reject([uid, target], &is_nil/1))
      expected = Map.new(rows, &{&1.id, {&1.value, &1.integration_type, &1.reported_guest_ref}})

      %{rows: current} =
        query!(
          """
          SELECT id, identifier_value, metadata->>'integration_type',
                 metadata->>'hypervisor_provider_ref'
          FROM platform.device_identifiers
          WHERE id = ANY($1::bigint[]) AND device_id = $2 AND identifier_type = 'mac'
            AND source = 'sync_ingestor'
          FOR UPDATE
          """,
          [Map.keys(expected), uid]
        )

      ids =
        for [id, value, itype, ref] <- current,
            Map.get(expected, id) == {value, itype, ref},
            do: id

      act_on_macs(uid, decision, target, ids, run.actor)
      bump_revision([uid, target], ids, run.actor)

      case record_mac_action(uid, decision, target, rows, ids, token, run) do
        :ok -> ids
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp act_on_macs(_uid, _decision, _target, [], _actor), do: :ok

  defp act_on_macs(uid, :remove, _target, ids, _actor) do
    moved = SourceRetirement.archive_identifiers(uid, ids, DateTime.utc_now(), @archive_reason)
    if moved != length(ids), do: Repo.rollback({:archive_incomplete, moved, length(ids)})
  end

  defp act_on_macs(_uid, :move, target, ids, actor) do
    DeviceIdentifier
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn identifier ->
      case identifier
           |> Ash.Changeset.for_update(:reassign_device, %{device_id: target})
           |> Ash.update(actor: actor) do
        {:ok, _} -> :ok
        {:error, error} -> Repo.rollback({:reassign_failed, identifier.id, error})
      end
    end)
  end

  defp bump_revision(_uids, [], _actor), do: :ok

  defp bump_revision(uids, _ids, actor) do
    for uid <- Enum.reject(uids, &is_nil/1) do
      with {:ok, %Device{} = device} <- Device.get_by_uid(uid, false, actor: actor),
           {:ok, _} <- Device.bump_identity_revision(device, actor: actor) do
        :ok
      else
        other -> Repo.rollback({:identity_revision_bump_failed, uid, other})
      end
    end

    :ok
  end

  defp record_mac_action(_uid, _decision, _target, _rows, [], _token, _run), do: :ok

  defp record_mac_action(uid, decision, target, rows, ids, token, run) do
    acted = Enum.filter(rows, &(&1.id in ids))

    {action, extra} =
      case decision do
        :remove -> {:archive_wrong_guest_mac, %{archive_reason: @archive_reason}}
        :move -> {:reassign_wrong_guest_mac, %{target_uid: target}}
      end

    entry = %{
      action: action,
      table: "platform.device_identifiers",
      ids: ids,
      extra:
        Map.merge(extra, %{
          phase: "prepared",
          candidate_token: token,
          device_uid: uid,
          values: Enum.map(acted, & &1.value),
          provider_refs: acted |> Enum.map(& &1.provider_ref) |> Enum.uniq(),
          merge_event_ids: acted |> Enum.flat_map(& &1.merge_event_ids) |> Enum.uniq()
        })
    }

    case Manifest.record_batch(run.manifest, @step, [entry]) do
      :ok ->
        :ok

      {:error, reason} ->
        :counters.add(run.manifest_errors, 1, 1)
        {:error, {:manifest_prepare_failed, reason}}
    end
  end

  # Re-query: an archived row must be gone from the live table, a moved row on its target.
  defp unsettled([]), do: 0

  defp unsettled(acted) do
    archived = for {id, :remove, _target} <- acted, do: id
    moved = for {id, :move, target} <- acted, do: {id, target}

    %{rows: [[present]]} =
      query!(
        "SELECT count(*) FROM platform.device_identifiers WHERE id = ANY($1::bigint[])",
        [archived]
      )

    %{rows: [[landed]]} =
      query!(
        """
        SELECT count(*)
        FROM platform.device_identifiers di
        JOIN unnest($1::bigint[], $2::text[]) AS m(id, target) ON m.id = di.id
        WHERE di.device_id = m.target
        """,
        [Enum.map(moved, &elem(&1, 0)), Enum.map(moved, &elem(&1, 1))]
      )

    present + length(moved) - landed
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

  @doc """
  Move MAC rows the step reassigned (`reassign_wrong_guest_mac`) from `target_uid` back to
  `device_uid`, for `source-id-rollback`: each row moves while it is still on the target and the
  record is live. Returns `{:ok, returned_ids}`; the others are left.
  """
  @spec return_moved_macs(String.t(), String.t(), [integer()]) ::
          {:ok, [integer()]} | {:error, term()}
  def return_moved_macs(device_uid, target_uid, ids)
      when is_binary(device_uid) and is_binary(target_uid) and is_list(ids) do
    %{rows: rows} =
      query!(
        """
        UPDATE platform.device_identifiers AS di
        SET device_id = $1
        FROM platform.ocsf_devices AS d
        WHERE d.uid = $1 AND d.deleted_at IS NULL
          AND di.id = ANY($3::bigint[]) AND di.device_id = $2
        RETURNING di.id
        """,
        [device_uid, target_uid, ids]
      )

    {:ok, rows |> Enum.map(&hd/1) |> Enum.sort()}
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
