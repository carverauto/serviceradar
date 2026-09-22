defmodule ServiceRadar.Observability.EventTitle do
  @moduledoc """
  Derives human-readable titles for event-backed alerts.
  """

  @fallback_alert_title "Alert"
  @fallback_event_title "Event Triggered"
  @max_title_length 180

  @generic_alert_titles MapSet.new([
                          "",
                          "alert",
                          "event",
                          "event triggered",
                          "anomaly finding",
                          "capacity forecast finding",
                          "falco security incident",
                          "causal prediction health finding"
                        ])

  @generic_alert_messages MapSet.new([
                            "causal prediction finding detected",
                            "capacity forecast warning-horizon finding detected",
                            "falco security incident detected",
                            "endpoint inventory vulnerability detected"
                          ])

  @spec alert_title(map()) :: String.t()
  def alert_title(alert) when is_map(alert) do
    explicit = text_value(alert, "title")

    if present?(explicit) and not generic_alert_title?(explicit) do
      explicit
    else
      first_present([
        finding_subject(alert),
        unless_generic_message(message_title(text_value(alert, "description"))),
        unless_generic_message(message_title(text_value(alert, "message"))),
        unless_generic_message(message_title(text_value(alert, "short_message")))
      ]) || explicit || @fallback_alert_title
    end
  end

  def alert_title(_alert), do: @fallback_alert_title

  @spec event_title(map()) :: String.t()
  def event_title(event) when is_map(event) do
    first_present([
      message_title(text_value(event, "description")),
      message_title(text_value(event, "message")),
      message_title(text_value(event, "short_message")),
      source_event_title(event)
    ])
  end

  def event_title(_event), do: @fallback_event_title

  @spec generic_alert_title?(term()) :: boolean()
  def generic_alert_title?(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    MapSet.member?(@generic_alert_titles, normalized) or
      String.starts_with?(normalized, "event: logs.")
  end

  def generic_alert_title?(_value), do: true

  defp finding_subject(alert) when is_map(alert) do
    values = group_values(alert)
    series = decode_series_key(group_value(values, ["anomaly.series_key", "series_key"]))

    metric =
      first_present([
        text_value(alert, "metric_name"),
        series_component(series, "metric")
      ])

    identity =
      first_present([
        group_value(values, ["hostname"]),
        series_component(series, "identity"),
        series_component(series, "hint"),
        group_value(values, ["capacity_forecast.resource_key", "resource_key"]),
        short_device(group_value(values, ["device"]) || text_value(alert, "device_uid"))
      ])

    rule = group_value(values, ["rule"])
    kind = finding_kind(alert, values)

    parts =
      cond do
        present?(rule) ->
          [rule, identity]

        present?(metric) or present?(identity) ->
          [kind, metric, identity]

        true ->
          []
      end

    parts
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [single] -> normalize_title(single)
      list -> normalize_title(Enum.join(list, " · "))
    end
  end

  defp finding_subject(_), do: nil

  defp finding_kind(alert, values) do
    rule_name =
      nested_text(alert, ["metadata", "incident_rule_name"]) ||
        nested_text(alert, ["metadata", "incident_diagnostics", "rule_name"])

    cond do
      present?(group_value(values, ["anomaly.series_key", "series_key"])) ->
        "Anomaly"

      present?(rule_name) and String.contains?(to_string(rule_name), "anomaly") ->
        "Anomaly"

      present?(rule_name) and String.contains?(to_string(rule_name), "capacity") ->
        "Capacity"

      generic_alert_title?(text_value(alert, "title")) and
          String.contains?(String.downcase(text_value(alert, "title") || ""), "anomaly") ->
        "Anomaly"

      generic_alert_title?(text_value(alert, "title")) and
          String.contains?(String.downcase(text_value(alert, "title") || ""), "capacity") ->
        "Capacity"

      true ->
        nil
    end
  end

  defp group_values(alert) do
    metadata = map_field(alert, "metadata")
    diagnostics = map_field(metadata, "incident_diagnostics")

    case map_field(metadata, "incident_group_values") do
      values when map_size(values) > 0 -> values
      _ -> map_field(diagnostics, "group_values")
    end
  end

  defp group_value(values, keys) when is_list(keys) do
    Enum.find_value(keys, &group_value(values, &1))
  end

  defp group_value(values, key) when is_map(values) and is_binary(key) do
    case Map.get(values, key) do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> value |> Atom.to_string() |> String.trim()
      _ -> nil
    end
  end

  defp group_value(_, _), do: nil

  defp decode_series_key(value) when is_binary(value) do
    value = String.trim(value)

    delimiter =
      cond do
        String.starts_with?(value, "v2|") -> "|"
        String.starts_with?(value, "v2:") -> ":"
        true -> nil
      end

    if is_binary(delimiter) do
      value
      |> String.split(delimiter)
      |> Enum.drop(1)
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(part, "=", parts: 2) do
          [key, encoded] when key != "" ->
            Map.put(acc, key, decode_series_component(encoded))

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  end

  defp decode_series_key(_), do: %{}

  defp series_component(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp series_component(_, _), do: nil

  defp decode_series_component(value) when is_binary(value) do
    if rem(byte_size(value), 2) == 0 and String.match?(value, ~r/\A[0-9a-fA-F]+\z/) do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} -> if String.printable?(decoded), do: decoded, else: value
        :error -> value
      end
    else
      value
    end
  end

  defp decode_series_component(value), do: to_string(value)

  defp short_device(nil), do: nil
  defp short_device(""), do: nil

  defp short_device("sr:" <> rest) when byte_size(rest) > 12 do
    nil
  end

  defp short_device(uid) when is_binary(uid) do
    if String.starts_with?(uid, "sr:"), do: nil, else: uid
  end

  defp short_device(_), do: nil

  defp unless_generic_message(nil), do: nil

  defp unless_generic_message(value) when is_binary(value) do
    if MapSet.member?(@generic_alert_messages, String.downcase(String.trim(value))),
      do: nil,
      else: value
  end

  defp unless_generic_message(_), do: nil

  defp map_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, atom_key(key)) do
      %{} = nested -> nested
      _ -> %{}
    end
  end

  defp map_field(_, _), do: %{}

  defp nested_text(map, keys) when is_map(map) and is_list(keys) do
    keys
    |> Enum.reduce_while(map, fn key, acc ->
      case acc do
        %{} = current ->
          {:cont, Map.get(current, key) || Map.get(current, atom_key(key))}

        _ ->
          {:halt, nil}
      end
    end)
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp nested_text(_, _), do: nil

  defp message_title(nil), do: nil

  defp message_title(message) do
    message
    |> extract_message_field()
    |> extract_cef_name(message)
    |> normalize_title()
  end

  defp extract_message_field(message) do
    case Regex.run(~r/(?:^|\s)msg=(.+)$/i, message, capture: :all_but_first) do
      [msg] -> msg
      _ -> message
    end
  end

  defp extract_cef_name(title, original) do
    cond do
      present?(title) and title != original ->
        title

      String.starts_with?(String.trim(original), "CEF:") ->
        original
        |> String.split("|", parts: 8)
        |> Enum.at(5)
        |> case do
          name when is_binary(name) and name != "" -> name
          _ -> title
        end

      true ->
        title
    end
  end

  defp source_event_title(event) do
    event
    |> text_value("log_name")
    |> case do
      value when is_binary(value) and value != "" -> "Event: #{value}"
      _ -> @fallback_event_title
    end
  end

  defp text_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, atom_key(key)) do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) and value != nil -> value |> Atom.to_string() |> String.trim()
      value when is_number(value) -> value |> to_string() |> String.trim()
      _ -> nil
    end
  end

  defp atom_key("description"), do: :description
  defp atom_key("message"), do: :message
  defp atom_key("short_message"), do: :short_message
  defp atom_key("log_name"), do: :log_name
  defp atom_key("title"), do: :title
  defp atom_key("metadata"), do: :metadata
  defp atom_key("metric_name"), do: :metric_name
  defp atom_key("device_uid"), do: :device_uid
  defp atom_key("incident_diagnostics"), do: :incident_diagnostics
  defp atom_key("incident_group_values"), do: :incident_group_values
  defp atom_key("incident_rule_name"), do: :incident_rule_name
  defp atom_key("rule_name"), do: :rule_name
  defp atom_key("group_values"), do: :group_values
  defp atom_key(_key), do: :__unknown__

  defp first_present(values) do
    Enum.find(values, &present?/1)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_title(nil), do: nil

  defp normalize_title(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    cond do
      value == "" ->
        nil

      String.length(value) > @max_title_length ->
        String.slice(value, 0, @max_title_length) <> "..."

      true ->
        value
    end
  end
end
