defmodule ServiceRadarWebNGWeb.ServiceLive.Service do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  def name(%{} = service) do
    Map.get(service, "service_name") ||
      Map.get(service, "name") ||
      Map.get(service, "service") ||
      Map.get(service, "check_name")
  end

  def name(_service), do: nil

  def type(%{} = service) do
    Map.get(service, "service_type") ||
      Map.get(service, "type") ||
      Map.get(service, "check_type") ||
      Map.get(service, "service_kind")
  end

  def type(_service), do: nil

  def status(service, details) when is_map(service) and is_map(details) do
    Map.get(details, "status") || Map.get(service, "status")
  end

  def summary(service, details) when is_map(service) and is_map(details) do
    Map.get(details, "summary") ||
      get_in(details, ["reported_result", "summary"]) ||
      Map.get(service, "message")
  end

  def parse_details(%{} = service) do
    details = Map.get(service, "details") || Map.get(service, :details)

    cond do
      is_map(details) -> details
      is_binary(details) -> parse_details_json(details)
      true -> %{}
    end
  end

  def parse_details(_service), do: %{}

  def display_instructions(details) when is_map(details) do
    Map.get(details, "display") ||
      get_in(details, ["ui", "display"]) ||
      get_in(details, ["reported_result", "display"]) ||
      get_in(details, ["reported_result", "ui", "display"]) ||
      []
  end

  def display_instructions(_details), do: []

  def plugin_id(details) when is_map(details) do
    get_in(details, ["labels", "plugin_id"]) ||
      get_in(details, [:labels, :plugin_id]) ||
      Map.get(details, "plugin_id") ||
      Map.get(details, :plugin_id) ||
      get_in(details, ["reported_result", "labels", "plugin_id"]) ||
      get_in(details, ["reported_result", "plugin_id"])
  end

  def plugin_id(_details), do: nil

  def filter_display(display, contract) when is_list(display) and is_map(contract) do
    allowed = Map.get(contract, "widgets") || Map.get(contract, :widgets) || []

    if is_list(allowed) and allowed != [] do
      Enum.filter(display, fn item ->
        widget = Map.get(item, "widget") || Map.get(item, :widget)
        is_binary(widget) and widget in allowed
      end)
    else
      display
    end
  end

  def filter_display(display, _contract), do: display

  def schema_version(details, contract) when is_map(details) and is_map(contract) do
    detail_version =
      Map.get(details, "schema_version") ||
        get_in(details, ["display", "schema_version"]) ||
        get_in(details, ["reported_result", "schema_version"]) ||
        get_in(details, ["reported_result", "display", "schema_version"])

    contract_version = Map.get(contract, "schema_version") || Map.get(contract, :schema_version)

    cond do
      is_integer(detail_version) -> detail_version
      is_integer(contract_version) -> contract_version
      true -> nil
    end
  end

  def normalize_available(true), do: true
  def normalize_available(false), do: false
  def normalize_available(1), do: true
  def normalize_available(0), do: false

  def normalize_available(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "true" -> true
      "t" -> true
      "1" -> true
      "false" -> false
      "f" -> false
      "0" -> false
      _ -> nil
    end
  end

  def normalize_available(_value), do: nil

  def timestamp(%{} = service) do
    case parse_iso_timestamp(Map.get(service, "timestamp")) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  def timestamp(_service), do: nil

  def timestamp_fallback(%{} = service) do
    case Map.get(service, "timestamp") do
      value when is_binary(value) and value != "" -> value
      %DateTime{} = value -> DateTime.to_iso8601(value)
      %NaiveDateTime{} = value -> NaiveDateTime.to_iso8601(value)
      value when is_integer(value) or is_float(value) -> to_string(value)
      _ -> "—"
    end
  end

  def timestamp_fallback(_service), do: "—"

  def parse_iso_timestamp(nil), do: :error
  def parse_iso_timestamp(""), do: :error
  def parse_iso_timestamp(%DateTime{} = value), do: {:ok, value}

  def parse_iso_timestamp(%NaiveDateTime{} = value) do
    {:ok, DateTime.from_naive!(value, "Etc/UTC")}
  end

  def parse_iso_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, datetime} -> {:ok, DateTime.from_naive!(datetime, "Etc/UTC")}
          {:error, _reason} -> :error
        end
    end
  end

  def parse_iso_timestamp(_value), do: :error

  def details_path(service) do
    ~p"/services/check?#{details_params(service)}"
  end

  def details_params(%{} = service) do
    %{
      "service_id" => safe_param(Map.get(service, "service_id") || Map.get(service, "uid")),
      "timestamp" => safe_param(Map.get(service, "timestamp")),
      "service_name" => safe_param(name(service)),
      "service_type" => safe_param(type(service)),
      "gateway_id" => safe_param(Map.get(service, "gateway_id")),
      "agent_id" => safe_param(Map.get(service, "agent_id")),
      "partition" => safe_param(Map.get(service, "partition"))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  def details_params(_service), do: %{}

  defp parse_details_json(value) do
    case Jason.decode(value) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp safe_param(nil), do: nil

  defp safe_param(value) when is_binary(value) do
    if String.valid?(value), do: value
  end

  defp safe_param(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe_param(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp safe_param(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp safe_param(value), do: value |> to_string() |> safe_param()
end
