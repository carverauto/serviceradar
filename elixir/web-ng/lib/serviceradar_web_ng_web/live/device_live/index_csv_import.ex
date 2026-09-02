defmodule ServiceRadarWebNGWeb.DeviceLive.IndexCsvImport do
  @moduledoc false

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Changes.Required
  alias Ash.Error.Changes.StaleRecord
  alias Ash.Error.Invalid
  alias ServiceRadarWebNG.Devices.ManualDeviceCreator

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  # How many skipped rows to name individually before collapsing the rest into
  # a count. Naming every row in a mostly-bad 10k-row file would bury the UI.
  @max_reported_skips 10
  @max_hostname_only_rows 100
  @dns_max_concurrency 10
  @dns_timeout 2_000
  @reserved_csv_columns ~w(hostname ip type tags partition)

  @doc false
  # Phoenix.LiveView.uploaded_entries/2 returns `{completed, in_progress}`.
  # A list match on that tuple is the CaseClauseError that used to crash Preview.
  def completed_csv_upload_entry({[], []}), do: {:error, :no_file}
  def completed_csv_upload_entry({[], [_ | _]}), do: {:error, :in_progress}
  def completed_csv_upload_entry({[entry | _], _in_progress}), do: {:ok, entry}

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
    # Spreadsheet applications commonly prefix UTF-8 CSV files with a BOM.
    # It is not whitespace to String.trim/1, so leaving it attached to the
    # first header either rejects a hostname-only file or silently loses every
    # hostname when an `ip` column also happens to validate.
    content = path |> File.read!() |> String.trim_leading("\uFEFF")

    case parse_csv_rows(content) do
      {:error, error} ->
        {:error, [error]}

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

  # Reaching EOF immediately after a record separator creates no new record.
  # Track it by parser state instead of dropping any final [""] record by
  # content: an explicitly quoted empty record (`""`) is real input and must
  # still produce a skipped-row warning.
  defp parse_csv_field([], [], [], rows, :field_start, _pos), do: {:ok, Enum.reverse(rows)}

  defp parse_csv_field([], _field, _row, _rows, :quoted, {_line, row_start}) do
    {:error, "Row #{row_start}: unterminated quoted field"}
  end

  defp parse_csv_field([], field, row, rows, _state, {_line, row_start}) do
    final_row = finish_row_fields(field, row)
    {:ok, Enum.reverse([{row_start, final_row} | rows])}
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

  defp parse_device_row(values, header_map, line) do
    hostname = trimmed_csv_value(values, header_map, "hostname")
    ip = trimmed_csv_value(values, header_map, "ip")

    if hostname == "" and ip == "" do
      {:skip, line, "needs a hostname or an ip"}
    else
      case parse_row_partition(trimmed_csv_value(values, header_map, "partition")) do
        {:error, slug} ->
          {:skip, line, "invalid partition '#{slug}'"}

        {:ok, partition} ->
          tags = parse_tags(get_csv_value(values, header_map, "tags"))

          # `key=value` pieces in the tags column are the documented CSV channel
          # for operator fields (site, gate, model, …). They must also land in
          # `metadata` — All Metadata on device details reads that map, not tags.
          # Extra CSV columns overlay the same keys when both are present.
          metadata =
            tags
            |> tag_pairs_as_metadata()
            |> Map.merge(extra_column_metadata(values, header_map))

          {:ok,
           %{
             hostname: hostname,
             ip: ip,
             partition: partition,
             type: get_csv_value(values, header_map, "type") || "",
             tags: tags,
             metadata: metadata,
             # Kept so a creation failure can name the line the operator wrote,
             # not a running tally. ManualDeviceCreator builds its own attribute
             # map and ignores this.
             source_line: line
           }}
      end
    end
  end

  defp parse_row_partition(value) do
    ManualDeviceCreator.parse_partition(value)
  end

  @doc false
  def apply_import_partition(devices, default_partition) when is_list(devices) do
    default = ManualDeviceCreator.coerce_partition(default_partition)

    Enum.map(devices, fn device ->
      case Map.get(device, :partition) || Map.get(device, "partition") do
        value when is_binary(value) and value != "" ->
          Map.put(device, :partition, value)

        _ ->
          Map.put(device, :partition, default)
      end
    end)
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

  defp tag_pairs_as_metadata(tags) when is_list(tags) do
    Enum.reduce(tags, %{}, fn tag, acc ->
      case String.split(tag, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = String.trim(value)

          if key == "" or value == "" do
            acc
          else
            Map.put(acc, key, value)
          end

        _ ->
          acc
      end
    end)
  end

  defp extra_column_metadata(values, header_map) do
    Enum.reduce(header_map, %{}, fn {name, index}, acc ->
      if name in @reserved_csv_columns do
        acc
      else
        case values |> Enum.at(index) |> Kernel.||("") |> String.trim() do
          "" -> acc
          value -> Map.put(acc, name, value)
        end
      end
    end)
  end

  def import_success_message(created, updated) when created > 0 and updated > 0 do
    "Created #{created} device(s). Updated #{updated} existing device(s) with imported tags and metadata."
  end

  def import_success_message(_created, updated) when updated > 0 do
    "Updated #{updated} existing device(s) with imported tags and metadata."
  end

  def import_success_message(created, _updated) do
    "Created #{created} device(s) successfully."
  end

  def import_devices(scope, devices) do
    import_devices(
      scope,
      devices,
      &ManualDeviceCreator.upsert/2,
      &ManualDeviceCreator.resolve_hostname/1
    )
  end

  @doc false
  def import_devices(scope, devices, create_device) when is_function(create_device, 2) do
    import_devices(scope, devices, create_device, &ManualDeviceCreator.resolve_hostname/1)
  end

  @doc false
  def import_devices(scope, devices, create_device, resolve_hostname, opts \\ [])
      when is_list(devices) and is_function(create_device, 2) and is_function(resolve_hostname, 1) and is_list(opts) do
    devices = apply_import_partition(devices, Keyword.get(opts, :default_partition, "default"))

    case prepare_hostname_rows(devices, resolve_hostname, opts) do
      {:ok, prepared_rows} ->
        do_import_devices(prepared_rows, scope, create_device)

      {:error, errors} ->
        {:error, %{created: 0, updated: 0, errors: errors}}
    end
  end

  defp prepare_hostname_rows(devices, resolve_hostname, opts) do
    candidates =
      devices
      |> Enum.with_index()
      |> Enum.filter(fn {device, _index} -> hostname_only?(device) end)

    max_rows = Keyword.get(opts, :max_hostname_only_rows, @max_hostname_only_rows)

    if length(candidates) > max_rows do
      {:error,
       [
         "CSV contains #{length(candidates)} hostname-only rows; the maximum is #{max_rows} per import"
       ]}
    else
      resolutions = resolve_hostname_rows(candidates, resolve_hostname, opts)

      prepared_rows =
        devices
        |> Enum.with_index()
        |> Enum.map(fn {device, index} ->
          Map.get(resolutions, index, {:device, device})
        end)

      {:ok, prepared_rows}
    end
  end

  defp resolve_hostname_rows([], _resolve_hostname, _opts), do: %{}

  defp resolve_hostname_rows(candidates, resolve_hostname, opts) do
    task_opts = [
      max_concurrency: Keyword.get(opts, :dns_max_concurrency, @dns_max_concurrency),
      timeout: Keyword.get(opts, :dns_timeout, @dns_timeout),
      on_timeout: :kill_task,
      ordered: true
    ]

    candidates
    |> Task.async_stream(
      fn {device, _index} -> resolve_hostname.(hostname(device)) end,
      task_opts
    )
    |> Enum.zip(candidates)
    |> Enum.reduce(%{}, fn {task_result, {device, index}}, acc ->
      Map.put(acc, index, resolution_result(device, task_result))
    end)
  end

  defp resolution_result(device, {:ok, {:ok, ip}}) when is_binary(ip) do
    case String.trim(ip) do
      "" -> resolution_error(device, :empty_address)
      resolved_ip -> {:device, Map.put(device, :ip, resolved_ip)}
    end
  end

  defp resolution_result(device, {:ok, {:error, reason}}), do: resolution_error(device, reason)

  defp resolution_result(device, {:exit, :timeout}) do
    {:error, "#{row_label(device)}: hostname resolution timed out for '#{hostname(device)}'"}
  end

  defp resolution_result(device, {:exit, reason}), do: resolution_error(device, {:resolver_exit, reason})

  defp resolution_result(device, {:ok, result}), do: resolution_error(device, {:unexpected_resolver_result, result})

  defp resolution_error(device, reason) do
    {:error, "#{row_label(device)}: unable to resolve hostname '#{hostname(device)}': #{inspect(reason)}"}
  end

  defp hostname_only?(device), do: blank?(ip(device)) and not blank?(hostname(device))

  defp hostname(device), do: Map.get(device, :hostname) || Map.get(device, "hostname")
  defp ip(device), do: Map.get(device, :ip) || Map.get(device, "ip")

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp do_import_devices(prepared_rows, scope, persist_device) do
    {created, updated, errors} =
      Enum.reduce(prepared_rows, {0, 0, []}, fn
        {:device, device_data}, acc ->
          process_device_import(device_data, scope, acc, persist_device)

        {:error, error}, {created, updated, errors} ->
          {created, updated, [error | errors]}
      end)

    if errors == [] do
      {:ok, {created, updated}}
    else
      {:error, %{created: created, updated: updated, errors: Enum.reverse(errors)}}
    end
  end

  defp process_device_import(device_data, scope, {created, updated, errors}, persist_device) do
    case persist_device.(scope, device_data) do
      {:ok, :created, _device} ->
        {created + 1, updated, errors}

      {:ok, :updated, _device} ->
        {created, updated + 1, errors}

      {:ok, _device} ->
        {created + 1, updated, errors}

      {:error, :already_exists} ->
        {created, updated, ["#{row_label(device_data)}: device already exists and could not be updated" | errors]}

      {:error, reason} ->
        # created + updated + 1 would count successes, not source rows: every
        # parser-skipped row and every earlier failure shifted it, so a failure
        # on line 9 could report itself as "Row 3".
        Logger.warning("CSV device import failed for #{row_label(device_data)}: #{inspect(reason)}")

        {created, updated, ["#{row_label(device_data)}: #{format_create_error(reason)}" | errors]}
    end
  end

  def import_partial_message(created, updated, failed) do
    if created + updated > 0 do
      "Import partially completed: #{created} created, #{updated} updated, and #{failed} failed."
    end
  end

  defp row_label(%{source_line: line}) when is_integer(line), do: "Row #{line}"
  defp row_label(_device_data), do: "Row (unknown)"

  def create_device(scope, params) do
    ManualDeviceCreator.create(scope, %{
      hostname: params["hostname"],
      ip: params["ip"],
      partition: params["partition"],
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

  def format_device_error(%StaleRecord{} = error), do: format_single_device_error(error)

  def format_device_error(error), do: inspect(error)

  defp format_create_error(%Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_device_error/1)
  end

  defp format_create_error(%StaleRecord{} = error), do: format_single_device_error(error)

  defp format_create_error(error), do: inspect(error)

  defp format_single_device_error(%InvalidAttribute{field: field, message: msg}), do: "#{field}: #{msg}"

  defp format_single_device_error(%Required{field: field}), do: "#{field} is required"

  defp format_single_device_error(%Ash.Error.Query.NotFound{}), do: "Device not found"

  defp format_single_device_error(%StaleRecord{}),
    do: "device was updated by another writer during import; retry this row"

  defp format_single_device_error(%{message: msg}) when is_binary(msg), do: msg

  defp format_single_device_error(err), do: inspect(err)
end
