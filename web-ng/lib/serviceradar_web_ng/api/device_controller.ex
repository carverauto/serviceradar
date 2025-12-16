defmodule ServiceRadarWebNG.Api.DeviceController do
  use ServiceRadarWebNGWeb, :controller

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias ServiceRadarWebNG.Inventory.Device
  alias ServiceRadarWebNG.Repo

  @default_limit 100
  @max_limit 500
  @max_offset 100_000

  def index(conn, params) do
    with {:ok, opts} <- parse_index_params(params) do
      devices = list_devices(opts)

      json(conn, %{
        "data" => Enum.map(devices, &device_to_map/1),
        "pagination" => build_pagination(devices, opts)
      })
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  def show(conn, %{"device_id" => device_id}) do
    with {:ok, device_id} <- parse_device_id(device_id) do
      case Repo.get(Device, device_id) do
        %Device{} = device ->
          json(conn, %{"data" => device_to_map(device)})

        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{"error" => "device not found"})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "missing required path param: device_id"})
  end

  defp list_devices(opts) do
    query = from(d in Device, select: d)
    query = maybe_apply_search(query, Map.get(opts, :search))
    query = maybe_apply_status(query, Map.get(opts, :status))
    query = maybe_apply_poller_id(query, Map.get(opts, :poller_id))
    query = maybe_apply_device_type(query, Map.get(opts, :device_type))

    query =
      from(d in query,
        order_by: [desc: d.last_seen],
        limit: ^opts.limit,
        offset: ^opts.offset
      )

    Repo.all(query)
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

  defp parse_device_id(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "invalid device_id"}

      String.length(value) > 200 ->
        {:error, "invalid device_id"}

      Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9:._-]*$/, value) ->
        {:ok, value}

      true ->
        {:error, "invalid device_id"}
    end
  end

  defp parse_device_id(_), do: {:error, "invalid device_id"}

  defp maybe_apply_search(query, nil), do: query

  defp maybe_apply_search(query, search) when is_binary(search) do
    like = "%#{escape_like(search)}%"

    where = dynamic([d], ilike(d.hostname, ^like) or ilike(d.ip, ^like) or ilike(d.id, ^like))

    from(d in query, where: ^where)
  end

  defp maybe_apply_search(query, _), do: query

  defp maybe_apply_status(query, nil), do: query
  defp maybe_apply_status(query, :online), do: from(d in query, where: d.is_available == true)
  defp maybe_apply_status(query, :offline), do: from(d in query, where: d.is_available == false)
  defp maybe_apply_status(query, _), do: query

  defp maybe_apply_poller_id(query, nil), do: query

  defp maybe_apply_poller_id(query, poller_id) when is_binary(poller_id) do
    from(d in query, where: d.poller_id == ^poller_id)
  end

  defp maybe_apply_poller_id(query, _), do: query

  defp maybe_apply_device_type(query, nil), do: query

  defp maybe_apply_device_type(query, device_type) when is_binary(device_type) do
    from(d in query, where: d.device_type == ^device_type)
  end

  defp maybe_apply_device_type(query, _), do: query

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

  defp device_to_map(%Device{} = device) do
    %{
      "device_id" => device.id,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "poller_id" => device.poller_id,
      "agent_id" => device.agent_id,
      "mac" => device.mac,
      "discovery_sources" => device.discovery_sources,
      "is_available" => device.is_available,
      "first_seen" => normalize_value(device.first_seen),
      "last_seen" => normalize_value(device.last_seen),
      "metadata" => device.metadata,
      "device_type" => device.device_type,
      "service_type" => device.service_type,
      "service_status" => device.service_status,
      "last_heartbeat" => normalize_value(device.last_heartbeat),
      "os_info" => device.os_info,
      "version_info" => device.version_info,
      "updated_at" => normalize_value(device.updated_at)
    }
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(value), do: value
end
