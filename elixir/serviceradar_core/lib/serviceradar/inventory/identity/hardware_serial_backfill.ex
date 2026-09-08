defmodule ServiceRadar.Inventory.Identity.HardwareSerialBackfill do
  @moduledoc """
  Bounded, dry-run-first registration of hardware serial identifiers.

  The planner normalizes existing canonical device evidence, rejects ambiguous
  serials before any write, and records only a bounded evidence projection.
  Execute mode uses conflict-safe inserts and never rebinds an identifier.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.CardinalityCaps
  alias ServiceRadar.Inventory.Identity.HardwareSerial
  alias ServiceRadar.Repo

  require Logger

  @default_limit 5_000
  @max_limit 50_000
  @lookup_chunk_size 2_000
  @source "hardware_serial_backfill"

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
      Logger.warning("Hardware serial backfill failed: #{Exception.message(error)}")
      {:error, :hardware_serial_backfill_failed}
  end

  @doc false
  @spec plan([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def plan(devices, opts \\ [])

  def plan(devices, opts) when is_list(devices) do
    existing_loader = Keyword.get(opts, :existing_loader, &load_existing_owners/1)

    {candidates, rejected} =
      devices
      |> Enum.map(&normalize_candidate/1)
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

      {:ok,
       %{
         entries: entries,
         summary: summarize(entries),
         plan_hash: plan_hash(entries)
       }}
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
      [:serviceradar, :identity_reconciler, :hardware_serial_backfill],
      report.summary,
      %{mode: :execute, plan_hash: plan.plan_hash}
    )

    Logger.info("Hardware serial backfill completed",
      plan_hash: plan.plan_hash,
      summary: inspect(report.summary)
    )

    {:ok, report}
  end

  def execute(_plan, _opts), do: {:error, :invalid_hardware_serial_plan}

  defp maybe_execute(plan, :dry_run, _opts) do
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :hardware_serial_backfill],
      plan.summary,
      %{mode: :dry_run, plan_hash: plan.plan_hash}
    )

    {:ok, plan}
  end

  defp maybe_execute(plan, :execute, opts), do: execute(plan, opts)

  defp normalize_candidate(device) do
    uid = string_value(device, :uid)
    partition_result = device_partition(device)
    update = serial_update(device)

    cond do
      is_nil(uid) ->
        {:error, rejected_entry(nil, "default", :missing_device_uid, device)}

      match?({:error, _}, partition_result) ->
        {:error, rejected_entry(uid, "default", :ambiguous_device_partition, device)}

      true ->
        {:ok, partition} = partition_result

        case HardwareSerial.evidence(update) do
          {:ok, evidence} ->
            {:ok,
             %{
               device_uid: uid,
               partition: partition,
               identifier_value: evidence.identifier_value,
               vendor_namespace: evidence.vendor_namespace,
               normalized_serial: evidence.normalized_serial,
               prior_evidence: prior_evidence(device),
               status: :ready,
               reason: nil
             }}

          :error ->
            {:error, rejected_entry(uid, partition, :invalid_or_unscoped_serial, device)}
        end
    end
  end

  defp split_ambiguous_candidates(candidates) do
    candidates
    |> Enum.group_by(&identifier_key/1)
    |> Enum.reduce({[], []}, fn {_key, grouped}, {ambiguous, unique} ->
      case grouped do
        [candidate] ->
          {ambiguous, [candidate | unique]}

        candidates ->
          device_uids = candidates |> Enum.map(& &1.device_uid) |> Enum.sort()

          conflicts =
            Enum.map(candidates, fn candidate ->
              candidate
              |> Map.put(:status, :conflict)
              |> Map.put(:reason, :duplicate_serial_in_batch)
              |> Map.put(:conflicting_device_uids, device_uids)
            end)

          {conflicts ++ ambiguous, unique}
      end
    end)
  end

  defp classify_existing_owner(candidate, owners) do
    case Map.get(owners, identifier_key(candidate)) do
      nil ->
        candidate

      owner when owner == candidate.device_uid ->
        candidate
        |> Map.put(:status, :already_registered)
        |> Map.put(:reason, :same_owner)

      owner ->
        candidate
        |> Map.put(:status, :conflict)
        |> Map.put(:reason, :identifier_owned_by_another_device)
        |> Map.put(:existing_owner_uid, owner)
    end
  end

  defp execute_entry(entry, actor, registrar) do
    case registrar.(entry, actor) do
      :ok ->
        %{entry | status: :registered, reason: nil}

      {:ok, :already_registered} ->
        %{entry | status: :already_registered, reason: :same_owner}

      {:error, {:identifier_owned_by, owner}} ->
        entry
        |> Map.put(:status, :conflict)
        |> Map.put(:reason, :identifier_owned_by_another_device)
        |> Map.put(:existing_owner_uid, owner)

      {:error, _reason} ->
        %{entry | status: :error, reason: :identifier_registration_failed}

      _other ->
        %{entry | status: :error, reason: :invalid_registrar_result}
    end
  end

  defp register_identifier(entry, _actor) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    record = %{
      device_id: entry.device_uid,
      identifier_type: :hardware_serial,
      identifier_value: entry.identifier_value,
      partition: entry.partition,
      confidence: :strong,
      source: @source,
      verified: false,
      first_seen: now,
      last_seen: now,
      metadata: %{
        "backfill" => "hardware_serial_v1",
        "canonical_device_uid" => entry.device_uid,
        "hardware_serial_namespace" => entry.vendor_namespace,
        "hardware_serial_normalized" => entry.normalized_serial,
        "prior_evidence" => entry.prior_evidence
      }
    }

    {inserted, _rows} =
      Repo.insert_all(DeviceIdentifier, [record],
        on_conflict: :nothing,
        conflict_target: [:identifier_type, :identifier_value, :partition]
      )

    if inserted == 1 do
      CardinalityCaps.enforce([{entry.device_uid, :hardware_serial}])
      :ok
    else
      existing_owner(entry)
    end
  end

  defp existing_owner(entry) do
    owner =
      Repo.one(
        from(identifier in DeviceIdentifier,
          where:
            identifier.identifier_type == :hardware_serial and
              identifier.identifier_value == ^entry.identifier_value and
              identifier.partition == ^entry.partition,
          select: identifier.device_id
        )
      )

    if owner == entry.device_uid,
      do: {:ok, :already_registered},
      else: {:error, {:identifier_owned_by, owner}}
  end

  defp load_devices(limit, after_uid) do
    query =
      from(device in Device,
        where: is_nil(device.deleted_at),
        order_by: [asc: device.uid],
        limit: ^limit,
        select: %{
          uid: device.uid,
          vendor_name: device.vendor_name,
          metadata: device.metadata,
          hw_info: device.hw_info,
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
            where:
              identifier.identifier_type == :hardware_serial and
                identifier.identifier_value in ^values,
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

  defp serial_update(device) do
    metadata = map_value(device, :metadata)

    metadata =
      case string_value(device, :vendor_name) do
        nil -> metadata
        vendor -> Map.put_new(metadata, "vendor_name", vendor)
      end

    %{metadata: metadata, hw_info: map_value(device, :hw_info)}
  end

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

  defp rejected_entry(uid, partition, reason, device) do
    %{
      device_uid: uid,
      partition: partition,
      identifier_value: nil,
      prior_evidence: prior_evidence(device),
      status: :skipped,
      reason: reason
    }
  end

  defp prior_evidence(device) do
    metadata = map_value(device, :metadata)
    hw_info = map_value(device, :hw_info)

    %{
      "vendor_name" =>
        string_value(device, :vendor_name) || first_string(metadata, ["vendor_name", "vendor"]),
      "serial_number" =>
        first_string(metadata, ["serial_number", "serial", "chassis_serial"]) ||
          first_string(hw_info, ["serial_number", "serial", "chassis_serial"]),
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

    :sha256
    |> :crypto.hash(Jason.encode!(payload))
    |> Base.encode16(case: :lower)
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
      trimmed -> String.slice(trimmed, 0, 160)
    end
  end

  defp normalize_after_uid(_value), do: nil

  defp normalize_loader_result({:ok, result}), do: {:ok, result}
  defp normalize_loader_result({:error, _reason} = error), do: error
  defp normalize_loader_result(result) when is_list(result) or is_map(result), do: {:ok, result}
  defp normalize_loader_result(_result), do: {:error, :invalid_backfill_loader_result}

  defp map_value(map, key) when is_map(map) do
    case value(map, key) do
      nested when is_map(nested) -> nested
      _ -> %{}
    end
  end

  defp string_value(map, key) do
    case value(map, key) do
      text when is_binary(text) -> text |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        text when is_binary(text) -> text |> String.trim() |> blank_to_nil()
        _ -> nil
      end
    end)
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
