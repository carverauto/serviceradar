# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNG.Dashboards.Authored.Normalization do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      require Ash.Query

      defp fetch_slug(attrs) do
        attrs
        |> fetch_string([:slug, "slug"])
        |> case do
          nil -> nil
          slug -> slugify(slug)
        end
      end

      defp slugify(value) when is_binary(value) do
        value
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")
        |> case do
          "" -> nil
          slug -> slug
        end
      end

      defp fetch_string(map, keys) when is_map(map) do
        map
        |> fetch_value(keys)
        |> normalize_string()
      end

      defp fetch_string(_map, _keys), do: nil

      defp normalize_string(value) when is_binary(value) do
        value = String.trim(value)
        if value == "", do: nil, else: value
      end

      defp normalize_string(_value), do: nil

      defp fetch_map(map, keys) when is_map(map) do
        case fetch_value(map, keys) do
          value when is_map(value) -> value
          _ -> nil
        end
      end

      defp fetch_map(_map, _keys), do: nil

      defp fetch_integer(map, keys) when is_map(map) do
        case fetch_value(map, keys) do
          value when is_integer(value) ->
            value

          value when is_binary(value) ->
            case Integer.parse(String.trim(value)) do
              {int, ""} -> int
              _ -> nil
            end

          _ ->
            nil
        end
      end

      defp fetch_integer(_map, _keys), do: nil

      defp fetch_boolean(map, keys) when is_map(map) do
        case fetch_value(map, keys) do
          value when is_boolean(value) -> value
          value when is_binary(value) -> String.downcase(String.trim(value)) in ~w(true 1 yes on)
          _ -> nil
        end
      end

      defp fetch_boolean(_map, _keys), do: nil

      defp fetch_datetime(map, keys) when is_map(map) do
        case fetch_value(map, keys) do
          %DateTime{} = value ->
            value

          value when is_binary(value) ->
            case DateTime.from_iso8601(value) do
              {:ok, dt, _offset} -> dt
              _ -> nil
            end

          _ ->
            nil
        end
      end

      defp fetch_datetime(_map, _keys), do: nil

      defp fetch_recipients(map) when is_map(map) do
        case fetch_value(map, [:recipients, "recipients"]) do
          values when is_list(values) ->
            values
            |> Enum.map(&normalize_string/1)
            |> Enum.reject(&is_nil/1)

          value when is_binary(value) ->
            value
            |> String.split([",", "\n"], trim: true)
            |> Enum.map(&normalize_string/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            nil
        end
      end

      defp fetch_recipients(_map), do: nil

      defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
        Enum.reduce_while(keys, nil, fn key, _acc ->
          if Map.has_key?(map, key) do
            {:halt, Map.get(map, key)}
          else
            {:cont, nil}
          end
        end)
      end

      defp put_if_present(map, _key, nil), do: map
      defp put_if_present(map, key, value), do: Map.put(map, key, value)

      defp normalize_existing_atom(value, allowed) when is_atom(value) do
        if value in allowed, do: value
      end

      defp normalize_existing_atom(value, allowed) when is_binary(value) do
        Enum.find(allowed, &(Atom.to_string(&1) == value))
      end

      defp normalize_existing_atom(_value, _allowed), do: nil

      defp normalize_existing_atoms(nil, _allowed), do: []

      defp normalize_existing_atoms(values, allowed) when is_list(values) do
        values
        |> Enum.map(&normalize_existing_atom(&1, allowed))
        |> Enum.reject(&is_nil/1)
      end

      defp normalize_existing_atoms(value, allowed), do: normalize_existing_atoms([value], allowed)

      defp normalize_limit(value, max_limit \\ 200)
      defp normalize_limit(value, max_limit) when is_integer(value), do: value |> max(1) |> min(max_limit)

      defp normalize_limit(value, max_limit) when is_binary(value) do
        case Integer.parse(String.trim(value)) do
          {int, ""} -> normalize_limit(int, max_limit)
          _ -> 50
        end
      end

      defp normalize_limit(_value, _max_limit), do: 50

      defp visual_types, do: ServiceRadarWebNG.Dashboards.Authored.Visuals.visual_types()

      defp owner_id(%{user: %{id: id}}), do: id
      defp owner_id(_scope), do: nil

      defp normalize_timezone(value) when value in ["UTC", "Etc/UTC"], do: "Etc/UTC"
      defp normalize_timezone(value) when is_binary(value) and value != "", do: value
      defp normalize_timezone(_value), do: "UTC"

      defp srql_module do
        Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
      end
    end
  end
end
