defmodule ServiceRadar.WifiMap.CSVSeedPayload do
  @moduledoc """
  Builds normalized WiFi-map batch payloads from the CSV seed files used by the
  customer WiFi-map plugin.

  This module is intentionally independent of database writes so it can be used
  by local validation tasks and test harnesses. The customer-owned Go plugin
  should emit the same JSON shape when it runs in `csv_seed` mode.
  """

  @schema "serviceradar.wifi_map.batch.v1"
  @default_source_name "wifi-map-csv-seed"
  @default_source_kind "wifi_map_seed"

  @type build_option ::
          {:collection_timestamp, DateTime.t() | String.t()}
          | {:source_id, String.t()}
          | {:source_name, String.t()}
          | {:source_kind, String.t()}

  @type build_summary :: %{
          directory: String.t(),
          row_counts: map(),
          source_files: map(),
          reference_hash: String.t()
        }

  @spec build(Path.t(), [build_option()]) :: {:ok, map(), build_summary()} | {:error, term()}
  def build(directory, opts \\ []) do
    directory = Path.expand(directory)

    with :ok <- ensure_directory(directory),
         {:ok, sites, site_file} <- read_required_csv(directory, "sites.csv"),
         {:ok, search_index, search_file} <- read_optional_csv(directory, "search_index.csv"),
         {:ok, history, history_file} <- read_optional_csv(directory, "history.csv"),
         {:ok, overrides, overrides_file} <- read_optional_csv(directory, "overrides.csv"),
         {:ok, ap_rows, ap_file} <- read_optional_csv(directory, "ap-database-current.csv"),
         {:ok, controller_rows, controller_file} <-
           read_first_optional_csv(directory, [
             "switchinfo-current.csv",
             "wlc-database-current.csv"
           ]),
         {:ok, radius_rows, radius_file} <-
           read_optional_csv(directory, "radius-groups-current.csv"),
         {:ok, meta} <- read_optional_json(directory, "meta.json"),
         {:ok, collection_timestamp} <- collection_timestamp(opts, meta) do
      source_files =
        [
          site_file,
          search_file,
          history_file,
          overrides_file,
          ap_file,
          controller_file,
          radius_file
        ]
        |> Enum.reject(&is_nil/1)
        |> Map.new(fn file -> {file.name, Map.delete(file, :name)} end)

      reference_hash = reference_hash(source_files, ["sites.csv", "overrides.csv"])

      payload =
        %{
          "schema" => @schema,
          "kind" => "wifi_map",
          "collection_mode" => "csv_seed",
          "collection_timestamp" => DateTime.to_iso8601(collection_timestamp),
          "reference_hash" => reference_hash,
          "source" => source(opts, directory),
          "source_files" => source_files,
          "row_counts" =>
            row_counts(
              sites,
              search_index,
              history,
              overrides,
              ap_rows,
              controller_rows,
              radius_rows
            ),
          "site_references" => sites,
          "sites" => sites,
          "search_index" => search_index,
          "access_points" => ap_rows,
          "controllers" => controller_rows,
          "radius_groups" => radius_rows,
          "fleet_history" => history,
          "diagnostics" => diagnostics(meta, overrides)
        }

      summary = %{
        directory: directory,
        row_counts: payload["row_counts"],
        source_files: source_files,
        reference_hash: reference_hash
      }

      {:ok, payload, summary}
    end
  end

  defp ensure_directory(directory) do
    if File.dir?(directory), do: :ok, else: {:error, {:missing_directory, directory}}
  end

  defp read_required_csv(directory, filename) do
    path = Path.join(directory, filename)

    with true <- File.regular?(path) || {:error, {:missing_csv, path}},
         {:ok, rows} <- read_csv(path),
         {:ok, metadata} <- file_metadata(path, rows) do
      {:ok, rows, metadata}
    end
  end

  defp read_optional_csv(directory, filename) do
    path = Path.join(directory, filename)

    if File.regular?(path) do
      with {:ok, rows} <- read_csv(path),
           {:ok, metadata} <- file_metadata(path, rows) do
        {:ok, rows, metadata}
      end
    else
      {:ok, [], nil}
    end
  end

  defp read_first_optional_csv(_directory, []), do: {:ok, [], nil}

  defp read_first_optional_csv(directory, [filename | rest]) do
    path = Path.join(directory, filename)

    if File.regular?(path) do
      read_optional_csv(directory, filename)
    else
      read_first_optional_csv(directory, rest)
    end
  end

  defp read_csv(path) do
    with {:ok, content} <- File.read(path),
         {:ok, rows} <- parse_csv(content) do
      {:ok, rows}
    else
      {:error, reason} -> {:error, {:invalid_csv, path, reason}}
    end
  end

  defp parse_csv(content) do
    rows =
      content
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.graphemes()
      |> parse_chars([], [], [], false)
      |> Enum.reject(&empty_row?/1)

    case rows do
      [] ->
        {:ok, []}

      [headers | data_rows] ->
        headers = Enum.map(headers, &normalize_header/1)

        rows =
          Enum.map(data_rows, fn row ->
            headers
            |> Enum.zip(row ++ List.duplicate("", max(length(headers) - length(row), 0)))
            |> Map.new(fn {key, value} -> {key, normalize_value(value)} end)
          end)

        {:ok, rows}
    end
  end

  defp parse_chars([], field, row, rows, _quoted?) do
    row = finish_row(row, field)

    if empty_row?(row), do: Enum.reverse(rows), else: Enum.reverse([row | rows])
  end

  defp parse_chars(["," | rest], field, row, rows, false),
    do: parse_chars(rest, [], finish_field(row, field), rows, false)

  defp parse_chars(["\n" | rest], field, row, rows, false) do
    finished = finish_row(row, field)
    parse_chars(rest, [], [], [finished | rows], false)
  end

  defp parse_chars(["\"" | ["\"" | rest]], field, row, rows, true),
    do: parse_chars(rest, ["\"" | field], row, rows, true)

  defp parse_chars(["\"" | rest], field, row, rows, quoted?),
    do: parse_chars(rest, field, row, rows, not quoted?)

  defp parse_chars([char | rest], field, row, rows, quoted?),
    do: parse_chars(rest, [char | field], row, rows, quoted?)

  defp finish_row(row, field), do: row |> finish_field(field) |> Enum.reverse()

  defp finish_field(row, field) do
    value = field |> Enum.reverse() |> IO.iodata_to_binary()
    [value | row]
  end

  defp empty_row?(row), do: Enum.all?(row, &(String.trim(to_string(&1)) == ""))

  defp normalize_header(header) do
    header
    |> String.trim()
    |> String.trim_leading(<<0xEF, 0xBB, 0xBF>>)
  end

  defp normalize_value(value), do: String.trim(value)

  defp read_optional_json(directory, filename) do
    path = Path.join(directory, filename)

    if File.regular?(path) do
      case path |> File.read!() |> Jason.decode() do
        {:ok, value} when is_map(value) -> {:ok, value}
        {:ok, _value} -> {:error, {:invalid_json_object, path}}
        {:error, reason} -> {:error, {:invalid_json, path, reason}}
      end
    else
      {:ok, %{}}
    end
  end

  defp file_metadata(path, rows) do
    with {:ok, stat} <- File.stat(path),
         {:ok, content} <- File.read(path) do
      {:ok,
       %{
         :name => Path.basename(path),
         "bytes" => stat.size,
         "sha256" => sha256(content),
         "rows" => length(rows)
       }}
    end
  end

  defp collection_timestamp(opts, meta) do
    opts
    |> Keyword.get(:collection_timestamp)
    |> case do
      nil ->
        meta
        |> Map.get("collection_timestamp")
        |> case do
          nil -> {:ok, DateTime.truncate(DateTime.utc_now(), :second)}
          value -> parse_datetime(value)
        end

      %DateTime{} = datetime ->
        {:ok, DateTime.truncate(datetime, :second)}

      value when is_binary(value) ->
        parse_datetime(value)
    end
  end

  defp parse_datetime(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:ok, DateTime.truncate(DateTime.utc_now(), :second)}

      String.ends_with?(value, "Z") or String.contains?(value, "T") ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
          {:error, reason} -> {:error, {:invalid_collection_timestamp, value, reason}}
        end

      true ->
        case NaiveDateTime.from_iso8601(String.replace(value, " ", "T")) do
          {:ok, naive} ->
            {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)}

          {:error, reason} ->
            {:error, {:invalid_collection_timestamp, value, reason}}
        end
    end
  end

  defp source(opts, directory) do
    %{
      "source_id" => Keyword.get(opts, :source_id),
      "name" => Keyword.get(opts, :source_name, @default_source_name),
      "source_kind" => Keyword.get(opts, :source_kind, @default_source_kind),
      "metadata" => %{
        "seed_directory" => directory,
        "seed_format" => "wifi_map_csv_v1"
      }
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp row_counts(
         sites,
         search_index,
         history,
         overrides,
         access_points,
         controllers,
         radius_groups
       ) do
    search_counts = Enum.frequencies_by(search_index, &String.downcase(Map.get(&1, "kind", "")))

    %{
      "sites" => length(sites),
      "site_references" => length(sites),
      "search_index" => length(search_index),
      "search_index_access_points" => Map.get(search_counts, "ap", 0),
      "search_index_controllers" => Map.get(search_counts, "wlc", 0),
      "fleet_history" => length(history),
      "overrides" => length(overrides),
      "access_points" => length(access_points),
      "controllers" => length(controllers),
      "radius_groups" => length(radius_groups)
    }
  end

  defp diagnostics(meta, overrides) do
    []
    |> maybe_add_diagnostic("meta", meta)
    |> maybe_add_diagnostic("overrides", %{"rows" => length(overrides)})
  end

  defp maybe_add_diagnostic(diagnostics, _kind, value) when value in [%{}, %{"rows" => 0}],
    do: diagnostics

  defp maybe_add_diagnostic(diagnostics, kind, value),
    do: [%{"kind" => kind, "value" => value} | diagnostics]

  defp reference_hash(source_files, names) do
    names
    |> Enum.map(fn name -> get_in(source_files, [name, "sha256"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
    |> sha256()
  end

  defp sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
