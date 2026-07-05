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
end
