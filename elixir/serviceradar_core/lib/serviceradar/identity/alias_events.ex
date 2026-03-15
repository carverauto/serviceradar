defmodule ServiceRadar.Identity.AliasEvents do
  @moduledoc """
  Device alias lifecycle event tracking.

  Ported from Go core's alias_events.go and pkg/devicealias/alias.go.
  Tracks changes to device alias metadata (service IDs, IPs, collectors)
  and generates lifecycle events for audit/alerting purposes.

  ## Alias Metadata Keys

  - `_alias_last_seen_at` - Timestamp of last alias update
  - `_alias_collector_ip` - IP of the collector that last saw the device
  - `_alias_last_seen_service_id` - Most recent service ID
  - `_alias_last_seen_ip` - Most recent IP address
  - `service_alias:<id>` - Service ID -> timestamp mapping
  - `ip_alias:<ip>` - IP -> timestamp mapping

  ## Usage

      # Build alias lifecycle events from device updates
      {:ok, events} = AliasEvents.build_lifecycle_events(updates)

      # Parse alias record from metadata
      record = AliasEvents.AliasRecord.from_metadata(metadata)

      # Check for alias changes
      changed? = AliasEvents.alias_change_detected?(previous, current)
  """

  require Ash.Query
  require Logger

  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device

  defmodule AliasRecord do
    @moduledoc """
    Represents alias metadata extracted from device records.
    """

    @type t :: %__MODULE__{
            last_seen_at: String.t() | nil,
            collector_ip: String.t() | nil,
            current_service_id: String.t() | nil,
            current_ip: String.t() | nil,
            services: %{String.t() => String.t()},
            ips: %{String.t() => String.t()}
          }

    defstruct [
      :last_seen_at,
      :collector_ip,
      :current_service_id,
      :current_ip,
      services: %{},
      ips: %{}
    ]

    @doc """
    Construct an AliasRecord from metadata map.

    Returns nil if no alias fields are present.
    """
    @spec from_metadata(map() | nil) :: t() | nil
    def from_metadata(nil), do: nil
    def from_metadata(metadata) when map_size(metadata) == 0, do: nil

    def from_metadata(metadata) when is_map(metadata) do
      record = build_alias_record(metadata)
      {services, ips} = build_alias_maps(metadata, record)
      record = %{record | services: services, ips: ips}

      if empty?(record), do: nil, else: record
    end

    @doc """
    Check if two AliasRecords are equal (order-insensitive).
    """
    @spec equal?(t() | nil, t() | nil) :: boolean()
    def equal?(nil, nil), do: true
    def equal?(nil, _), do: false
    def equal?(_, nil), do: false

    def equal?(a, b) do
      trim_or_nil(a.last_seen_at) == trim_or_nil(b.last_seen_at) and
        trim_or_nil(a.collector_ip) == trim_or_nil(b.collector_ip) and
        trim_or_nil(a.current_service_id) == trim_or_nil(b.current_service_id) and
        trim_or_nil(a.current_ip) == trim_or_nil(b.current_ip) and
        maps_equal?(a.services, b.services) and
        maps_equal?(a.ips, b.ips)
    end

    @doc """
    Format a map as a deterministic string for logging.
    """
    @spec format_map(%{String.t() => String.t()}) :: String.t()
    def format_map(values) when map_size(values) == 0, do: ""

    def format_map(values) do
      values
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",", fn {k, v} ->
        trimmed = String.trim(to_string(v))
        if trimmed != "", do: "#{k}=#{trimmed}", else: k
      end)
    end

    # Private helpers

    defp get_trimmed(map, key) do
      case Map.get(map, key) do
        nil -> nil
        value -> String.trim(to_string(value))
      end
    end

    defp build_alias_record(metadata) do
      %__MODULE__{
        last_seen_at: get_trimmed(metadata, "_alias_last_seen_at"),
        collector_ip: get_trimmed(metadata, "_alias_collector_ip"),
        current_service_id: get_trimmed(metadata, "_alias_last_seen_service_id"),
        current_ip: get_trimmed(metadata, "_alias_last_seen_ip"),
        services: %{},
        ips: %{}
      }
    end

    defp build_alias_maps(metadata, record) do
      services = seed_service_aliases(record, metadata)
      ips = seed_ip_aliases(record, metadata)

      Enum.reduce(metadata, {services, ips}, fn {key, value}, acc ->
        update_alias_maps(key, value, acc, record)
      end)
    end

    defp seed_service_aliases(record, metadata) do
      if record.current_service_id && record.current_service_id != "" do
        timestamp =
          get_trimmed(metadata, "service_alias:#{record.current_service_id}") ||
            record.last_seen_at

        %{record.current_service_id => timestamp}
      else
        %{}
      end
    end

    defp seed_ip_aliases(record, metadata) do
      if record.current_ip && record.current_ip != "" do
        timestamp =
          get_trimmed(metadata, "ip_alias:#{record.current_ip}") ||
            record.last_seen_at

        %{record.current_ip => timestamp}
      else
        %{}
      end
    end

    defp update_alias_maps(key, value, {svc_acc, ip_acc}, record) do
      cond do
        String.starts_with?(key, "service_alias:") ->
          update_service_alias(key, value, svc_acc, ip_acc, record)

        String.starts_with?(key, "ip_alias:") ->
          update_ip_alias(key, value, svc_acc, ip_acc, record)

        true ->
          {svc_acc, ip_acc}
      end
    end

    defp update_service_alias(key, value, svc_acc, ip_acc, record) do
      id = key |> String.replace_prefix("service_alias:", "") |> String.trim()

      if id != "" do
        timestamp =
          if String.trim(to_string(value)) != "",
            do: String.trim(to_string(value)),
            else: record.last_seen_at

        {Map.put(svc_acc, id, timestamp), ip_acc}
      else
        {svc_acc, ip_acc}
      end
    end

    defp update_ip_alias(key, value, svc_acc, ip_acc, record) do
      ip = key |> String.replace_prefix("ip_alias:", "") |> String.trim()

      if ip != "" do
        timestamp =
          if String.trim(to_string(value)) != "",
            do: String.trim(to_string(value)),
            else: record.last_seen_at

        {svc_acc, Map.put(ip_acc, ip, timestamp)}
      else
        {svc_acc, ip_acc}
      end
    end

    defp trim_or_nil(nil), do: nil
    defp trim_or_nil(s), do: String.trim(to_string(s))

    defp empty?(record) do
      blank?(record.last_seen_at) and
        blank?(record.collector_ip) and
        blank?(record.current_service_id) and
        blank?(record.current_ip) and
        map_size(record.services) == 0 and
        map_size(record.ips) == 0
    end

    defp blank?(nil), do: true
    defp blank?(s), do: String.trim(to_string(s)) == ""

    defp maps_equal?(a, b) when map_size(a) != map_size(b), do: false

    defp maps_equal?(a, b) do
      Enum.all?(a, fn {key, val_a} ->
        case Map.fetch(b, key) do
          {:ok, val_b} ->
            trim_or_nil(val_a) == trim_or_nil(val_b)

          :error ->
            false
        end
      end)
    end
  end

  @type device_update :: %{
          device_id: String.t(),
          partition: String.t() | nil,
          metadata: map(),
          timestamp: DateTime.t()
        }

  @type lifecycle_event :: %{
          device_id: String.t(),
          partition: String.t(),
          action: String.t(),
          reason: String.t(),
          timestamp: DateTime.t(),
          severity: String.t(),
          level: integer(),
          metadata: map()
        }

  @doc """
  Build alias lifecycle events from device updates.

  Compares new metadata against existing records and generates
  lifecycle events for any alias changes.
  """
  @spec build_lifecycle_events([device_update()], keyword()) ::
          {:ok, [lifecycle_event()]} | {:error, term()}
  def build_lifecycle_events(updates, opts \\ [])

  def build_lifecycle_events([], _opts), do: {:ok, []}

  def build_lifecycle_events(updates, opts) when is_list(updates) do
    # Filter updates with alias metadata and deduplicate by device_id (keep newest)
    alias_updates =
      updates
      |> Enum.filter(&has_alias_metadata?(&1.metadata))
      |> deduplicate_by_device_id()

    case alias_updates do
      [] ->
        {:ok, []}

      _ ->
        build_alias_events(alias_updates, opts)
    end
  end

  defp build_alias_events(alias_updates, opts) do
    device_ids = Enum.map(alias_updates, & &1.device_id) |> Enum.sort()
    existing_records = lookup_existing_alias_records(device_ids, opts)

    events =
      Enum.flat_map(alias_updates, fn update ->
        current = AliasRecord.from_metadata(update.metadata)
        previous = Map.get(existing_records, update.device_id)

        if alias_change_detected?(previous, current) do
          [build_alias_event(update, current, previous)]
        else
          []
        end
      end)

    {:ok, events}
  end

  @doc """
  Check if metadata contains alias-related keys.
  """
  @spec has_alias_metadata?(map() | nil) :: boolean()
  def has_alias_metadata?(nil), do: false
  def has_alias_metadata?(metadata) when map_size(metadata) == 0, do: false

  def has_alias_metadata?(metadata) do
    Enum.any?(metadata, fn {key, _value} ->
      key in [
        "_alias_last_seen_service_id",
        "_alias_last_seen_ip",
        "_alias_collector_ip"
      ] or
        String.starts_with?(key, "service_alias:") or
        String.starts_with?(key, "ip_alias:")
    end)
  end

  @doc """
  Detect if an alias change occurred between previous and current records.
  """
  @spec alias_change_detected?(AliasRecord.t() | nil, AliasRecord.t() | nil) :: boolean()
  def alias_change_detected?(nil, nil), do: false
  def alias_change_detected?(nil, _current), do: true
  def alias_change_detected?(_previous, nil), do: false

  def alias_change_detected?(previous, current) do
    # Check if any core field changed
    # Check if new keys were introduced
    trim(previous.current_service_id) != trim(current.current_service_id) or
      trim(previous.current_ip) != trim(current.current_ip) or
      trim(previous.collector_ip) != trim(current.collector_ip) or
      new_keys_introduced?(previous.services, current.services) or
      new_keys_introduced?(previous.ips, current.ips)
  end

  @doc """
  Process alias updates and persist to DeviceAliasState resource.

  This function:
  1. Detects new aliases
  2. Records sightings for existing aliases
  3. Triggers state transitions (confirm, mark_stale, etc.)
  4. Returns lifecycle events for audit

  ## Options

  - `:actor` - Actor for authorization context
  - `:confirm_threshold` - Sightings required to confirm (default: 3)
  """
  @spec process_and_persist([device_update()], keyword()) ::
          {:ok, [lifecycle_event()]} | {:error, term()}
  def process_and_persist(updates, opts \\ [])

  def process_and_persist([], _opts), do: {:ok, []}

  def process_and_persist(updates, opts) when is_list(updates) do
    actor = actor(opts)
    confirm_threshold = confirm_threshold(opts)
    events = build_device_alias_events(updates, actor, confirm_threshold)
    {:ok, events}
  end

  defp process_device_aliases(update, actor, confirm_threshold) do
    record = AliasRecord.from_metadata(update.metadata)

    record
    |> alias_values()
    |> Enum.flat_map(fn {type, value} ->
      case process_alias(update, type, value, actor, confirm_threshold) do
        nil -> []
        event -> [event]
      end
    end)
  end

  defp build_device_alias_events(updates, actor, confirm_threshold) do
    updates
    |> Enum.filter(&has_alias_metadata?(&1.metadata))
    |> deduplicate_by_device_id()
    |> Enum.flat_map(fn update ->
      process_device_aliases(update, actor, confirm_threshold)
    end)
  end

  defp alias_values(nil), do: []

  defp alias_values(record) do
    base =
      [
        {:ip, record.current_ip},
        {:service_id, record.current_service_id},
        {:collector_ip, record.collector_ip}
      ]
      |> Enum.reject(fn {_type, value} -> is_nil(value) or value == "" end)

    ip_aliases =
      record.ips
      |> Map.keys()
      |> Enum.map(&{:ip, &1})

    (base ++ ip_aliases)
    |> Enum.uniq()
  end

  defp process_alias(update, alias_type, alias_value, actor, confirm_threshold) do
    # Try to find existing alias
    case lookup_alias_state(alias_type, alias_value, actor) do
      {:ok, [existing | _]} ->
        # Record sighting and maybe transition state
        handle_existing_alias(existing, update, confirm_threshold, actor)

      {:ok, []} ->
        # Create new alias
        handle_new_alias(update, alias_type, alias_value, actor)

      {:error, _reason} ->
        nil
    end
  end

  defp handle_existing_alias(existing, _update, confirm_threshold, actor) do
    # Record the sighting
    case DeviceAliasState.record_sighting(
           existing,
           %{confirm_threshold: confirm_threshold},
           actor: actor
         ) do
      {:ok, updated} ->
        # Generate event if state changed
        if updated.state != existing.state do
          lifecycle_event(
            existing.device_id,
            existing.partition || "",
            action: "alias_state_changed",
            reason: "state_transition",
            timestamp: now(),
            metadata: %{
              "alias_type" => to_string(existing.alias_type),
              "alias_value" => existing.alias_value,
              "previous_state" => to_string(existing.state),
              "new_state" => to_string(updated.state),
              "sighting_count" => to_string(updated.sighting_count)
            }
          )
        else
          nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp handle_new_alias(update, alias_type, alias_value, actor) do
    partition = pick_partition(update.partition, update.device_id)

    attrs = %{
      device_id: update.device_id,
      partition: partition,
      alias_type: alias_type,
      alias_value: alias_value,
      metadata: %{
        "source" => "alias_detection",
        "first_update_timestamp" => DateTime.to_iso8601(update_timestamp(update.timestamp))
      }
    }

    case DeviceAliasState.create_detected(attrs, actor: actor) do
      {:ok, _created} ->
        lifecycle_event(
          update.device_id,
          partition,
          action: "alias_detected",
          reason: "new_alias",
          timestamp: now(),
          metadata: %{
            "alias_type" => to_string(alias_type),
            "alias_value" => alias_value
          }
        )

      {:error, _reason} ->
        nil
    end
  end

  # Private helpers

  defp deduplicate_by_device_id(updates) do
    updates
    |> Enum.group_by(& &1.device_id)
    |> Enum.map(fn {_device_id, grouped} ->
      # Keep the newest update; nil timestamps sort oldest.
      Enum.max_by(grouped, &sortable_timestamp(&1.timestamp), DateTime)
    end)
  end

  defp sortable_timestamp(nil), do: ~U[1970-01-01 00:00:00Z]
  defp sortable_timestamp(%DateTime{} = ts), do: ts
  defp sortable_timestamp(_), do: ~U[1970-01-01 00:00:00Z]

  defp lookup_existing_alias_records(device_ids, opts) do
    # Query devices and extract alias records from metadata
    case Device
         |> Ash.Query.filter(uid in ^device_ids)
         |> Ash.read(actor: actor(opts)) do
      {:ok, devices} ->
        devices
        |> Enum.map(fn device ->
          record = AliasRecord.from_metadata(device.metadata || %{})
          {String.trim(device.uid), record}
        end)
        |> Enum.reject(fn {_uid, record} -> is_nil(record) end)
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  defp build_alias_event(update, current, previous) do
    lifecycle_event(
      update.device_id,
      pick_partition(update.partition, update.device_id),
      action: "alias_updated",
      reason: "alias_change",
      timestamp: update_timestamp(update.timestamp),
      severity: "Low",
      metadata: build_alias_event_metadata(current, previous)
    )
  end

  defp build_alias_event_metadata(current, previous) do
    metadata =
      %{}
      |> maybe_put("alias_last_seen_at", current.last_seen_at)
      |> maybe_put("alias_current_service_id", current.current_service_id)
      |> maybe_put("alias_current_ip", current.current_ip)
      |> maybe_put("alias_collector_ip", current.collector_ip)
      |> maybe_put_map("alias_services", current.services, &AliasRecord.format_map/1)
      |> maybe_put_map("alias_ips", current.ips, &AliasRecord.format_map/1)

    if previous do
      metadata
      |> maybe_add_previous(
        "previous_service_id",
        previous.current_service_id,
        current.current_service_id
      )
      |> maybe_add_previous("previous_ip", previous.current_ip, current.current_ip)
      |> maybe_add_previous(
        "previous_collector_ip",
        previous.collector_ip,
        current.collector_ip
      )
    else
      metadata
    end
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, _key, ""), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_map(metadata, _key, values, _formatter) when map_size(values) == 0, do: metadata

  defp maybe_put_map(metadata, key, values, formatter) do
    Map.put(metadata, key, formatter.(values))
  end

  defp maybe_add_previous(metadata, key, prev, curr) do
    prev_trimmed = trim(prev)
    curr_trimmed = trim(curr)

    if prev_trimmed != "" and prev_trimmed != curr_trimmed do
      Map.put(metadata, key, prev_trimmed)
    else
      metadata
    end
  end

  defp pick_partition(partition, device_id) do
    partition = String.trim(to_string(partition || ""))

    if partition != "" do
      partition
    else
      case String.split(device_id || "", ":", parts: 2) do
        [part, _rest] when part != "" -> String.trim(part)
        _ -> ""
      end
    end
  end

  defp actor(opts), do: Keyword.get(opts, :actor)
  defp confirm_threshold(opts), do: Keyword.get(opts, :confirm_threshold, 3)

  defp lookup_alias_state(alias_type, alias_value, actor) do
    DeviceAliasState.lookup_by_value(alias_type, alias_value, actor: actor)
  end

  defp lifecycle_event(device_id, partition, opts) do
    %{
      device_id: device_id,
      partition: partition,
      action: Keyword.fetch!(opts, :action),
      reason: Keyword.fetch!(opts, :reason),
      timestamp: Keyword.fetch!(opts, :timestamp),
      severity: Keyword.get(opts, :severity, "Info"),
      level: Keyword.get(opts, :level, 6),
      metadata: Keyword.fetch!(opts, :metadata)
    }
  end

  defp now, do: DateTime.utc_now()

  defp update_timestamp(nil), do: DateTime.utc_now()

  defp update_timestamp(%DateTime{} = ts), do: ts

  defp update_timestamp(_), do: DateTime.utc_now()

  defp new_keys_introduced?(previous, current) do
    Enum.any?(current, fn {key, _} ->
      not Map.has_key?(previous, key)
    end)
  end

  defp trim(nil), do: ""
  defp trim(s), do: String.trim(to_string(s))
end
