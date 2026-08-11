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

      {:ok, [{_line, header} | data_rows]} ->
        # Validation and lookup must normalize headers the same way, or a file
        # headed `HostName` passes the column check and then every row is
        # skipped as missing both fields.
        header_map = build_header_map(header)

        if Map.has_key?(header_map, "hostname") or Map.has_key?(header_map, "ip") do
          {devices, skipped} =
            data_rows
            |> Enum.map(fn {line, values} -> parse_device_row(values, header_map, line) end)
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

  # Every record is emitted as {physical_line, fields}. A quoted field may span
  # newlines, so a record's ordinal is not its line number -- and a warning that
  # points at the wrong line is worse than no line at all.
  #
  # `pos` is {line_of_the_char_being_read, line_the_current_record_started_on}.
  defp parse_csv_rows(content) when is_binary(content) do
    content
    |> String.to_charlist()
    |> parse_csv_field([], [], [], :field_start, {1, 1})
  end

  defp parse_csv_field([], field, row, rows, _state, {_line, row_start}) do
    final_row = finish_row_fields(field, row)
    {:ok, finalize_csv_rows([{row_start, final_row} | rows])}
  end

  defp parse_csv_field([?" | rest], [], row, rows, :field_start, pos) do
    parse_csv_field(rest, [], row, rows, :quoted, pos)
  end

  defp parse_csv_field([?, | rest], field, row, rows, state, pos) when state in [:field_start, :unquoted] do
    new_field = finish_field(field)
    parse_csv_field(rest, [], [new_field | row], rows, :field_start, pos)
  end

  defp parse_csv_field([?\r, ?\n | rest], field, row, rows, state, pos) when state in [:field_start, :unquoted] do
    finish_csv_row(rest, field, row, rows, pos)
  end

  defp parse_csv_field([?\r | rest], field, row, rows, state, pos) when state in [:field_start, :unquoted] do
    finish_csv_row(rest, field, row, rows, pos)
  end

  defp parse_csv_field([?\n | rest], field, row, rows, state, pos) when state in [:field_start, :unquoted] do
    finish_csv_row(rest, field, row, rows, pos)
  end

  defp parse_csv_field([char | rest], field, row, rows, state, pos) when state in [:field_start, :unquoted] do
    parse_csv_field(rest, [char | field], row, rows, :unquoted, pos)
  end

  defp parse_csv_field([?", ?" | rest], field, row, rows, :quoted, pos) do
    parse_csv_field(rest, [?" | field], row, rows, :quoted, pos)
  end

  defp parse_csv_field([?" | rest], field, row, rows, :quoted, pos) do
    parse_csv_field(rest, field, row, rows, :quote_end, pos)
  end

  # A newline inside quotes stays part of the field but still advances the
  # physical line, which is the whole reason records and lines diverge.
  defp parse_csv_field([?\r, ?\n | rest], field, row, rows, :quoted, {line, row_start}) do
    parse_csv_field(rest, [?\n, ?\r | field], row, rows, :quoted, {line + 1, row_start})
  end

  defp parse_csv_field([newline | rest], field, row, rows, :quoted, {line, row_start}) when newline in [?\r, ?\n] do
    parse_csv_field(rest, [newline | field], row, rows, :quoted, {line + 1, row_start})
  end

  defp parse_csv_field([char | rest], field, row, rows, :quoted, pos) do
    parse_csv_field(rest, [char | field], row, rows, :quoted, pos)
  end

  defp parse_csv_field([?, | rest], field, row, rows, :quote_end, pos) do
    new_field = finish_field(field)
    parse_csv_field(rest, [], [new_field | row], rows, :field_start, pos)
  end

  defp parse_csv_field([?\r, ?\n | rest], field, row, rows, :quote_end, pos),
    do: finish_csv_row(rest, field, row, rows, pos)

  defp parse_csv_field([?\r | rest], field, row, rows, :quote_end, pos), do: finish_csv_row(rest, field, row, rows, pos)

  defp parse_csv_field([?\n | rest], field, row, rows, :quote_end, pos), do: finish_csv_row(rest, field, row, rows, pos)

  defp parse_csv_field([char | rest], field, row, rows, :quote_end, pos) do
    parse_csv_field(rest, [char | field], row, rows, :unquoted, pos)
  end

  defp finish_csv_row(rest, field, row, rows, {line, row_start}) do
    new_row = finish_row_fields(field, row)
    next_line = line + 1
    parse_csv_field(rest, [], [], [{row_start, new_row} | rows], :field_start, {next_line, next_line})
  end

  defp finish_field(field), do: field |> Enum.reverse() |> List.to_string()
  defp finish_row_fields(field, row), do: Enum.reverse([finish_field(field) | row])

  # A trailing newline leaves one empty record behind; drop it.
  defp finalize_csv_rows([{_line, [""]} | rest]), do: Enum.reverse(rest)
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
         tags: parse_tags(get_csv_value(values, header_map, "tags")),
         # Kept so a creation failure can name the line the operator wrote,
         # not a running tally. ManualDeviceCreator builds its own attribute
         # map and ignores this.
         source_line: line
       }}
    end
  end

  # Headers are matched case-insensitively and trimmed, so `HostName`, ` IP `,
  # and `hostname` all resolve. First occurrence wins on a duplicated column.
  defp build_header_map(header) do
    header
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {name, index}, acc -> Map.put_new(acc, name, index) end)
  end

  defp trimmed_csv_value(values, header_map, column) do
    values
    |> get_csv_value(header_map, column)
    |> Kernel.||("")
    |> String.trim()
  end

  # `column` is always already lowercase here, matching build_header_map/1.
  defp get_csv_value(values, header_map, column) do
    if index = Map.get(header_map, column), do: Enum.at(values, index)
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
        # created + skipped + 1 counts successes, not source rows: every
        # parser-skipped row and every earlier failure shifted it, so a failure
        # on line 9 could report itself as "Row 3".
        {created, skipped, ["#{row_label(device_data)}: #{format_create_error(reason)}" | errors]}
    end
  end

  defp row_label(%{source_line: line}) when is_integer(line), do: "Row #{line}"
  defp row_label(_device_data), do: "Row (unknown)"

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
