defmodule ServiceRadarWebNG.Api.Access do
  @moduledoc """
  Shared read functions used by HTTP controllers and MCP tools.

  MCP must not grow a second query path. Callers pass `current_scope` and
  Ash is always authorized.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.SRQL.EntityAccess

  require Ash.Query

  @default_limit 100
  @max_limit 500
  @max_offset 100_000

  @uid_pattern ~r/^[A-Za-z0-9][A-Za-z0-9:._-]*$/

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec execute_query(term(), map()) :: {:ok, map()} | {:error, term()}
  def execute_query(scope, params) when is_map(params) do
    params = params |> stringify_keys() |> Map.put("scope", scope)

    with :ok <- EntityAccess.authorize(Map.get(params, "query"), scope) do
      srql_module().query_request(params)
    end
  end

  @spec srql_catalog(term()) :: map()
  def srql_catalog(scope) do
    case Application.fetch_env!(:serviceradar_web_ng, :srql_catalog) do
      {mod, fun} -> apply(mod, fun, [scope])
      fun when is_function(fun, 1) -> fun.(scope)
    end
  end

  @doc """
  Restrict a catalog payload to one entity. MCP agents should pass `entity`
  so they do not ingest the full ~50-entity map.
  """
  @spec slice_srql_catalog(map(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def slice_srql_catalog(catalog, entity) when entity in [nil, ""], do: {:ok, catalog}

  def slice_srql_catalog(catalog, entity) when is_binary(entity) do
    wanted = entity |> String.trim() |> String.downcase()
    entities = Map.get(catalog, "entities") || %{}

    case Enum.find(entities, fn {id, _meta} -> String.downcase(to_string(id)) == wanted end) do
      {id, meta} ->
        {:ok, Map.put(catalog, "entities", %{id => meta})}

      nil ->
        known =
          entities
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.sort()
          |> Enum.join(", ")

        {:error, "unknown SRQL entity #{inspect(entity)}. Known ids: #{known}"}
    end
  end

  def slice_srql_catalog(_catalog, _entity), do: {:error, "entity must be a string"}

  @spec list_devices(term(), map()) :: [struct()]
  def list_devices(scope, opts) when is_map(opts) do
    Device
    |> Ash.Query.sort(last_seen_time: :desc)
    |> maybe_filter_search(opts[:search])
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_gateway_id(opts[:gateway_id])
    |> maybe_filter_device_type(opts[:device_type])
    |> Ash.read!(
      scope: scope,
      page: [limit: opts[:limit] || @default_limit, offset: opts[:offset] || 0]
    )
    |> Map.fetch!(:results)
  end

  @spec get_device(term(), term()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, {:invalid, String.t()}}
  def get_device(scope, uid) do
    with {:ok, parsed} <- parse_uid(uid) do
      case Device.get_by_uid(parsed, false, scope: scope) do
        {:ok, device} -> {:ok, device}
        {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
        {:error, %Ash.Error.Forbidden{}} -> {:error, :not_found}
        {:error, _} -> {:error, :not_found}
      end
    end
  end

  @spec parse_uid(term()) :: {:ok, String.t()} | {:error, {:invalid, String.t()}}
  def parse_uid(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, {:invalid, "invalid uid"}}
      String.length(value) > 200 -> {:error, {:invalid, "invalid uid"}}
      Regex.match?(@uid_pattern, value) -> {:ok, value}
      true -> {:error, {:invalid, "invalid uid"}}
    end
  end

  def parse_uid(_), do: {:error, {:invalid, "invalid uid"}}

  @spec clamp_limit(term()) :: pos_integer()
  def clamp_limit(nil), do: @default_limit
  def clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  def clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} -> clamp_limit(value)
      _ -> @default_limit
    end
  end

  def clamp_limit(_), do: @default_limit

  @spec clamp_offset(term()) :: non_neg_integer()
  def clamp_offset(nil), do: 0
  def clamp_offset(offset) when is_integer(offset) and offset >= 0, do: min(offset, @max_offset)

  def clamp_offset(offset) when is_binary(offset) do
    case Integer.parse(String.trim(offset)) do
      {value, ""} -> clamp_offset(value)
      _ -> 0
    end
  end

  def clamp_offset(_), do: 0

  @spec device_to_map(struct()) :: map()
  def device_to_map(device) do
    %{
      "uid" => device.uid,
      "type" => device.type,
      "name" => device.name,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "mac" => device.mac,
      "vendor_name" => device.vendor_name,
      "gateway_id" => device.gateway_id,
      "is_available" => device.is_available,
      "last_seen_time" => normalize_value(device.last_seen_time),
      "first_seen_time" => normalize_value(device.first_seen_time)
    }
  end

  defp stringify_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp maybe_filter_search(query, nil), do: query
  defp maybe_filter_search(query, ""), do: query

  defp maybe_filter_search(query, search) when is_binary(search) do
    like = "%#{escape_like(search)}%"

    Ash.Query.filter(
      query,
      fragment("? ILIKE ? OR ? ILIKE ? OR ? ILIKE ?", hostname, ^like, ip, ^like, uid, ^like)
    )
  end

  defp maybe_filter_search(query, _), do: query

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, :online), do: Ash.Query.filter(query, is_available == true)
  defp maybe_filter_status(query, "online"), do: maybe_filter_status(query, :online)
  defp maybe_filter_status(query, :offline), do: Ash.Query.filter(query, is_available == false)
  defp maybe_filter_status(query, "offline"), do: maybe_filter_status(query, :offline)
  defp maybe_filter_status(query, _), do: query

  defp maybe_filter_gateway_id(query, nil), do: query
  defp maybe_filter_gateway_id(query, ""), do: query

  defp maybe_filter_gateway_id(query, gateway_id) when is_binary(gateway_id) do
    Ash.Query.filter(query, gateway_id == ^gateway_id)
  end

  defp maybe_filter_gateway_id(query, _), do: query

  defp maybe_filter_device_type(query, nil), do: query
  defp maybe_filter_device_type(query, ""), do: query

  defp maybe_filter_device_type(query, device_type) when is_binary(device_type) do
    Ash.Query.filter(query, type == ^device_type)
  end

  defp maybe_filter_device_type(query, _), do: query

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(value), do: value
end
