defmodule ServiceRadarWebNGWeb.Observability.EventDeviceReference do
  @moduledoc """
  Extracts and resolves the affected inventory device for an observability event.

  Device-scoped signals encode the affected device inside their signal/condition
  key. For example a Proxmox guest bottleneck emits a condition key such as:

      proxmox:guest_memory:sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85:qemu:116

  Here the canonical device uid is `sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85`
  (the `sr:` scheme prefix is part of the uid) and `qemu:116` identifies the
  guest for display.

  This module keeps that link actionable:

    * `extract/1` returns the device uid (and any guest label) without touching
      the database. It prefers a structured device field when the event carries
      one, then decodes an anomaly finding series key, then falls back to a
      regex over the condition key. It only returns a uid when a canonical
      `sr:<uuid>` value is confidently found, so signals that do not reference a
      device return `nil` (no broken link).
    * `resolve/2` runs `extract/1` and additionally looks up a human-readable
      device name via the scoped Ash read path used elsewhere in web-ng. The
      lookup is best-effort: an unresolvable (deleted/unknown) device still
      yields a reference so the caller can link by uid.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNGWeb.AnomalySeriesKey

  require Logger

  # Canonical device uids are `sr:` + a v4 UUID. `@uid_scan` finds one embedded
  # in a larger key; `@uid_exact` validates a standalone structured value.
  @uid_body "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  @uid_scan Regex.compile!("sr:" <> @uid_body)
  @uid_exact Regex.compile!("\\Asr:" <> @uid_body <> "\\z")
  @guest_scan ~r/\b(qemu|lxc):(\d+)\b/

  # Structured device fields, checked in priority order. Only canonical `sr:`
  # uids are accepted so a raw hostname/agent id in one of these fields is
  # ignored rather than turned into a broken device link.
  @structured_paths [
    ["device_uid"],
    ["device_id"],
    ["metadata", "service_radar", "device_uid"],
    ["metadata", "service_radar", "device_id"],
    ["metadata", "device_uid"],
    ["metadata", "device_id"]
  ]

  # Anomaly findings carry their device identity inside a hex-encoded series key
  # rather than a plain condition key, so they are decoded separately.
  @series_key_paths [
    ["metadata", "detection_finding", "series_key"],
    ["unmapped", "detection_finding", "series_key"],
    ["unmapped", "anomaly", "series_key"]
  ]

  @condition_key_paths [
    ["unmapped", "condition_key"],
    ["metadata", "condition_key"],
    ["condition_key"]
  ]

  @type t :: %{
          uid: String.t(),
          guest: String.t() | nil,
          via: :structured | :anomaly_series_key | :condition_key
        }

  @doc """
  Extract a device reference from an event map. Returns `nil` when no canonical
  device uid can be confidently determined. Never raises and never hits the DB.
  """
  @spec extract(map()) :: t() | nil
  def extract(event) when is_map(event) do
    condition_key = first_binary(event, @condition_key_paths)
    guest = guest_label(condition_key)

    cond do
      uid = explicit_structured_uid(event) ->
        %{uid: uid, guest: guest, via: :structured}

      uid = anomaly_identity_uid(event) ->
        %{uid: uid, guest: guest, via: :anomaly_series_key}

      uid = uid_from_key(condition_key) ->
        %{uid: uid, guest: guest, via: :condition_key}

      true ->
        nil
    end
  end

  def extract(_event), do: nil

  @doc """
  Extract a device reference and enrich it with a resolved device name.

  Returns `nil` when no uid is found. Otherwise returns the `extract/1` map with
  an added `:hostname` key (the resolved device hostname/name, or `nil` when the
  device cannot be read). RBAC is enforced by passing the caller `scope` to the
  Ash read.
  """
  @spec resolve(map(), term()) :: map() | nil
  def resolve(event, scope) do
    case extract(event) do
      nil -> nil
      %{uid: uid} = ref -> Map.put(ref, :hostname, lookup_hostname(uid, scope))
    end
  end

  defp lookup_hostname(uid, scope) do
    case Device.get_by_uid(uid, false, scope: scope) do
      {:ok, %Device{} = device} -> device_name(device)
      _ -> nil
    end
  rescue
    error ->
      Logger.debug("EventDeviceReference device lookup failed: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.debug("EventDeviceReference device lookup failed: #{inspect({kind, reason})}")
      nil
  end

  defp device_name(%Device{} = device) do
    Enum.find([Map.get(device, :hostname), Map.get(device, :name)], fn value ->
      is_binary(value) and String.trim(value) != ""
    end)
  end

  defp explicit_structured_uid(event) do
    Enum.find_value(@structured_paths, fn path -> canonical_uid(dig(event, path)) end)
  end

  defp anomaly_identity_uid(event) do
    Enum.find_value(@series_key_paths, fn path ->
      case AnomalySeriesKey.decode(dig(event, path)) do
        %{} = decoded -> canonical_uid(AnomalySeriesKey.component(decoded, "identity"))
        _ -> nil
      end
    end)
  end

  defp uid_from_key(key) when is_binary(key) do
    case Regex.run(@uid_scan, key) do
      [uid | _] -> uid
      _ -> nil
    end
  end

  defp uid_from_key(_key), do: nil

  defp guest_label(key) when is_binary(key) do
    case Regex.run(@guest_scan, key) do
      [match | _] -> match
      _ -> nil
    end
  end

  defp guest_label(_key), do: nil

  defp canonical_uid(value) when is_binary(value) do
    if Regex.match?(@uid_exact, value), do: value
  end

  defp canonical_uid(_value), do: nil

  defp first_binary(event, paths) do
    Enum.find_value(paths, fn path ->
      case dig(event, path) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  # Fetch a nested value tolerating both string and (existing) atom keys, since
  # SRQL rows are string-keyed but structured/PubSub events may be atom-keyed.
  defp dig(value, []), do: value

  defp dig(map, [key | rest]) when is_map(map) and is_binary(key) do
    case fetch_key(map, key) do
      {:ok, value} -> dig(value, rest)
      :error -> nil
    end
  end

  defp dig(_value, _path), do: nil

  defp fetch_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        try do
          Map.fetch(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> :error
        end
    end
  end
end
