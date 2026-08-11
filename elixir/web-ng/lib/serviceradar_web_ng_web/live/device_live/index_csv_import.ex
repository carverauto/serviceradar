defmodule ServiceRadarWebNGWeb.DeviceLive.IndexCsvImport do
  @moduledoc false

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Changes.Required
  alias Ash.Error.Invalid
  alias ServiceRadarWebNG.Devices.ManualDeviceCreator

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  # How many skipped rows to name individually before collapsing the rest into
  # a count. Naming every row in a mostly-bad 10k-row file would bury the UI.
  @max_reported_skips 10

  @doc """
  Parses an uploaded CSV into device maps.

  Returns `{:ok, devices, warnings}` on success. `warnings` names the rows that
  were skipped and why; they used to be dropped silently, which turned a
  malformed row into an import that was quietly short.

  A row needs a hostname or an IP, not both — `ManualDeviceCreator` resolves a
  hostname-only device via DNS and accepts an IP-only device as-is.
  """
  @sobelow_skip ["Traversal.FileModule"]
  def parse_csv_file(path) do
    content = File.read!(path)

    case parse_csv_rows(content) do
      {:ok, []} ->
        {:error, ["CSV file is empty"]}

      {:ok, [header | data_rows]} ->
        headers = Enum.map(header, &String.trim/1)
        downcased = Enum.map(headers, &String.downcase/1)

        if "hostname" in downcased or "ip" in downcased do
          header_map = headers |> Enum.with_index() |> Map.new()

          # Row 1 is the header, so data rows start at line 2.
          {devices, skipped} =
            data_rows
            |> Enum.with_index(2)
            |> Enum.map(fn {values, line} -> parse_device_row(values, header_map, line) end)
            |> Enum.split_with(&match?({:ok, _}, &1))

          devices = Enum.map(devices, fn {:ok, device} -> device end)
          warnings = skip_warnings(skipped)

          case devices do
            [] -> {:error, ["No valid device rows found in CSV" | warnings]}
            _ -> {:ok, devices, warnings}
          end
        else
          {:error, ["CSV must include a hostname or ip column"]}
        end
    end
  rescue
    e ->
      {:error, ["Failed to parse CSV: #{inspect(e)}"]}
  end

  defp skip_warnings([]), do: []

  defp skip_warnings(skipped) do
    reported =
      skipped
      |> Enum.take(@max_reported_skips)
      |> Enum.map(fn {:skip, line, reason} -> "Row #{line} skipped: #{reason}" end)

    case length(skipped) - length(reported) do
      0 -> reported
      remaining -> reported ++ ["... and #{remaining} more row(s) skipped"]
    end
  end

  defp parse_csv_rows(content) when is_binary(content) do
    content
    |> String.to_charlist()
    |> parse_csv_field([], [], [], :field_start)
  end

  defp parse_csv_field([], field, row, rows, _state) do
    final_row = finish_row_fields(field, row)
    {:ok, finalize_csv_rows([final_row | rows])}
  end

  defp parse_csv_field([?" | rest], [], row, rows, :field_start) do
    parse_csv_field(rest, [], row, rows, :quoted)
  end

  defp parse_csv_field([?, | rest], field, row, rows, state) when state in [:field_start, :unquoted] do
    new_field = finish_field(field)
    parse_csv_field(rest, [], [new_field | row], rows, :field_start)
  end

  defp parse_csv_field([?\r, ?\n | rest], field, row, rows, state) when state in [:field_start, :unquoted] do
    finish_csv_row(rest, field, row, rows)
  end

  defp parse_csv_field([?\r | rest], field, row, rows, state) when state in [:field_start, :unquoted] do
    finish_csv_row(rest, field, row, rows)
  end

  defp parse_csv_field([?\n | rest], field, row, rows, state) when state in [:field_start, :unquoted] do
    finish_csv_row(rest, field, row, rows)
  end

  defp parse_csv_field([char | rest], field, row, rows, state) when state in [:field_start, :unquoted] do
    parse_csv_field(rest, [char | field], row, rows, :unquoted)
  end

  defp parse_csv_field([?", ?" | rest], field, row, rows, :quoted) do
    parse_csv_field(rest, [?" | field], row, rows, :quoted)
  end

  defp parse_csv_field([?" | rest], field, row, rows, :quoted) do
    parse_csv_field(rest, field, row, rows, :quote_end)
  end

  defp parse_csv_field([char | rest], field, row, rows, :quoted) do
    parse_csv_field(rest, [char | field], row, rows, :quoted)
  end

  defp parse_csv_field([?, | rest], field, row, rows, :quote_end) do
    new_field = finish_field(field)
    parse_csv_field(rest, [], [new_field | row], rows, :field_start)
  end

  defp parse_csv_field([?\r, ?\n | rest], field, row, rows, :quote_end), do: finish_csv_row(rest, field, row, rows)

  defp parse_csv_field([?\r | rest], field, row, rows, :quote_end), do: finish_csv_row(rest, field, row, rows)

  defp parse_csv_field([?\n | rest], field, row, rows, :quote_end), do: finish_csv_row(rest, field, row, rows)

  defp parse_csv_field([char | rest], field, row, rows, :quote_end) do
    parse_csv_field(rest, [char | field], row, rows, :unquoted)
  end

  defp finish_csv_row(rest, field, row, rows) do
    new_row = finish_row_fields(field, row)
    parse_csv_field(rest, [], [], [new_row | rows], :field_start)
  end

  defp finish_field(field), do: field |> Enum.reverse() |> List.to_string()
  defp finish_row_fields(field, row), do: Enum.reverse([finish_field(field) | row])

  defp finalize_csv_rows([[""] | rest]), do: Enum.reverse(rest)
  defp finalize_csv_rows(rows), do: Enum.reverse(rows)

  defp parse_device_row(values, header_map, line) do
    hostname = trimmed_csv_value(values, header_map, "hostname")
    ip = trimmed_csv_value(values, header_map, "ip")

    if hostname == "" and ip == "" do
      {:skip, line, "needs a hostname or an ip"}
    else
      {:ok,
       %{
         hostname: hostname,
         ip: ip,
         type: get_csv_value(values, header_map, "type") || "",
         tags: parse_tags(get_csv_value(values, header_map, "tags"))
       }}
    end
  end

  defp trimmed_csv_value(values, header_map, column) do
    values
    |> get_csv_value(header_map, column)
    |> Kernel.||("")
    |> String.trim()
  end

  defp get_csv_value(values, header_map, column) do
    index =
      Map.get(header_map, column) ||
        Map.get(header_map, String.capitalize(column)) ||
        Map.get(header_map, String.upcase(column))

    if index, do: Enum.at(values, index)
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags_string) do
    tags_string
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def import_success_message(created, skipped) when skipped > 0 and created > 0 do
    "Created #{created} device(s). #{skipped} device(s) skipped (already exist)."
  end

  def import_success_message(_created, skipped) when skipped > 0 do
    "All #{skipped} device(s) already exist."
  end

  def import_success_message(created, _skipped) do
    "Created #{created} device(s) successfully."
  end

  def import_devices(scope, devices) do
    do_import_devices(devices, scope)
  end

  defp do_import_devices(devices, scope) do
    {created, skipped, errors} =
      Enum.reduce(devices, {0, 0, []}, fn device_data, acc ->
        process_device_import(device_data, scope, acc)
      end)

    if errors == [], do: {:ok, {created, skipped}}, else: {:error, Enum.reverse(errors)}
  end

  defp process_device_import(device_data, scope, {created, skipped, errors}) do
    case ManualDeviceCreator.create(scope, device_data) do
      {:ok, _device} ->
        {created + 1, skipped, errors}

      {:error, :already_exists} ->
        {created, skipped + 1, errors}

      {:error, reason} ->
        error_msg = "Row #{created + skipped + 1}: #{format_create_error(reason)}"
        {created, skipped, [error_msg | errors]}
    end
  end

  def create_device(scope, params) do
    ManualDeviceCreator.create(scope, %{
      hostname: params["hostname"],
      ip: params["ip"],
      type: params["type"],
      tags: parse_form_tags(params["tags"])
    })
  end

  defp parse_form_tags(nil), do: []
  defp parse_form_tags(""), do: []

  defp parse_form_tags(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def format_device_error(%Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_device_error/1)
  end

  def format_device_error(error), do: inspect(error)

  defp format_create_error(%Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_device_error/1)
  end

  defp format_create_error(error), do: inspect(error)

  defp format_single_device_error(%InvalidAttribute{field: field, message: msg}), do: "#{field}: #{msg}"

  defp format_single_device_error(%Required{field: field}), do: "#{field} is required"

  defp format_single_device_error(%Ash.Error.Query.NotFound{}), do: "Device not found"

  defp format_single_device_error(%{message: msg}) when is_binary(msg), do: msg

  defp format_single_device_error(err), do: inspect(err)
end
