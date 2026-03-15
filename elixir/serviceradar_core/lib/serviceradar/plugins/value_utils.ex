defmodule ServiceRadar.Plugins.ValueUtils do
  @moduledoc false

  alias ServiceRadar.Plugins.MapUtils

  @spec raw_value(map(), [atom() | String.t()]) :: term()
  def raw_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  @spec string_value(map(), [atom() | String.t()]) :: String.t() | nil
  def string_value(map, keys) when is_map(map) and is_list(keys) do
    case raw_value(map, keys) do
      nil ->
        nil

      value when is_binary(value) ->
        String.trim(value)

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        :erlang.float_to_binary(value)

      _ ->
        nil
    end
  end

  @spec int_value(map(), [atom() | String.t()], integer() | nil) :: integer() | nil
  def int_value(map, keys, default \\ nil) when is_map(map) and is_list(keys) do
    case raw_value(map, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  @spec bool_value(map(), [atom() | String.t()], boolean()) :: boolean()
  def bool_value(map, keys, default) when is_map(map) and is_list(keys) and is_boolean(default) do
    case raw_value(map, keys) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  @spec map_value(map(), [atom() | String.t()], keyword()) :: map() | nil
  def map_value(map, keys, opts \\ []) when is_map(map) and is_list(keys) do
    case raw_value(map, keys) do
      value when is_map(value) ->
        if Keyword.get(opts, :stringify_keys, false) do
          MapUtils.stringify_keys(value)
        else
          value
        end

      _ ->
        nil
    end
  end

  @spec list_value(map(), [atom() | String.t()]) :: list() | nil
  def list_value(map, keys) when is_map(map) and is_list(keys) do
    case raw_value(map, keys) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  @spec normalize_entity(term()) :: String.t()
  def normalize_entity(entity) when is_atom(entity),
    do: entity |> Atom.to_string() |> normalize_entity()

  def normalize_entity(entity) when is_binary(entity) do
    entity
    |> String.trim()
    |> String.downcase()
  end

  def normalize_entity(_), do: ""

  @spec blank_string?(term()) :: boolean()
  def blank_string?(value) when is_binary(value), do: String.trim(value) == ""
  def blank_string?(_), do: true
end
