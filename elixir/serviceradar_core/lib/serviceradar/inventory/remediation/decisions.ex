defmodule ServiceRadar.Inventory.Remediation.Decisions do
  @moduledoc """
  Pure decision functions for the DIRE production-data remediation task
  (`mix serviceradar.dire_remediation`, OpenSpec
  `refactor-device-identity-reconciliation` tasks 4.1-4.4).

  No database access happens here: every rule that decides whether a row is
  purged, deleted, restored, repointed, or merged lives in this module so it
  can be unit-tested in isolation. The step modules under
  `ServiceRadar.Inventory.Remediation` translate these decisions into
  (audited) writes.
  """

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.IntegrationIdentity

  @valid_mac_pattern ~r/^[0-9A-F]{12}$/

  @default_debris_date ~D[2026-04-25]
  @default_null_device_patterns [
    "test-agent-",
    "local-config-agent-",
    "recover-agent-",
    "new-heartbeat-agent-"
  ]
  @default_sim_patterns [
    "agent-active-ip-conflict-",
    "agent-active-ip-owner-"
  ]
  @default_debris_device_agent_prefix "agent-reip-"
  @default_debris_hostnames ["k8s-pod-a", "k8s-pod-b"]
  @default_hostname_denylist ["localhost", "unknown"]

  def default_debris_date, do: @default_debris_date
  def default_null_device_patterns, do: @default_null_device_patterns
  def default_sim_patterns, do: @default_sim_patterns
  def default_debris_device_agent_prefix, do: @default_debris_device_agent_prefix
  def default_debris_hostnames, do: @default_debris_hostnames
  def default_hostname_denylist, do: @default_hostname_denylist

  # ---------------------------------------------------------------------------
  # Blob purge (task 4.1)
  # ---------------------------------------------------------------------------

  @doc """
  A valid stored MAC identifier value: exactly 12 uppercase hex characters.
  """
  @spec valid_mac_value?(term()) :: boolean()
  def valid_mac_value?(value) when is_binary(value), do: Regex.match?(@valid_mac_pattern, value)

  def valid_mac_value?(_), do: false

  @doc """
  Rows the blob purge deletes: any `mac` identifier value that is not an
  atomic, valid 12-hex value (comma blobs, wrong length, non-hex).
  """
  @spec purgeable_mac_value?(term()) :: boolean()
  def purgeable_mac_value?(value), do: not valid_mac_value?(value)

  @doc """
  Multi-MAC blob detection (comma/semicolon/whitespace-joined histories).
  """
  @spec mac_blob?(term()) :: boolean()
  def mac_blob?(value) when is_binary(value), do: String.contains?(value, [",", ";", " "])

  def mac_blob?(_), do: false

  @doc """
  First valid MAC extracted from a (possibly multi-value) blob, or nil when
  the blob holds no valid MAC. Delegates to
  `IdentityReconciler.normalize_mac/1` so extraction uses the same
  normalization the reconciler enforces at the boundary.
  """
  @spec first_mac_from_blob(term()) :: String.t() | nil
  def first_mac_from_blob(value), do: IdentityReconciler.normalize_mac(value)

  # ---------------------------------------------------------------------------
  # Test debris (task 4.2)
  # ---------------------------------------------------------------------------

  @doc """
  Whether an `ocsf_agents` row is 2026-04-25 test-suite debris.

  Conservative, all of:
    * created on the debris date (default #{inspect(@default_debris_date)})
    * not in an active connection state
    * uid matches a configured debris prefix:
      - the "named" patterns (#{inspect(@default_null_device_patterns)})
        additionally require a NULL/blank `device_uid`
      - the active-ip simulation patterns (#{inspect(@default_sim_patterns)})
        may carry a (simulated) device link
  """
  @spec debris_agent?(map(), keyword()) :: boolean()
  def debris_agent?(agent, opts \\ []) when is_map(agent) do
    date = Keyword.get(opts, :date, @default_debris_date)
    null_patterns = Keyword.get(opts, :null_device_patterns, @default_null_device_patterns)
    sim_patterns = Keyword.get(opts, :sim_patterns, @default_sim_patterns)
    uid = to_string(Map.get(agent, :uid) || "")

    created_on?(Map.get(agent, :created_time), date) and
      not active_agent_status?(Map.get(agent, :status)) and
      ((prefix_match?(uid, null_patterns) and blank?(Map.get(agent, :device_uid))) or
         prefix_match?(uid, sim_patterns))
  end

  @doc """
  Whether an `ocsf_devices` row is reip-simulation debris: its `agent_id`
  carries the simulation prefix (default `agent-reip-`) or its hostname is one
  of the known fake pod hostnames (default k8s-pod-a/k8s-pod-b).
  """
  @spec debris_device?(map(), keyword()) :: boolean()
  def debris_device?(device, opts \\ []) when is_map(device) do
    prefix = Keyword.get(opts, :agent_id_prefix, @default_debris_device_agent_prefix)
    hostnames = Keyword.get(opts, :hostnames, @default_debris_hostnames)
    agent_id = Map.get(device, :agent_id)
    hostname = normalize_hostname(Map.get(device, :hostname))

    (is_binary(agent_id) and prefix != "" and String.starts_with?(agent_id, prefix)) or
      (not is_nil(hostname) and hostname in Enum.map(hostnames, &normalize_hostname/1))
  end

  # ---------------------------------------------------------------------------
  # Agent links (task 4.3)
  # ---------------------------------------------------------------------------

  @doc """
  Normalized hostname for matching: trimmed + lowercased; nil for blank.
  """
  @spec normalize_hostname(term()) :: String.t() | nil
  def normalize_hostname(hostname) when is_binary(hostname) do
    case hostname |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_hostname(_), do: nil

  @doc """
  The hostname an agent's device is expected to carry, derived from the
  agent row itself (ground truth), never from hardcoded device ids.
  """
  @spec expected_hostname(map()) :: String.t() | nil
  def expected_hostname(agent) when is_map(agent) do
    normalize_hostname(Map.get(agent, :host)) || normalize_hostname(Map.get(agent, :name))
  end

  @doc """
  Whether a device row is the correct, live host device for the expected
  hostname.
  """
  @spec device_matches_host?(map() | nil, String.t() | nil) :: boolean()
  def device_matches_host?(nil, _expected), do: false
  def device_matches_host?(_device, nil), do: false

  def device_matches_host?(device, expected) when is_map(device) do
    is_nil(Map.get(device, :deleted_at)) and
      normalize_hostname(Map.get(device, :hostname)) == expected
  end

  @doc """
  When several agents share one device row (the chimera pathology), at most
  one agent rightfully owns it: the one whose expected hostname matches the
  device hostname (ties broken deterministically by agent uid). Returns the
  owning agent or nil.
  """
  @spec choose_device_owner([map()], term()) :: map() | nil
  def choose_device_owner(agents, device_hostname) do
    case normalize_hostname(device_hostname) do
      nil ->
        nil

      normalized ->
        agents
        |> Enum.filter(&(expected_hostname(&1) == normalized))
        |> Enum.sort_by(&to_string(Map.get(&1, :uid)))
        |> List.first()
    end
  end

  @doc "Whether a string parses as an IP address (rejects literals like \"agent\")."
  @spec valid_ip?(term()) :: boolean()
  def valid_ip?(value) when is_binary(value) do
    case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, _} -> true
      _ -> false
    end
  end

  def valid_ip?(_), do: false

  # ---------------------------------------------------------------------------
  # Proxmox duplicates (task 4.4)
  # ---------------------------------------------------------------------------

  @doc """
  Pick the canonical device of an intra-Proxmox duplicate hostname group.

  Preference order: a device some agent row links to (never tombstone an
  agent's device), then most recent `last_seen_time`, then lowest uid for
  determinism. `linked_uids` is a `MapSet` of `ocsf_agents.device_uid`s.
  """
  @spec select_canonical([map()], MapSet.t()) :: map()
  def select_canonical(devices, %MapSet{} = linked_uids) when devices != [] do
    devices
    |> Enum.sort_by(fn device ->
      uid = Map.get(device, :uid)

      {if(MapSet.member?(linked_uids, uid), do: 0, else: 1),
       -datetime_rank(Map.get(device, :last_seen_time)), to_string(uid)}
    end)
    |> List.first()
  end

  @doc """
  Group live proxmox-sourced devices into duplicate groups by normalized
  hostname; only groups with more than one device (and a non-denylisted
  hostname) are returned, as `{normalized_hostname, devices}`.
  """
  @spec duplicate_hostname_groups([map()], [String.t()]) :: [{String.t(), [map()]}]
  def duplicate_hostname_groups(devices, denylist \\ @default_hostname_denylist) do
    denylist = denylist |> Enum.map(&normalize_hostname/1) |> Enum.reject(&is_nil/1)

    devices
    |> Enum.group_by(&normalize_hostname(Map.get(&1, :hostname)))
    |> Enum.reject(fn {hostname, group} ->
      is_nil(hostname) or hostname in denylist or length(group) < 2
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  True when two devices are corroborated as the SAME physical host by a shared
  strong identity: a common MAC address or a common Proxmox host reference
  (`integration_id` / `hypervisor_provider_ref` / `hypervisor_host_provider_ref`
  / `legacy_integration_ids`).

  A shared hostname is deliberately NOT sufficient. Distinct Proxmox clusters
  routinely reuse node hostnames (`pve01`, `pve02`, …), so merging on hostname
  alone would fuse distinct hardware across clusters — the exact over-merge this
  guard exists to prevent. Devices are expected to carry `:macs` and
  `:host_refs` as `MapSet`s of normalized tokens; absent both (network-probed
  candidates with no MAC and no enrichment ref), no corroboration exists and the
  pair is treated as distinct.

  Proxmox host references must satisfy the admissibility contract in
  `IntegrationIdentity`. Shared atomic MACs remain separate evidence.
  """
  @spec same_physical_host?(map(), map()) :: boolean()
  def same_physical_host?(a, b) do
    shared_tokens?(Map.get(a, :macs), Map.get(b, :macs)) or
      shared_tokens?(strong_host_refs(a), strong_host_refs(b))
  end

  # Host references minus the ambiguous name-keyed values that fuse
  # same-named devices across clusters (GitHub #4051). Operates on the token
  # sets (not the device maps) so callers keep passing raw `host_refs`.
  defp strong_host_refs(device) do
    case Map.get(device, :host_refs) do
      %MapSet{} = refs ->
        MapSet.reject(refs, &IntegrationIdentity.ambiguous_name_keyed?/1)

      _ ->
        nil
    end
  end

  @doc """
  Partition a same-hostname group into identity components: two devices land in
  the same component iff they are (transitively) corroborated as the same
  physical host via `same_physical_host?/2`. Devices that share only a hostname
  fall into separate singleton components and are therefore never merged.

  Returns a list of components (each a list of devices). Merge planning collapses
  only components of size >= 2, so a hostname group spanning multiple clusters
  yields one component per physical host and never merges across them.
  """
  @spec identity_components([map()]) :: [[map()]]
  def identity_components(devices) do
    Enum.reduce(devices, [], fn device, components ->
      {matching, rest} =
        Enum.split_with(components, fn component ->
          Enum.any?(component, &same_physical_host?(&1, device))
        end)

      [[device | List.flatten(matching)] | rest]
    end)
  end

  defp shared_tokens?(%MapSet{} = a, %MapSet{} = b),
    do: MapSet.size(a) > 0 and not MapSet.disjoint?(a, b)

  defp shared_tokens?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Proxmox cross-cluster unfuse (GitHub #4051)
  # ---------------------------------------------------------------------------

  @doc """
  Plan the split of one Proxmox-fused device back into per-cluster devices.

  Before the name-key guard existed, resolve-time lookups on legacy
  name-keyed bridges (`proxmox:vm:<name>` and kin) collapsed updates from
  different Proxmox clusters onto one row, which then accumulated every
  cluster's v2 identifiers. That collapse wrote no reversible merge_audit, so
  like `plan_armis_unmerge/2` the target grouping is reconstructed from
  current state — here the cluster segment of the registered
  `proxmox:v2:<cluster>:<kind>:<ref>` integration ids, which ARE unique
  within their scope.

    * `device` — `%{uid, partition, tombstoned?}`
    * `v2_rows` — `[%{id, value, partition, first_seen, source_id}]`, the
      device's registered v2 integration_id rows (caller parses nothing; the
      planner validates each value with `IntegrationIdentity.parse_v2/1`)
    * `mac_rows` — `[%{id, value, partition, source_id}]`, the device's
      registered atomic MAC rows with their registration provenance

  Returns `{:skip, reason}` or `{:split, plan}`. Fail-closed throughout:

    * `:no_v2_identifiers` / `:unexpected_identifier_shape` — nothing, or
      nothing parseable, to group by
    * `:single_cluster` — a normal device, not an over-merge
    * `:tombstoned` — fused tombstones need operator judgment, never an
      automatic restore
    * `:multiple_partitions` — every row must carry the device's own
      canonical partition; no default is synthesized
    * `:ambiguous_mac_attribution` — a MAC row whose registration source
      matches zero or several cluster groups cannot be placed. Leaving it on
      the survivor would re-trigger a cross-device conflict on the next sync
      (and re-fuse past the unmerge cooldown), so the candidate waits for
      manual attribution instead
    * `:uid_collision` — a split target UID already equals the source UID or
      a sibling target (never emit a self-target or a fork)

  The survivor group is the earliest-registered cluster (lowest row
  `first_seen`, ties broken by cluster name): the original owner keeps the
  row. Every other cluster gets a fresh remediation-stable UID derived from
  its own v2 id alone, so later ingest resolves through the reassigned
  strong identifier rows regardless of UID parity.
  """
  @spec plan_proxmox_unfuse(map(), [map()], [map()]) :: {:skip, atom()} | {:split, map()}
  def plan_proxmox_unfuse(device, v2_rows, mac_rows)
      when is_map(device) and is_list(v2_rows) and is_list(mac_rows) do
    with {:ok, groups} <- proxmox_cluster_groups(v2_rows),
         :ok <- check_proxmox_multi_cluster(groups),
         :ok <- check_proxmox_live(device),
         :ok <- check_proxmox_partitions(device, v2_rows, mac_rows),
         {:ok, plan} <- build_proxmox_split_plan(device, groups, mac_rows) do
      {:split, plan}
    end
  end

  defp proxmox_cluster_groups([]), do: {:skip, :no_v2_identifiers}

  defp proxmox_cluster_groups(v2_rows) do
    Enum.reduce_while(v2_rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case IntegrationIdentity.parse_v2(row[:value]) do
        {:ok, %{cluster: cluster}} ->
          {:cont, {:ok, Map.update(acc, cluster, [row], &[row | &1])}}

        :error ->
          {:halt, {:skip, :unexpected_identifier_shape}}
      end
    end)
  end

  defp check_proxmox_multi_cluster(groups) when map_size(groups) < 2, do: {:skip, :single_cluster}

  defp check_proxmox_multi_cluster(_groups), do: :ok

  defp check_proxmox_live(%{tombstoned?: true}), do: {:skip, :tombstoned}
  defp check_proxmox_live(_device), do: :ok

  defp check_proxmox_partitions(device, v2_rows, mac_rows) do
    partition = device[:partition]

    rows_ok? =
      is_binary(partition) and partition != "" and
        Enum.all?(v2_rows ++ mac_rows, &(&1[:partition] == partition))

    if rows_ok?, do: :ok, else: {:skip, :multiple_partitions}
  end

  defp build_proxmox_split_plan(device, groups, mac_rows) do
    partition = device[:partition]
    {survivor_cluster, _} = earliest_proxmox_cluster(groups)

    split_clusters = groups |> Map.keys() |> Enum.sort() |> Enum.reject(&(&1 == survivor_cluster))

    with {:ok, mac_assignments} <- assign_proxmox_macs(groups, mac_rows) do
      splits =
        Enum.map(split_clusters, fn cluster ->
          rows = Map.fetch!(groups, cluster)
          v2_values = rows |> Enum.map(& &1[:value]) |> Enum.uniq() |> Enum.sort()

          %{
            cluster: cluster,
            new_uid: proxmox_split_uid(partition, v2_values),
            v2_values: v2_values,
            row_ids: rows |> Enum.map(& &1[:id]) |> Enum.sort(),
            mac_row_ids: mac_assignments |> Map.get(cluster, []) |> Enum.sort()
          }
        end)

      uids = Enum.map(splits, & &1.new_uid)

      if device[:uid] in uids or length(uids) != length(Enum.uniq(uids)) do
        {:skip, :uid_collision}
      else
        {:split,
         %{
           device_uid: device[:uid],
           partition: partition,
           survivor: %{
             cluster: survivor_cluster,
             uid: device[:uid],
             row_ids: groups |> Map.fetch!(survivor_cluster) |> Enum.map(& &1[:id]) |> Enum.sort()
           },
           splits: splits
         }}
      end
    end
  end

  # Survivor = the cluster that registered first (lowest row first_seen, ties
  # by cluster name): the original owner keeps the device row. `first_seen`
  # may be a DateTime or NaiveDateTime depending on the reader; values are
  # normalized to unix microseconds for comparison, and missing values sort
  # last so dated evidence always wins over absent evidence.
  defp earliest_proxmox_cluster(groups) do
    groups
    |> Enum.map(fn {cluster, rows} ->
      earliest =
        rows
        |> Enum.map(&proxmox_first_seen_rank(&1[:first_seen]))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> List.first()

      {cluster, earliest}
    end)
    |> Enum.sort_by(fn {cluster, earliest} -> {is_nil(earliest), earliest, cluster} end)
    |> List.first()
    |> case do
      {cluster, _} -> {cluster, Map.fetch!(groups, cluster)}
    end
  end

  defp proxmox_first_seen_rank(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp proxmox_first_seen_rank(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp proxmox_first_seen_rank(_), do: nil

  # Attribute each MAC row to exactly one cluster group via its registration
  # provenance (`metadata.sync_service_id`): attributable iff the row's source
  # matches that group's v2 rows and no other group's. Anything else —
  # missing source, a source shared across groups, an unknown source — fails
  # the whole candidate closed: a MAC left on the survivor while its cluster
  # moves away re-fires the cross-device conflict on the next sync and
  # re-fuses past the unmerge cooldown. Attribution trusts reporter
  # provenance, so the dry-run report lists every MAC assignment (value and
  # source per cluster) for operator review before any execute allowlist.
  defp assign_proxmox_macs(groups, mac_rows) do
    group_sources = Map.new(groups, fn {cluster, rows} -> {cluster, group_source_ids(rows)} end)

    Enum.reduce_while(mac_rows, {:ok, %{}}, fn row, {:ok, acc} ->
      source = row[:source_id]

      owners =
        group_sources
        |> Enum.filter(fn {_cluster, sources} ->
          is_binary(source) and MapSet.member?(sources, source)
        end)
        |> Enum.map(&elem(&1, 0))

      case owners do
        [cluster] -> {:cont, {:ok, Map.update(acc, cluster, [row[:id]], &[row[:id] | &1])}}
        _ -> {:halt, {:skip, :ambiguous_mac_attribution}}
      end
    end)
  end

  defp group_source_ids(rows) do
    rows
    |> Enum.map(& &1[:source_id])
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  # Stable remediation UID over {partition, cluster v2 id}. Later ingest
  # resolves through the reassigned strong integration_id row, not this UID.
  defp proxmox_split_uid(partition, [primary_v2 | _]) do
    Ids.generate_deterministic_device_id(%{integration_id: primary_v2, partition: partition})
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp created_on?(%DateTime{} = created, %Date{} = date), do: DateTime.to_date(created) == date

  defp created_on?(%NaiveDateTime{} = created, %Date{} = date),
    do: NaiveDateTime.to_date(created) == date

  defp created_on?(_, _), do: false

  defp active_agent_status?(status) do
    to_string(status) in ["connected", "connecting", "degraded"]
  end

  defp prefix_match?(uid, patterns) do
    Enum.any?(patterns, fn pattern ->
      pattern != "" and String.starts_with?(uid, pattern)
    end)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp datetime_rank(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp datetime_rank(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp datetime_rank(_), do: 0

  # ---------------------------------------------------------------------------
  # Armis over-merge un-merge (armis-unmerge step)
  # ---------------------------------------------------------------------------

  @doc """
  Plan the split of one Armis-collapsed device from its universal MAC identifier
  rows.

  The ingest-time collapse wrote no reversible merge_audit, so the target
  grouping is reconstructed from current state: one target per distinct
  universal MAC. Co-occurrence provenance is lost, so genuine multi-NIC hosts
  are conservatively over-split. Later ingest does not prove that those classes
  should be rejoined because identifier ownership is intentionally stable; an
  operator must leave live-device execution disabled unless independent
  co-residency evidence validates the split. The **survivor** class keeps the
  existing device and its `armis_device_id`; every other class gets a fresh
  MAC-only device at a remediation-stable UID derived from
  `{armis_device_id, MAC, partition}`. Future ingest resolves through the moved
  typed MAC; the UID does not claim parity with enriched update shapes that
  carry additional strong seeds.

    * `device` — `%{uid, mac, armis_device_id, tombstoned?, live_overmerge_verified?}`
    * `mac_rows` — `[%{id, value, partition}]`, universal atomic MAC identifier rows

  Returns `{:skip, :no_universal_mac | :single_universal_mac}` or
  `{:split, plan}` where `plan` carries the survivor and the per-class splits.

  A live device with a single universal MAC is a normal device, not an
  over-merge, and is skipped. A **tombstoned** ghost with even one universal MAC
  still yields a plan: its survivor action is `:restore`, giving the orphaned
  sole-copy MAC a live home again (the reassign-before-delete rescue).
  Every universal row must carry the same canonical nonblank partition; no
  default partition is synthesized by the planner.
  """
  @spec plan_armis_unmerge(map(), [map()]) :: {:skip, atom()} | {:split, map()}
  def plan_armis_unmerge(device, mac_rows) when is_map(device) and is_list(mac_rows) do
    classes = mac_classes(mac_rows)
    {missing_partition?, partitions} = universal_mac_partitions(mac_rows)
    display_classes = display_mac_classes(device, classes)

    cond do
      map_size(classes) == 0 ->
        {:skip, :no_universal_mac}

      missing_partition? ->
        {:skip, :missing_partition}

      length(partitions) != 1 ->
        {:skip, :multiple_partitions}

      not device[:tombstoned?] and not canonical_partition?(device[:source_partition]) ->
        {:skip, :missing_source_partition}

      not device[:tombstoned?] and device[:source_partition] != hd(partitions) ->
        {:skip, :source_partition_mismatch}

      length(display_classes) > 1 ->
        {:skip, :ambiguous_display_mac}

      length(device[:typed_armis_rows] || []) != 1 ->
        {:skip, :ambiguous_typed_armis_identity}

      blank?(device[:armis_device_id]) ->
        {:skip, :missing_armis_device_id}

      not blank?(device[:metadata_armis_device_id]) and
          device[:metadata_armis_device_id] != device[:armis_device_id] ->
        {:skip, :armis_identity_mismatch}

      not device[:tombstoned?] and device[:armis_provenance_valid?] != true ->
        {:skip, :unproven_armis_identity_source}

      not device[:tombstoned?] and device[:integration_type] != "armis" ->
        {:skip, :noncanonical_armis_integration}

      not device[:tombstoned?] and device[:live_overmerge_verified?] != true ->
        {:skip, :missing_live_overmerge_signal}

      map_size(classes) == 1 and !device[:tombstoned?] ->
        {:skip, :single_universal_mac}

      true ->
        {:split, build_armis_split_plan(device, classes, hd(partitions))}
    end
  end

  defp display_mac_classes(device, classes) do
    device[:mac]
    |> Mac.universal_macs()
    |> MapSet.to_list()
    |> Enum.filter(&Map.has_key?(classes, &1))
    |> Enum.sort()
  end

  # Group the universal MAC identifier rows by their (already atomic, uppercase)
  # value — one class per distinct hardware MAC.
  defp mac_classes(mac_rows) do
    Enum.reduce(mac_rows, %{}, fn row, acc ->
      case row.value |> Mac.universal_macs() |> MapSet.to_list() do
        [value] -> Map.update(acc, value, [row], &[row | &1])
        _ -> acc
      end
    end)
  end

  defp universal_mac_partitions(mac_rows) do
    values =
      mac_rows
      |> Enum.filter(fn row -> MapSet.size(Mac.universal_macs(row.value)) == 1 end)
      |> Enum.map(fn row ->
        case row[:partition] do
          partition when is_binary(partition) ->
            if String.trim(partition) == partition and partition != "", do: partition

          _ ->
            nil
        end
      end)

    {Enum.any?(values, &is_nil/1), values |> Enum.reject(&is_nil/1) |> Enum.uniq()}
  end

  defp canonical_partition?(partition) when is_binary(partition),
    do: partition != "" and String.trim(partition) == partition

  defp canonical_partition?(_partition), do: false

  defp build_armis_split_plan(device, classes, partition) do
    target_uids =
      Map.new(classes, fn {mac, _rows} -> {mac, armis_split_uid(device, mac, partition)} end)

    survivor_mac = pick_survivor_mac(device, classes, target_uids)

    # A device may already carry the remediation-derived UID for one of its MAC
    # classes (for example, its display MAC changed after initial ingest).
    # Every class that hashes to the existing UID must remain on the survivor;
    # emitting it as a split target would turn the reassignment into a no-op and
    # leave the candidate permanently unconverged.
    survivor_macs =
      target_uids
      |> Enum.filter(fn {mac, uid} -> mac == survivor_mac or uid == device.uid end)
      |> MapSet.new(&elem(&1, 0))

    splits =
      classes
      |> Enum.reject(fn {mac, _rows} -> MapSet.member?(survivor_macs, mac) end)
      |> Enum.map(fn {mac, rows} ->
        %{
          mac: mac,
          new_uid: Map.fetch!(target_uids, mac),
          row_ids: rows |> Enum.map(& &1.id) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(& &1.mac)

    %{
      device_uid: device.uid,
      armis_device_id: device[:armis_device_id],
      partition: partition,
      tombstoned?: !!device[:tombstoned?],
      survivor: %{
        mac: survivor_mac,
        action: if(device[:tombstoned?], do: :restore, else: :adopt),
        uid: device.uid,
        # Survivor-class rows stay in place, so they get no :reassign_device
        # last_seen bump — the step must :touch them instead, or a restored
        # ghost's sole-copy MAC (guard lifted by :restore nulling
        # deleted_reason, last_seen still pinned to the cleanup date) would be
        # GC-eligible immediately after disposition.
        row_ids:
          survivor_macs
          |> Enum.flat_map(fn mac -> Map.fetch!(classes, mac) end)
          |> Enum.map(& &1.id)
          |> Enum.sort()
      },
      splits: splits
    }
  end

  # Prefer the class whose remediation target is already the device UID. The
  # mutable display MAC is only a fallback; selecting it first can emit the true
  # original class as a self-target after the display MAC changes.
  defp pick_survivor_mac(device, classes, target_uids) do
    deterministic_uid_mac =
      target_uids
      |> Enum.filter(fn {_mac, uid} -> uid == device.uid end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> List.first()

    device_mac =
      device
      |> display_mac_classes(classes)
      |> List.first()

    deterministic_uid_mac || device_mac || deterministic_fallback_class(classes)
  end

  # Identifier `last_seen` is a hot TTL field and cannot be a durable plan
  # input. Use the lowest normalized MAC as the stable fallback when neither
  # the remediation-derived UID nor the display MAC anchors the survivor.
  defp deterministic_fallback_class(classes) do
    classes
    |> Map.keys()
    |> Enum.sort()
    |> List.first()
  end

  # Stable remediation UID over {armis_id, class MAC, partition}. This matches
  # the canonical Armis-only ingest shape, but enriched updates can carry extra
  # strong seeds and hash differently. Later ingest still resolves to the
  # reconstructed device through the reassigned strong :mac identifier.
  defp armis_split_uid(device, mac, partition) do
    Ids.generate_deterministic_device_id(%{
      armis_id: device[:armis_device_id],
      mac: mac,
      partition: partition
    })
  end

  @doc """
  Which `ip_alias:` keys on a device are netprobe over-merge debris.

  Returns `{:skip, reason}` or `{:purge, [address]}`. Fail-closed: every guard
  below removes a way for a LEGITIMATE alias to be mistaken for debris, and an
  alias left behind costs nothing that a later run cannot take.

  The defect: a passive netprobe fingerprint used to identify the COLLECTOR that
  observed it rather than the host it described (fixed forward in the
  `passive-netprobe` enrichment-only classification), leaving the observed host's
  address as an `ip_alias:` on the collector's own device.

  There is NO provenance to key on -- `device_alias_states` has no source column,
  and `ip_alias:` keys have five writers. So each guard rules out one writer or
  one legitimate shape:

    * `:not_netprobe` -- the device never took a passive-netprobe update, so
      netprobe cannot be responsible for anything on it.
    * `:mapper_wrote_here` -- the mapper is the other writer of foreign-looking
      `ip_alias:` keys, and it writes a device's OWN alternate addresses. If it
      ever wrote to this device we cannot attribute any single key.
    * `:router_role` -- for router-role devices the mapper deliberately records
      the device's own interface addresses as `ip_alias:` and NOWHERE else, so
      every other guard is vacuous for exactly that population. A multi-homed
      gateway is also where netprobe is most likely to run, which is what makes
      this the dangerous case rather than an unlikely one.
    * `:no_addresses` -- nothing to do.

  and per address:

    * an address equal to the device's own `ip` is its self-alias, never debris;
    * an address with NO device of its own is NOT purged. It may be the only
      record that the address was ever seen, and this pass is not allowed to be
      the thing that loses it.
  """
  @spec plan_netprobe_alias_purge(map()) :: {:skip, atom()} | {:purge, [String.t()]}
  def plan_netprobe_alias_purge(device) when is_map(device) do
    sources = device[:discovery_sources] || []
    own_ip = trim(device[:ip])

    cond do
      "passive-netprobe" not in sources ->
        {:skip, :not_netprobe}

      "mapper" in sources ->
        {:skip, :mapper_wrote_here}

      router_role?(device) ->
        {:skip, :router_role}

      true ->
        purgeable =
          device
          |> Map.get(:foreign_aliases, [])
          |> Enum.map(&trim/1)
          |> Enum.reject(&(&1 == "" or &1 == own_ip))
          |> Enum.filter(&(&1 in (device[:addresses_with_own_device] || [])))
          |> Enum.uniq()

        if purgeable == [], do: {:skip, :no_addresses}, else: {:purge, purgeable}
    end
  end

  defp router_role?(device) do
    metadata = device[:metadata] || %{}

    role =
      metadata
      |> Map.get("device_role", Map.get(metadata, "_device_role"))
      |> to_string()
      |> String.downcase()
      |> String.trim()

    role == "router"
  end

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
