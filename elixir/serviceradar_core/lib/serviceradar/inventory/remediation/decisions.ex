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
  """
  @spec same_physical_host?(map(), map()) :: boolean()
  def same_physical_host?(a, b) do
    shared_tokens?(Map.get(a, :macs), Map.get(b, :macs)) or
      shared_tokens?(Map.get(a, :host_refs), Map.get(b, :host_refs))
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

    * `device` — `%{uid, mac, armis_device_id, partition, tombstoned?, live_overmerge_verified?}`
    * `mac_rows` — `[%{id, value, last_seen}]`, universal atomic MAC identifier rows

  Returns `{:skip, :no_universal_mac | :single_universal_mac}` or
  `{:split, plan}` where `plan` carries the survivor and the per-class splits.

  A live device with a single universal MAC is a normal device, not an
  over-merge, and is skipped. A **tombstoned** ghost with even one universal MAC
  still yields a plan: its survivor action is `:restore`, giving the orphaned
  sole-copy MAC a live home again (the reassign-before-delete rescue).
  """
  @spec plan_armis_unmerge(map(), [map()]) :: {:skip, atom()} | {:split, map()}
  def plan_armis_unmerge(device, mac_rows) when is_map(device) and is_list(mac_rows) do
    classes = mac_classes(mac_rows)
    partitions = universal_mac_partitions(mac_rows)

    cond do
      map_size(classes) == 0 ->
        {:skip, :no_universal_mac}

      length(partitions) > 1 ->
        {:skip, :multiple_partitions}

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
        {:split, build_armis_split_plan(device, classes)}
    end
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
    mac_rows
    |> Enum.filter(fn row -> MapSet.size(Mac.universal_macs(row.value)) == 1 end)
    |> Enum.map(& &1[:partition])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp build_armis_split_plan(device, classes) do
    partition = normalize_partition(device)

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
      device[:mac]
      |> Mac.universal_macs()
      |> MapSet.to_list()
      |> Enum.find(&Map.has_key?(classes, &1))

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

  defp normalize_partition(device) do
    case device[:partition] do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end
end
