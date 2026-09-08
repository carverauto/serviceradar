defmodule ServiceRadar.Inventory.BumblebeeCatalogParser do
  @moduledoc """
  Normalizes Bumblebee exposure catalog payloads into current-state catalog entries.
  """

  @default_max_entries 250_000

  @spec parse(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(body, opts \\ []) when is_binary(body) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)

    with {:ok, decoded} <- decode_catalog(body),
         {:ok, raw_entries, metadata} <- extract_entries(decoded),
         entries = normalize_entries(raw_entries, max_entries),
         true <- entries != [] || {:error, :empty_catalog} do
      {:ok,
       %{
         entries: entries,
         catalog_version: metadata["catalog_version"],
         schema_version: metadata["schema_version"],
         metadata: Map.drop(metadata, ["catalog_version", "schema_version"]),
         validation_result: %{
           "status" => "valid",
           "entry_count" => length(entries),
           "dropped_entry_count" => max(length(raw_entries) - length(entries), 0)
         }
       }}
    end
  end

  defp decode_catalog(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        decode_ndjson(body)
    end
  end

  defp decode_ndjson(body) do
    entries =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["#", "//"])))
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_ndjson, reason}}}
        end
      end)

    case entries do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _} = error -> error
    end
  end

  defp extract_entries(entries) when is_list(entries), do: {:ok, entries, %{}}

  defp extract_entries(%{} = catalog) do
    entries =
      catalog
      |> map_get_any(["entries", "findings", "rules", "catalog", "threat_intel"], [])
      |> List.wrap()

    metadata =
      catalog
      |> Map.take(["catalog_version", "version", "schema_version", "revision", "generated_at"])
      |> maybe_rename("version", "catalog_version")
      |> maybe_rename("revision", "source_revision")

    {:ok, entries, metadata}
  end

  defp extract_entries(_), do: {:error, :invalid_catalog_shape}

  defp normalize_entries(raw_entries, max_entries) do
    raw_entries
    |> Enum.take(max_entries)
    |> Enum.map(&normalize_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.catalog_id)
  end

  defp normalize_entry(%{} = entry) do
    catalog_id =
      first_string(entry, ["catalog_id", "catalogId", "id", "rule_id", "ruleId", "cve"])

    package_name =
      first_string(entry, ["package_name", "packageName", "package", "name", "module"])

    ecosystem = first_string(entry, ["ecosystem", "type", "manager", "source"], "unknown")
    severity = first_string(entry, ["severity", "risk", "level"], "medium")

    if blank?(catalog_id) or blank?(package_name) do
      nil
    else
      %{
        catalog_id: catalog_id,
        ecosystem: ecosystem,
        package_name: package_name,
        affected_versions:
          entry
          |> map_get_any(["affected_versions", "affectedVersions", "versions"], [])
          |> normalize_string_list(),
        severity: normalize_severity(severity),
        source_url: first_string(entry, ["source_url", "sourceUrl", "url", "reference"]),
        metadata: entry
      }
    end
  end

  defp normalize_entry(_), do: nil

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"])
    |> normalize_string_list()
  end

  defp normalize_string_list(_), do: []

  defp normalize_severity(value) do
    case value |> to_string() |> String.downcase() |> String.trim() do
      severity when severity in ["critical", "high", "medium", "low", "info"] -> severity
      "informational" -> "info"
      _ -> "medium"
    end
  end

  defp first_string(map, keys, default \\ nil) do
    map
    |> map_get_any(keys, default)
    |> case do
      nil -> default
      value -> value |> to_string() |> String.trim()
    end
  end

  defp map_get_any(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      atom_key = key_atom(key)

      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
        true -> nil
      end
    end)
  end

  defp key_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp key_atom(key) when is_atom(key), do: key
  defp key_atom(_), do: nil

  defp maybe_rename(map, old_key, new_key) do
    if Map.has_key?(map, old_key) and not Map.has_key?(map, new_key) do
      map
      |> Map.put(new_key, Map.get(map, old_key))
      |> Map.delete(old_key)
    else
      map
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
