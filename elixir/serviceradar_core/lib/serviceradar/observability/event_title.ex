defmodule ServiceRadar.Observability.EventTitle do
  @moduledoc """
  Derives human-readable titles for event-backed alerts.
  """

  @fallback_alert_title "Alert"
  @fallback_event_title "Event Triggered"
  @max_title_length 180

  @spec alert_title(map()) :: String.t()
  def alert_title(alert) when is_map(alert) do
    explicit = text_value(alert, "title")

    if present?(explicit) and not generic_alert_title?(explicit) do
      explicit
    else
      event_title(alert) || @fallback_alert_title
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

    normalized in ["", "alert", "event", "event triggered"] or
      String.starts_with?(normalized, "event: logs.")
  end

  def generic_alert_title?(_value), do: true

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
      value when is_atom(value) -> value |> Atom.to_string() |> String.trim()
      value when is_number(value) -> value |> to_string() |> String.trim()
      _ -> nil
    end
  end

  defp atom_key("description"), do: :description
  defp atom_key("message"), do: :message
  defp atom_key("short_message"), do: :short_message
  defp atom_key("log_name"), do: :log_name
  defp atom_key("title"), do: :title
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
