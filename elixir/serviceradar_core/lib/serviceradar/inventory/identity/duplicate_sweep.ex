defmodule ServiceRadar.Inventory.Identity.DuplicateSweep do
  @moduledoc """
  Scheduled duplicate reconciliation: builds identifier/IP indexes,
  union-finds transitive duplicate components, and merges each
  component into a canonical device (policy-gated via MergeEngine).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceInterfaceMac
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Query
  require Logger

  @doc """
  Reconcile duplicate devices by shared strong identifiers.

  Returns stats for observability and logging.
  """
  @spec reconcile_duplicates(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_duplicates(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:identity_reconciliation))
    max_merges = Keyword.get(opts, :max_merges, default_max_merges())
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Device identity reconciliation started")

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

    components =
      identifier_duplicates
      |> build_duplicate_components()
      |> Enum.filter(&(length(&1) > 1))

    {merge_count, error_count} = merge_components(components, actor, max_merges)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    stats = %{
      duplicate_identifier_count: length(identifier_duplicates),
      duplicate_components: length(components),
      merges: merge_count,
      errors: error_count,
      duration_ms: duration_ms
    }

    Logger.info("Device identity reconciliation completed: #{inspect(stats)}")

    {:ok, stats}
  rescue
    error ->
      Logger.warning("Device identity reconciliation failed: #{inspect(error)}")
      {:error, error}
  end

  # The scheduled job runs every few minutes; cap merges per run so a bad
  # state converges gradually under the merge guards instead of mass-merging.
  defp default_max_merges do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_merges_per_run, 200)
  end

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
      sibling_groups_for_partition(partition, partition_rows)
    end)
  end

  defp sibling_groups_for_partition(partition, rows) do
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
              group = {{partition, :mac_sibling, mac}, MapSet.new([device_id, other_id])}
              {[group | groups], MapSet.put(seen, {mac, sibling})}

            _ ->
              {groups, seen}
          end
      end
    end)
    |> elem(0)
  end

  # A MAC that lives on `ocsf_devices.mac` but is registered to a DIFFERENT
  # device. None of the groupings above can see this pair:
  #
  #   * `duplicate_identifier_groups/0` looks for one identifier value owned by
  #     more than one device, which `device_identifiers_unique_identifier_index`
  #     (UNIQUE on identifier_type, identifier_value, partition) makes
  #     impossible -- a second device can never register the same MAC.
  #   * `hardware_mac_sibling_groups/0` pairs two *registered* MACs differing in
  #     the IEEE local bit; here only one side is registered at all.
  #
  # So a device carrying a MAC it never registered stays split from the device
  # that did register it, indefinitely. Measured on one deployment: 10 mergeable
  # pairs, each a record split from its twin because only one side registered.
  #
  # Same evidence bar as the rest of this module: globally-unique MACs only. A
  # multi-MAC column fails the 12-hex regex and is skipped rather than guessed
  # at, and the merge still goes through the policy-gated MergeEngine.
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
          where: di.device_id != d.uid,
          where: fragment("upper(translate(?, ':-.', '')) ~ '^[0-9A-F]{12}$'", d.mac),
          select:
            {fragment("upper(translate(?, ':-.', ''))", d.mac), d.uid, di.device_id, di.partition}
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
  @spec column_mac_groups_from_rows([{String.t(), String.t(), String.t(), String.t()}]) :: [
          {{String.t(), atom(), String.t()}, MapSet.t()}
        ]
  def column_mac_groups_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reject(fn {mac, _uid, _owner, _partition} -> Mac.locally_administered_mac?(mac) end)
    |> Enum.map(fn {mac, uid, owner, partition} ->
      {{partition, :mac_column, mac}, MapSet.new([uid, owner])}
    end)
    |> Enum.uniq()
  end

  # One chassis reached at two addresses becomes two device rows anchored by
  # DIFFERENT interface MACs, so they share no identifier and every other group
  # source here correctly finds nothing. The evidence that they are one device is
  # that one of them reports the other's anchor MAC on its OWN interface table,
  # over authenticated SNMP.
  #
  # This is not "merge on a shared MAC" -- MergePolicy blocks MAC-only matches as
  # "too noisy (especially interface MACs observed by mapper)", and that stays
  # true for MACs merely OBSERVED. The distinction is ownership: a neighbour
  # table says what a device can see, an interface table says what it IS.
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

  defp build_duplicate_components(duplicate_entries) do
    duplicate_entries
    |> build_duplicate_parents()
    |> build_duplicate_groups()
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
    |> Map.values()
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

  defp merge_components(components, actor, max_merges) do
    Enum.reduce_while(components, {0, 0}, fn device_ids, {merged, errors} ->
      {merged_count, error_count, halted?} =
        merge_component_devices(device_ids, actor, max_merges, merged)

      total_merged = merged + merged_count
      total_errors = errors + error_count

      if halted? or (max_merges && total_merged >= max_merges) do
        {:halt, {total_merged, total_errors}}
      else
        {:cont, {total_merged, total_errors}}
      end
    end)
  end

  defp merge_component_devices(device_ids, actor, max_merges, merged_so_far) do
    canonical_id = choose_canonical_device_id(device_ids, actor)

    {local_merged, local_errors} =
      device_ids
      |> Enum.reject(&(&1 == canonical_id))
      |> Enum.reduce_while({0, 0}, fn from_id, acc ->
        merge_component_step(from_id, canonical_id, actor, max_merges, merged_so_far, acc)
      end)

    halted? = max_merges && merged_so_far + local_merged >= max_merges
    {local_merged, local_errors, halted?}
  end

  defp merge_component_step(from_id, canonical_id, actor, max_merges, merged_so_far, acc) do
    {local_merged, local_errors} = acc

    if max_merges && merged_so_far + local_merged >= max_merges do
      {:halt, {local_merged, local_errors}}
    else
      case merge_component_device(from_id, canonical_id, actor) do
        :ok -> {:cont, {local_merged + 1, local_errors}}
        {:error, _reason} -> {:cont, {local_merged, local_errors + 1}}
      end
    end
  end

  defp merge_component_device(from_id, canonical_id, actor) do
    case MergeEngine.merge_devices(from_id, canonical_id,
           actor: actor,
           reason: "identifier_backfill",
           details: %{source: "scheduled_reconciliation"}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to merge device #{from_id} into #{canonical_id}: #{inspect(reason)}"
        )

        {:error, reason}
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
