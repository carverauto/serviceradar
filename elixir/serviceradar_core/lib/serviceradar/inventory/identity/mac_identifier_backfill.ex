defmodule ServiceRadar.Inventory.Identity.MacIdentifierBackfill do
  @moduledoc """
  Bounded, dry-run-first registration of MAC identifiers that exist on the
  device row but were never registered in `device_identifiers`.

  DIRE converges on *registered* identifiers, so a device carrying a MAC only in
  `ocsf_devices.mac` is invisible to MAC-based matching. When another source
  later discovers the same hardware and does register the MAC, the two records
  cannot converge and the fleet splits. Measured on one deployment: 15 live
  duplicate-MAC groups, and 22 of 71 devices (31%) holding a MAC with no
  identifier row.

  The gap is NOT a clean per-ingest-path failure -- the same
  `discovery_sources` combination both registers and misses -- so this repairs
  state rather than assuming a cause. It is idempotent, so it still converges if
  the underlying gap recurs.

  Safety, mirroring `HardwareSerialBackfill`:

    * dry run by default; `mode: :execute` is explicit
    * a MAC claimed by more than one device in the batch is rejected outright,
      never tie-broken -- a wrong MAC binding merges two devices
    * an identifier already owned by a different device is reported as a
      conflict and never rebound
    * confidence comes from `Mac.mac_confidence/1`, the same function the live
      registrar uses, so backfilled rows behave exactly like organic ones
      (locally-administered MACs -- randomized phone Wi-Fi, virtual bridges --
      are therefore registered at reduced confidence, not as strong identity)
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Repo

  require Logger

  @default_limit 5_000
  @max_limit 50_000
  @lookup_chunk_size 2_000
  @source "mac_identifier_backfill"
  @backfill_version "mac_identifier_v1"

  @type mode :: :dry_run | :execute

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :dry_run)
    limit = bounded_limit(Keyword.get(opts, :limit, @default_limit))
    after_uid = normalize_after_uid(Keyword.get(opts, :after_uid))
    device_loader = Keyword.get(opts, :device_loader, &load_devices/2)

    with :ok <- validate_mode(mode),
         {:ok, devices} <- normalize_loader_result(device_loader.(limit, after_uid)),
         {:ok, plan} <- plan(devices, opts),
         {:ok, report} <- maybe_execute(plan, mode, opts) do
      {:ok,
       report
       |> Map.put(:mode, mode)
       |> Map.put(:limit, limit)
       |> Map.put(:after_uid, after_uid)
       |> Map.put(:scanned, length(devices))
       |> Map.put(:page_full, length(devices) == limit)}
    end
  rescue
    error ->
      Logger.warning("MAC identifier backfill failed: #{Exception.message(error)}")
      {:error, :mac_identifier_backfill_failed}
  end

  @doc false
  @spec plan([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def plan(devices, opts \\ [])

  def plan(devices, opts) when is_list(devices) do
    existing_loader = Keyword.get(opts, :existing_loader, &load_existing_owners/1)

    {candidates, rejected} =
      devices
      |> Enum.flat_map(&normalize_candidates/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    candidates = Enum.map(candidates, fn {:ok, candidate} -> candidate end)
    rejected = Enum.map(rejected, fn {:error, entry} -> entry end)

    {ambiguous, unique} = split_ambiguous_candidates(candidates)
    keys = Enum.map(unique, &identifier_key/1)

    with {:ok, existing} <- normalize_loader_result(existing_loader.(keys)) do
      entries =
        rejected
        |> Kernel.++(ambiguous)
        |> Kernel.++(Enum.map(unique, &classify_existing_owner(&1, existing)))
        |> Enum.sort_by(&entry_sort_key/1)

      {:ok, %{entries: entries, summary: summarize(entries), plan_hash: plan_hash(entries)}}
    end
  end

  def plan(_devices, _opts), do: {:error, :invalid_device_batch}

  @doc false
  @spec execute(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(plan, opts \\ [])

  def execute(%{entries: entries} = plan, opts) when is_list(entries) do
    actor = Keyword.get(opts, :actor)
    registrar = Keyword.get(opts, :registrar, &register_identifier/2)

    executed =
      Enum.map(entries, fn
        %{status: :ready} = entry -> execute_entry(entry, actor, registrar)
        entry -> entry
      end)

    report = %{plan | entries: executed, summary: summarize(executed)}

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :mac_identifier_backfill],
      report.summary,
      %{mode: :execute, plan_hash: plan.plan_hash}
    )

    Logger.info("MAC identifier backfill completed",
      plan_hash: plan.plan_hash,
      summary: inspect(report.summary)
    )

    {:ok, report}
  end

  def execute(_plan, _opts), do: {:error, :invalid_mac_identifier_plan}

  defp maybe_execute(plan, :dry_run, _opts) do
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :mac_identifier_backfill],
      plan.summary,
      %{mode: :dry_run, plan_hash: plan.plan_hash}
    )

    {:ok, plan}
  end

  defp maybe_execute(plan, :execute, opts), do: execute(plan, opts)

  # One candidate per normalized MAC: a device row may legitimately carry
  # several, and each is registered independently.
  defp normalize_candidates(device) do
    uid = string_value(device, :uid)
    partition_result = device_partition(device)

    cond do
      is_nil(uid) ->
        [{:error, rejected_entry(nil, "default", :missing_device_uid, device, nil)}]

      match?({:error, _}, partition_result) ->
        [{:error, rejected_entry(uid, "default", :ambiguous_device_partition, device, nil)}]

      true ->
        {:ok, partition} = partition_result

        case device |> string_value(:mac) |> Mac.normalize_mac_list() do
          [] ->
            [{:error, rejected_entry(uid, partition, :invalid_or_missing_mac, device, nil)}]

          macs ->
            Enum.map(macs, fn mac ->
              {:ok,
               %{
                 device_uid: uid,
                 partition: partition,
                 identifier_value: mac,
                 confidence: Mac.mac_confidence(mac),
                 prior_evidence: prior_evidence(device),
                 status: :ready,
                 reason: nil
               }}
            end)
        end
    end
  end

  # Fail closed: a MAC claimed by two devices in the same batch is evidence of a
  # problem, not a tiebreak. Binding it either way would merge them.
  defp split_ambiguous_candidates(candidates) do
    candidates
    |> Enum.group_by(&identifier_key/1)
    |> Enum.reduce({[], []}, fn {_key, grouped}, {ambiguous, unique} ->
      case Enum.uniq_by(grouped, & &1.device_uid) do
        [_single] ->
          {ambiguous, [hd(grouped) | unique]}

        multiple ->
          uids = multiple |> Enum.map(& &1.device_uid) |> Enum.sort()

          flagged =
            Enum.map(grouped, fn candidate ->
              candidate
              |> Map.put(:status, :skipped)
              |> Map.put(:reason, :mac_claimed_by_multiple_devices)
              |> Map.put(:conflicting_device_uids, uids)
            end)

          {flagged ++ ambiguous, unique}
      end
    end)
  end

  defp classify_existing_owner(candidate, owners) do
    case Map.get(owners, identifier_key(candidate)) do
      nil ->
        candidate

      owner when owner == candidate.device_uid ->
        candidate |> Map.put(:status, :already_registered) |> Map.put(:reason, :same_owner)

      owner ->
        candidate
        |> Map.put(:status, :conflict)
        |> Map.put(:reason, :identifier_owned_by_another_device)
        |> Map.put(:existing_owner_uid, owner)
    end
  end

  defp execute_entry(entry, actor, registrar) do
    case registrar.(entry, actor) do
      :ok -> %{entry | status: :registered, reason: nil}
      {:ok, :already_registered} -> %{entry | status: :already_registered, reason: :same_owner}
      {:error, reason} -> %{entry | status: :error, reason: reason}
    end
  end

  defp register_identifier(entry, _actor) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    record = %{
      device_id: entry.device_uid,
      identifier_type: :mac,
      identifier_value: entry.identifier_value,
      partition: entry.partition,
      confidence: entry.confidence,
      source: @source,
      verified: false,
      first_seen: now,
      last_seen: now,
      metadata: %{
        "backfill" => @backfill_version,
        "canonical_device_uid" => entry.device_uid,
        "mac_confidence" => to_string(entry.confidence),
        "prior_evidence" => entry.prior_evidence
      }
    }

    # on_conflict: :nothing so a concurrent organic registration wins and this
    # never rebinds an identifier that another device already owns.
    {inserted, _rows} =
      Repo.insert_all(DeviceIdentifier, [record],
        on_conflict: :nothing,
        conflict_target: [:identifier_type, :identifier_value, :partition]
      )

    if inserted == 1, do: :ok, else: {:ok, :already_registered}
  end

  defp load_devices(limit, after_uid) do
    query =
      from(device in Device,
        where: is_nil(device.deleted_at) and not is_nil(device.mac) and device.mac != "",
        order_by: [asc: device.uid],
        limit: ^limit,
        select: %{
          uid: device.uid,
          mac: device.mac,
          hostname: device.hostname,
          ip: device.ip,
          discovery_sources: device.discovery_sources
        }
      )

    query =
      if is_binary(after_uid),
        do: from(device in query, where: device.uid > ^after_uid),
        else: query

    devices = Repo.all(query)
    partitions = load_device_partitions(Enum.map(devices, & &1.uid))

    {:ok,
     Enum.map(devices, fn device ->
       Map.put(device, :partitions, Map.get(partitions, device.uid, []))
     end)}
  end

  defp load_device_partitions([]), do: %{}

  defp load_device_partitions(device_uids) do
    DeviceIdentifier
    |> where([identifier], identifier.device_id in ^device_uids)
    |> select([identifier], {identifier.device_id, identifier.partition})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {device_uid, partition}, acc ->
      Map.update(acc, device_uid, MapSet.new([partition]), &MapSet.put(&1, partition))
    end)
    |> Map.new(fn {device_uid, values} ->
      {device_uid, values |> MapSet.to_list() |> Enum.sort()}
    end)
  end

  defp load_existing_owners([]), do: {:ok, %{}}

  defp load_existing_owners(keys) do
    key_set = MapSet.new(keys)

    owners =
      keys
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.chunk_every(@lookup_chunk_size)
      |> Enum.flat_map(fn values ->
        Repo.all(
          from(identifier in DeviceIdentifier,
            where: identifier.identifier_type == :mac and identifier.identifier_value in ^values,
            select: {identifier.partition, identifier.identifier_value, identifier.device_id}
          )
        )
      end)
      |> Enum.reduce(%{}, fn {partition, value, device_uid}, acc ->
        key = {partition, value}
        if MapSet.member?(key_set, key), do: Map.put(acc, key, device_uid), else: acc
      end)

    {:ok, owners}
  end

  # A device with no identifiers has no partition evidence -- which is exactly
  # the population this repairs -- so it falls back to "default", matching
  # HardwareSerialBackfill.
  defp device_partition(device) do
    partitions =
      device
      |> value(:partitions)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case partitions do
      [] -> {:ok, string_value(device, :partition) || "default"}
      [partition] -> {:ok, partition}
      _multiple -> {:error, :ambiguous_device_partition}
    end
  end

  defp rejected_entry(uid, partition, reason, device, identifier_value) do
    %{
      device_uid: uid,
      partition: partition,
      identifier_value: identifier_value,
      confidence: nil,
      prior_evidence: prior_evidence(device),
      status: :skipped,
      reason: reason
    }
  end

  defp prior_evidence(device) do
    %{
      "hostname" => string_value(device, :hostname),
      "ip" => string_value(device, :ip),
      "discovery_sources" =>
        device
        |> value(:discovery_sources)
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.take(16)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp summarize(entries) do
    counts = Enum.frequencies_by(entries, & &1.status)

    %{
      total: length(entries),
      ready: Map.get(counts, :ready, 0),
      registered: Map.get(counts, :registered, 0),
      already_registered: Map.get(counts, :already_registered, 0),
      conflicts: Map.get(counts, :conflict, 0),
      skipped: Map.get(counts, :skipped, 0),
      errors: Map.get(counts, :error, 0)
    }
  end

  defp plan_hash(entries) do
    payload =
      Enum.map(entries, fn entry ->
        Map.take(entry, [
          :device_uid,
          :partition,
          :identifier_value,
          :status,
          :reason,
          :existing_owner_uid,
          :conflicting_device_uids
        ])
      end)

    :sha256 |> :crypto.hash(Jason.encode!(payload)) |> Base.encode16(case: :lower)
  end

  defp identifier_key(entry), do: {entry.partition, entry.identifier_value}

  defp entry_sort_key(entry) do
    {entry.partition || "", entry.identifier_value || "", entry.device_uid || ""}
  end

  defp validate_mode(mode) when mode in [:dry_run, :execute], do: :ok
  defp validate_mode(_mode), do: {:error, :invalid_backfill_mode}

  defp bounded_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp bounded_limit(_limit), do: @default_limit

  defp normalize_after_uid(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_after_uid(_value), do: nil

  defp normalize_loader_result({:ok, value}), do: {:ok, value}
  defp normalize_loader_result(value) when is_list(value), do: {:ok, value}
  defp normalize_loader_result(value) when is_map(value), do: {:ok, value}
  defp normalize_loader_result({:error, reason}), do: {:error, reason}
  defp normalize_loader_result(_other), do: {:error, :invalid_loader_result}

  defp value(device, key) when is_map(device), do: Map.get(device, key)
  defp value(_device, _key), do: nil

  defp string_value(device, key) do
    case value(device, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      _ ->
        nil
    end
  end
end
