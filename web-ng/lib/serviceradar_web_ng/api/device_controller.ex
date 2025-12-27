defmodule ServiceRadarWebNG.Api.DeviceController do
  @moduledoc """
  Device API controller using Ash resources.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Inventory.Device

  require Ash.Query

  @default_limit 100
  @max_limit 500
  @max_offset 100_000

  def index(conn, params) do
    case parse_index_params(params) do
      {:ok, opts} ->
        devices = list_devices(opts)

        json(conn, %{
          "data" => Enum.map(devices, &device_to_map/1),
          "pagination" => build_pagination(devices, opts)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  def show(conn, %{"uid" => uid}) do
    case parse_uid(uid) do
      {:ok, parsed_uid} ->
        case Device.get_by_uid(parsed_uid, authorize?: false) do
          {:ok, device} ->
            json(conn, %{"data" => device_to_map(device)})

          {:error, %Ash.Error.Query.NotFound{}} ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => "device not found"})

          {:error, _} ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => "device not found"})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "missing required path param: uid"})
  end

  @doc """
  Export devices in OCSF v1.7.0 Device object format.
  Supports filtering by type_id, time range, and pagination.

  Query params:
  - type_id: Filter by OCSF device type_id (integer)
  - first_seen_after: Filter devices first seen after this ISO8601 timestamp
  - last_seen_after: Filter devices last seen after this ISO8601 timestamp
  - limit: Max devices to return (default 100, max 1000)
  - offset: Pagination offset (default 0)
  """
  def ocsf_export(conn, params) do
    case parse_export_params(params) do
      {:ok, opts} ->
        devices = list_devices_for_export(opts)

        json(conn, %{
          "ocsf_version" => "1.7.0",
          "class_uid" => 5001,
          "class_name" => "Device Inventory Info",
          "devices" => Enum.map(devices, &device_to_ocsf_export/1),
          "count" => length(devices),
          "pagination" => build_export_pagination(devices, opts)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  defp parse_export_params(params) when is_map(params) do
    with {:ok, limit} <- parse_export_limit(Map.get(params, "limit"), 100, 1000),
         {:ok, offset} <- parse_offset_value(Map.get(params, "offset", 0)),
         {:ok, type_id} <- parse_optional_int(Map.get(params, "type_id")),
         {:ok, first_seen_after} <- parse_optional_datetime(Map.get(params, "first_seen_after")),
         {:ok, last_seen_after} <- parse_optional_datetime(Map.get(params, "last_seen_after")) do
      {:ok,
       %{
         limit: limit,
         offset: offset,
         type_id: type_id,
         first_seen_after: first_seen_after,
         last_seen_after: last_seen_after
       }}
    end
  end

  defp parse_export_params(_), do: {:error, "invalid query params"}

  defp parse_export_limit(nil, default, _max), do: {:ok, default}
  defp parse_export_limit("", default, _max), do: {:ok, default}

  defp parse_export_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, max)}
  end

  defp parse_export_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} when value > 0 -> parse_export_limit(value, default, max)
      _ -> {:error, "invalid limit"}
    end
  end

  defp parse_export_limit(_limit, _default, _max), do: {:error, "invalid limit"}

  defp parse_optional_int(nil), do: {:ok, nil}
  defp parse_optional_int(""), do: {:ok, nil}

  defp parse_optional_int(value) when is_integer(value), do: {:ok, value}

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, "invalid integer value"}
    end
  end

  defp parse_optional_int(_), do: {:error, "invalid integer value"}

  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(""), do: {:ok, nil}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "invalid datetime format (use ISO8601)"}
    end
  end

  defp parse_optional_datetime(_), do: {:error, "invalid datetime value"}

  defp list_devices_for_export(opts) do
    Device
    |> Ash.Query.sort(last_seen_time: :desc)
    |> Ash.Query.limit(opts.limit)
    |> Ash.Query.offset(opts.offset)
    |> maybe_filter_type_id(opts.type_id)
    |> maybe_filter_first_seen_after(opts.first_seen_after)
    |> maybe_filter_last_seen_after(opts.last_seen_after)
    |> Ash.read!(authorize?: false)
  end

  defp maybe_filter_type_id(query, nil), do: query
  defp maybe_filter_type_id(query, type_id), do: Ash.Query.filter(query, type_id == ^type_id)

  defp maybe_filter_first_seen_after(query, nil), do: query
  defp maybe_filter_first_seen_after(query, dt), do: Ash.Query.filter(query, first_seen_time >= ^dt)

  defp maybe_filter_last_seen_after(query, nil), do: query
  defp maybe_filter_last_seen_after(query, dt), do: Ash.Query.filter(query, last_seen_time >= ^dt)

  defp build_export_pagination(devices, %{limit: limit, offset: offset}) do
    next_offset = if length(devices) >= limit, do: offset + limit, else: nil

    %{
      "limit" => limit,
      "offset" => offset,
      "next_offset" => next_offset
    }
  end

  defp device_to_ocsf_export(device) do
    %{
      # OCSF Core Identity
      "uid" => device.uid,
      "type_id" => device.type_id,
      "type" => device.type,
      "name" => device.name,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "mac" => device.mac,
      # OCSF Extended Identity
      "uid_alt" => device.uid_alt,
      "vendor_name" => device.vendor_name,
      "model" => device.model,
      "domain" => device.domain,
      "zone" => device.zone,
      "subnet_uid" => device.subnet_uid,
      "vlan_uid" => device.vlan_uid,
      "region" => device.region,
      # OCSF Temporal
      "first_seen_time" => normalize_value(device.first_seen_time),
      "last_seen_time" => normalize_value(device.last_seen_time),
      "created_time" => normalize_value(device.created_time),
      "modified_time" => normalize_value(device.modified_time),
      # OCSF Risk and Compliance
      "risk_level_id" => device.risk_level_id,
      "risk_level" => device.risk_level,
      "risk_score" => device.risk_score,
      "is_managed" => device.is_managed,
      "is_compliant" => device.is_compliant,
      "is_trusted" => device.is_trusted,
      # OCSF Nested Objects
      "os" => device.os,
      "hw_info" => device.hw_info,
      "network_interfaces" => device.network_interfaces,
      "owner" => device.owner,
      "org" => device.org,
      "groups" => device.groups,
      "agent_list" => device.agent_list
    }
  end

  defp list_devices(opts) do
    Device
    |> Ash.Query.sort(last_seen_time: :desc)
    |> Ash.Query.limit(opts.limit)
    |> Ash.Query.offset(opts.offset)
    |> maybe_filter_search(opts.search)
    |> maybe_filter_status(opts.status)
    |> maybe_filter_poller_id(opts.poller_id)
    |> maybe_filter_device_type(opts.device_type)
    |> Ash.read!(authorize?: false)
  end

  defp parse_index_params(params) when is_map(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit"), @default_limit),
         {:ok, offset} <- parse_offset(params, limit),
         {:ok, search} <- parse_optional_string(Map.get(params, "search")),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, poller_id} <- parse_optional_string(Map.get(params, "poller_id")),
         {:ok, device_type} <- parse_optional_string(Map.get(params, "device_type")) do
      {:ok,
       %{
         limit: limit,
         offset: offset,
         search: search,
         status: status,
         poller_id: poller_id,
         device_type: device_type
       }}
    end
  end

  defp parse_index_params(_), do: {:error, "invalid query params"}

  defp parse_limit(nil, default), do: {:ok, default}
  defp parse_limit("", default), do: {:ok, default}

  defp parse_limit(limit, _default) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, @max_limit)}
  end

  defp parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} when value > 0 -> parse_limit(value, default)
      _ -> {:error, "invalid limit"}
    end
  end

  defp parse_limit(_limit, _default), do: {:error, "invalid limit"}

  defp parse_offset(params, limit) when is_map(params) and is_integer(limit) do
    offset = Map.get(params, "offset")
    page = Map.get(params, "page")

    cond do
      not is_nil(offset) ->
        parse_offset_value(offset)

      not is_nil(page) ->
        with {:ok, page} <- parse_page(page) do
          parse_offset_value((page - 1) * limit)
        end

      true ->
        {:ok, 0}
    end
  end

  defp parse_offset(_params, _limit), do: {:error, "invalid pagination params"}

  defp parse_offset_value(value) when is_integer(value) and value >= 0 do
    if value <= @max_offset, do: {:ok, value}, else: {:error, "offset too large"}
  end

  defp parse_offset_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {value, ""} -> parse_offset_value(value)
      _ -> {:error, "invalid offset"}
    end
  end

  defp parse_offset_value(_), do: {:error, "invalid offset"}

  defp parse_page(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, "invalid page"}
    end
  end

  defp parse_page(_), do: {:error, "invalid page"}

  defp parse_optional_string(nil), do: {:ok, nil}

  defp parse_optional_string(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.slice(0, 200)

    if value == "", do: {:ok, nil}, else: {:ok, value}
  end

  defp parse_optional_string(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp parse_optional_string(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp parse_optional_string(_), do: {:error, "invalid string param"}

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(value) when is_binary(value) do
    value = value |> String.downcase() |> String.trim()

    case value do
      "online" -> {:ok, :online}
      "offline" -> {:ok, :offline}
      "available" -> {:ok, :online}
      "unavailable" -> {:ok, :offline}
      other -> {:error, "invalid status: #{other}"}
    end
  end

  defp parse_status(_), do: {:error, "invalid status"}

  defp parse_uid(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "invalid uid"}

      String.length(value) > 200 ->
        {:error, "invalid uid"}

      Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9:._-]*$/, value) ->
        {:ok, value}

      true ->
        {:error, "invalid uid"}
    end
  end

  defp parse_uid(_), do: {:error, "invalid uid"}

  defp maybe_filter_search(query, nil), do: query

  defp maybe_filter_search(query, search) when is_binary(search) do
    like = "%#{escape_like(search)}%"
    # Use Ash fragment for ILIKE since it's PostgreSQL-specific
    Ash.Query.filter(query, fragment("? ILIKE ? OR ? ILIKE ? OR ? ILIKE ?",
      hostname, ^like, ip, ^like, uid, ^like))
  end

  defp maybe_filter_search(query, _), do: query

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, :online), do: Ash.Query.filter(query, is_available == true)
  defp maybe_filter_status(query, :offline), do: Ash.Query.filter(query, is_available == false)
  defp maybe_filter_status(query, _), do: query

  defp maybe_filter_poller_id(query, nil), do: query
  defp maybe_filter_poller_id(query, poller_id), do: Ash.Query.filter(query, poller_id == ^poller_id)

  defp maybe_filter_device_type(query, nil), do: query
  defp maybe_filter_device_type(query, device_type), do: Ash.Query.filter(query, type == ^device_type)

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp build_pagination(devices, %{limit: limit, offset: offset}) do
    next_offset = if length(devices) >= limit, do: offset + limit, else: nil

    %{
      "limit" => limit,
      "offset" => offset,
      "next_offset" => next_offset
    }
  end

  defp device_to_map(device) do
    %{
      # Primary identifier (OCSF uid)
      "uid" => device.uid,
      # OCSF Core Identity
      "type_id" => device.type_id,
      "type" => device.type,
      "name" => device.name,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "mac" => device.mac,
      # OCSF Extended Identity
      "uid_alt" => device.uid_alt,
      "vendor_name" => device.vendor_name,
      "model" => device.model,
      "domain" => device.domain,
      "zone" => device.zone,
      "subnet_uid" => device.subnet_uid,
      "vlan_uid" => device.vlan_uid,
      "region" => device.region,
      # OCSF Temporal (with backward-compatible aliases)
      "first_seen_time" => normalize_value(device.first_seen_time),
      "last_seen_time" => normalize_value(device.last_seen_time),
      "first_seen" => normalize_value(device.first_seen_time),
      "last_seen" => normalize_value(device.last_seen_time),
      "created_time" => normalize_value(device.created_time),
      "modified_time" => normalize_value(device.modified_time),
      # OCSF Risk and Compliance
      "risk_level_id" => device.risk_level_id,
      "risk_level" => device.risk_level,
      "risk_score" => device.risk_score,
      "is_managed" => device.is_managed,
      "is_compliant" => device.is_compliant,
      "is_trusted" => device.is_trusted,
      # OCSF Nested Objects
      "os" => device.os,
      "hw_info" => device.hw_info,
      "network_interfaces" => device.network_interfaces,
      "owner" => device.owner,
      "org" => device.org,
      "groups" => device.groups,
      "agent_list" => device.agent_list,
      # ServiceRadar-specific fields
      "poller_id" => device.poller_id,
      "agent_id" => device.agent_id,
      "discovery_sources" => device.discovery_sources,
      "is_available" => device.is_available,
      "metadata" => device.metadata
    }
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(value), do: value
end
