defmodule ServiceRadar.EventWriter.LogRow do
  @moduledoc """
  Decides the stored columns of a JSON log record after its Zen rules ran.

  The log collector makes the same decisions when it normalizes a record
  itself, and sends the outcome as OTLP
  (`rust/flowgger/src/flowgger/normalized/row.rs`). A record must be stored
  the same whichever side ran its rules, so this module follows that file
  function for function, and a change to either belongs in both. The two are
  held together by `normalized_log_parity_test.exs`, which compares the rows
  for hand-picked cases and for records and rule outputs generated on each run.

  A rule can return anything. Nothing here raises on a value of the wrong
  type: a column that cannot hold what the rule returned is left empty.

  What OTLP cannot carry is not stored on this path either, so that the two
  agree: an integer outside 64 bits is stored as a float, an attribute with an
  empty name is dropped, and an empty severity text, scope name, scope version
  or event name is absent.
  """

  import Bitwise

  alias ServiceRadar.EventWriter.LogSeverity

  @nanos_per_second 1_000_000_000
  @max_u64 0xFFFFFFFFFFFFFFFF
  @max_i64 0x7FFFFFFFFFFFFFFF
  @min_i64 -0x8000000000000000
  @max_i32 0x7FFFFFFF
  @max_u32 0xFFFFFFFF

  # RFC 3164 has no zone, so a wrong assumed zone files a fresh log hours off.
  @rfc3164_tolerance_seconds 3_600
  # Nothing is logged before it happens, so more than a day ahead is a wrong clock.
  @syslog_ahead_seconds 24 * 3_600
  # A relay can hold logs through an outage, so this is generous.
  @syslog_behind_seconds 30 * 24 * 3_600

  # RFC 3339 writes years 0000 to 9999.
  @rfc3339_first_second -62_167_219_200
  @rfc3339_last_second 253_402_300_799

  @syslog_attribute_keys ["_remote_addr", "_syslog_format", "_syslog_parse_fallback"]
  @column_prefix "serviceradar.column."

  @type columns :: %{
          timestamp: DateTime.t(),
          observed_timestamp: DateTime.t(),
          trace_flags: non_neg_integer() | nil,
          severity_text: String.t() | nil,
          severity_number: pos_integer() | nil,
          event_name: String.t() | nil,
          source: String.t() | nil,
          source_ip: String.t() | nil,
          service_name: String.t() | nil,
          service_version: String.t() | nil,
          service_instance: String.t() | nil,
          scope_name: String.t() | nil,
          scope_version: String.t() | nil,
          scope_attributes: map(),
          attributes: map(),
          resource_attributes: map()
        }

  @doc """
  The columns of `record`, which arrived at `received_at`.

  `trace_id` is the row's normalized trace id: trace flags are recorded only
  with a trace.
  """
  @spec columns(map(), DateTime.t() | nil, String.t() | nil) :: columns()
  def columns(record, received_at, trace_id) when is_map(record) do
    received = received_nanos(received_at)

    resource_attributes =
      object(field(record, "resource_attributes", "resourceAttributes") || record["resource"])

    {timestamp, time_attributes} = sender_time(record, received)
    {severity_text, severity_number} = severity(record)
    {scope_name, scope_version, scope_attributes} = scope(record)

    %{
      timestamp: from_nanos(timestamp),
      observed_timestamp: from_nanos(observed_time(record, received)),
      trace_flags: trace_flags(record, trace_id),
      severity_text: present(severity_text),
      severity_number: severity_number,
      event_name: record |> field("event_name", "eventName") |> text() |> present(),
      source: text(record["source"] || nil),
      source_ip: source_ip(record),
      service_name: text(service_name(record, resource_attributes)),
      service_version:
        text(
          service(
            record,
            resource_attributes,
            "service_version",
            "serviceVersion",
            "service.version"
          )
        ),
      service_instance:
        text(
          service(
            record,
            resource_attributes,
            "service_instance",
            "serviceInstance",
            "service.instance.id"
          )
        ),
      scope_name: present(scope_name),
      scope_version: present(scope_version),
      scope_attributes: scope_attributes,
      attributes: record |> attributes() |> Map.merge(time_attributes) |> as_carried(),
      resource_attributes: as_carried(resource_attributes || %{})
    }
  end

  @doc """
  The sender address in `value`, which may carry a partition prefix, a port
  or IPv6 brackets around the address.
  """
  @spec address(term()) :: String.t() | nil
  def address(value) when is_binary(value) do
    value = String.trim(value)

    [value, bracketless(value)]
    |> Enum.flat_map(fn candidate ->
      case String.split(candidate, ":", parts: 2) do
        [prefix, address] -> [candidate, prefix, address, bracketless(address)]
        _ -> [candidate]
      end
    end)
    |> Enum.find(&ip_address?/1)
  end

  def address(_value), do: nil

  defp received_nanos(%DateTime{} = received_at), do: DateTime.to_unix(received_at, :nanosecond)
  defp received_nanos(_), do: System.os_time(:nanosecond)

  # Microseconds are what both telemetry stores keep of a time.
  defp from_nanos(nanos), do: DateTime.from_unix!(div(nanos, 1_000), :microsecond)

  defp field(record, snake, camel), do: record[snake] || record[camel]

  defp first(record, keys), do: Enum.find_value(keys, &record[&1])

  # A scalar as a text column stores it. A float has no one spelling, so it is
  # not text.
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_boolean(value), do: to_string(value)

  defp text(value) when is_integer(value) and value >= @min_i64 and value <= @max_u64,
    do: Integer.to_string(value)

  defp text(_value), do: nil

  defp present(value) when value in ["", nil], do: nil
  defp present(value), do: value

  # An object field, which a sender may also give as JSON text.
  defp object(value) when is_map(value), do: value

  defp object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp object(_value), do: nil

  # Drops nulls, empty objects and empty arrays at every depth. `nil` when
  # nothing is left.
  defp prune(value) when is_map(value) do
    case prune_object(value) do
      empty when empty == %{} -> nil
      pruned -> pruned
    end
  end

  defp prune(value) when is_list(value) do
    case for item <- value, (pruned = prune(item)) != nil, do: pruned do
      [] -> nil
      pruned -> pruned
    end
  end

  defp prune(value), do: value

  defp prune_object(fields) do
    for {key, item} <- fields, (pruned = prune(item)) != nil, into: %{}, do: {key, pruned}
  end

  # A value as OTLP carries it to the store.
  defp as_carried(value) when is_map(value) do
    for {key, item} <- value, key != "", into: %{}, do: {key, as_carried(item)}
  end

  defp as_carried(value) when is_list(value), do: Enum.map(value, &as_carried/1)

  defp as_carried(value) when is_integer(value) and (value > @max_i64 or value < @min_i64) do
    value * 1.0
  rescue
    ArithmeticError -> nil
  end

  defp as_carried(value), do: value

  defp attributes(record) do
    attributes =
      case object(record["attributes"]) do
        nil -> %{}
        attributes -> prune_object(attributes)
      end

    attributes =
      Map.reject(attributes, fn {key, _} -> String.starts_with?(key, @column_prefix) end)

    Enum.reduce(@syslog_attribute_keys, attributes, fn key, acc ->
      case prune(record[key]) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # A timestamp as Unix nanoseconds: RFC 3339 text, integer seconds,
  # milliseconds or nanoseconds told apart by magnitude, or fractional seconds.
  # Anything else is `fallback`. A time before 1970 is negative.
  defp unix_nanos(value, fallback) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :nanosecond)
      _ -> fallback
    end
  end

  defp unix_nanos(value, _fallback) when is_integer(value) and value >= 0 and value <= @max_u64 do
    cond do
      value > 1_000_000_000_000_000_000 -> value
      value > 1_000_000_000_000 -> value * 1_000_000
      true -> value * @nanos_per_second
    end
  end

  # Whole microseconds: a double cannot hold more for a current time.
  defp unix_nanos(value, _fallback) when is_float(value) and value >= -1.0e10 and value < 1.0e10,
    do: round(value * 1.0e6) * 1_000

  defp unix_nanos(_value, fallback), do: fallback

  # A syslog record is filed under the time its sender wrote. A record filed
  # under a wrong clock drops out of every recent view on either telemetry
  # backend, so one whose time is implausible, or before 1970, is filed under
  # the receive time and keeps what the sender wrote.
  defp sender_time(record, received) do
    sender =
      case first(record, [
             "timestamp",
             "time_unix_nano",
             "timeUnixNano",
             "observed_time_unix_nano",
             "observedTimeUnixNano"
           ]) do
        nil -> received
        value -> unix_nanos(value, received)
      end

    # Whole seconds: the sender's minus the receive time's.
    sender_seconds = Integer.floor_div(sender, @nanos_per_second)
    ahead = sender_seconds - Integer.floor_div(received, @nanos_per_second)

    if sender in 0..@max_u64//1 and not implausible_syslog_time?(record["_syslog_format"], ahead) do
      {sender, %{}}
    else
      original =
        if sender_seconds in @rfc3339_first_second..@rfc3339_last_second//1 do
          %{
            "_syslog_original_timestamp" =>
              sender_seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()
          }
        else
          %{}
        end

      {received, Map.put(original, "_syslog_timestamp_fallback", true)}
    end
  end

  defp implausible_syslog_time?("rfc3164", ahead), do: abs(ahead) > @rfc3164_tolerance_seconds

  defp implausible_syslog_time?(format, ahead) when is_binary(format),
    do: ahead > @syslog_ahead_seconds or ahead < -@syslog_behind_seconds

  defp implausible_syslog_time?(_format, _ahead), do: false

  defp observed_time(record, received) do
    observed =
      case first(record, [
             "observed_timestamp",
             "observedTimestamp",
             "observed_time_unix_nano",
             "observedTimeUnixNano"
           ]) do
        nil -> received
        value -> unix_nanos(value, received)
      end

    if observed in 0..@max_u64//1, do: observed, else: received
  end

  defp service(record, resource_attributes, snake, camel, resource_key) do
    field(record, snake, camel) || (resource_attributes && resource_attributes[resource_key])
  end

  defp service_name(record, resource_attributes) do
    service(record, resource_attributes, "service_name", "serviceName", "service.name") ||
      field(record, "application_name", "applicationName") ||
      field(record, "app_name", "appName") ||
      field(record, "host", "hostname") ||
      (resource_attributes &&
         (resource_attributes["host.name"] || resource_attributes["host_name"]))
  end

  # An optional sign and the digits that follow, whatever comes after them,
  # held to 64 bits.
  defp leading_integer(text) do
    case Regex.run(~r/\A[+-]?[0-9]+/, text) do
      [digits] -> digits |> String.to_integer() |> max(@min_i64) |> min(@max_i64)
      nil -> nil
    end
  end

  defp integer_field(value) when is_integer(value) and value >= @min_i64 and value <= @max_u64,
    do: min(value, @max_i64)

  defp integer_field(value) when is_binary(value), do: leading_integer(value)
  defp integer_field(_value), do: nil

  # An explicit severity text wins. Without one a syslog `level` decides both
  # columns, so a record no severity rule touched is still filed by severity.
  defp severity(record) do
    explicit = field(record, "severity_text", "severityText") || record["severity"] || nil

    number = integer_field(field(record, "severity_number", "severityNumber"))

    {text, number} =
      cond do
        is_binary(explicit) and explicit != "" ->
          {explicit, number}

        not is_nil(record["level"]) ->
          {level_text, level_number} = LogSeverity.from_level(record["level"])
          {level_text, number || level_number}

        true ->
          {text(explicit), number}
      end

    # OTLP numbers severities from 1.
    if is_integer(number) and number > 0 and number <= @max_i32,
      do: {text, number},
      else: {text, nil}
  end

  # OTLP carries the W3C trace flags in the low byte of `flags`, and cannot
  # tell an unset field from zero, so flags are recorded only with a trace.
  defp trace_flags(_record, nil), do: nil

  defp trace_flags(record, _trace_id) do
    case integer_field(first(record, ["trace_flags", "traceFlags", "flags"])) do
      flags when is_integer(flags) and flags > 0 and flags <= @max_u32 ->
        case band(flags, 0xFF) do
          0 -> nil
          low -> low
        end

      _ ->
        nil
    end
  end

  defp source_ip(record) do
    Enum.find_value(
      [field(record, "source_ip", "sourceIp"), record["_remote_addr"], record["source"]],
      &address/1
    )
  end

  # `[address]` or `[address]:port` without the brackets and port.
  defp bracketless(value) do
    case Regex.run(~r/\A\[([^\]]+)\](?::[0-9]+)?\z/, value, capture: :all_but_first) do
      [address] -> address
      _ -> value
    end
  end

  # Dotted-quad IPv4 with no leading zeros, or IPv6 with no zone.
  defp ip_address?(candidate) do
    cond do
      String.contains?(candidate, ":") ->
        not String.contains?(candidate, "%") and
          match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(candidate)))

      Regex.match?(~r/\A(?:(?:0|[1-9][0-9]{0,2})\.){3}(?:0|[1-9][0-9]{0,2})\z/, candidate) ->
        candidate |> String.split(".") |> Enum.all?(&(String.to_integer(&1) <= 255))

      true ->
        false
    end
  end

  defp scope(record) do
    described = record["scope"]
    scope_field = fn keys -> if is_map(described), do: first(described, keys) end
    named = if is_binary(described) and described != "", do: described

    name =
      field(record, "scope_name", "scopeName") ||
        scope_field.(["name", "scopeName", "scope_name"]) || named

    version =
      field(record, "scope_version", "scopeVersion") ||
        scope_field.(["version", "scopeVersion", "scope_version"])

    attributes =
      case object(field(record, "scope_attributes", "scopeAttributes") || described) do
        nil -> %{}
        attributes -> as_carried(attributes)
      end

    {text(name), text(version), attributes}
  end
end
