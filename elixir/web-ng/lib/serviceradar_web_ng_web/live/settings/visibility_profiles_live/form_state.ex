defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.FormState do
  @moduledoc false

  @default_partition "default"
  @default_sample_interval_ms 60_000
  @default_retention_days 30

  def default_form do
    %{
      "name" => "",
      "description" => "",
      "enabled" => "true",
      "target_query" => "",
      "priority" => "0",
      "capture_interfaces" => "",
      "sample_interval_ms" => Integer.to_string(@default_sample_interval_ms),
      "retention_days" => Integer.to_string(@default_retention_days),
      "partition_id" => @default_partition,
      "fingerprint" => %{"tcp" => "true", "tls" => "true", "http" => "true"}
    }
  end

  def form_from_profile(profile) do
    fingerprint = profile.fingerprint || %{}

    %{
      "name" => profile.name || "",
      "description" => profile.description || "",
      "enabled" => bool_string(profile.enabled),
      "target_query" => profile.target_query || "",
      "priority" => to_string(profile.priority || 0),
      "capture_interfaces" => Enum.join(profile.capture_interfaces || [], "\n"),
      "sample_interval_ms" => to_string(profile.sample_interval_ms || @default_sample_interval_ms),
      "retention_days" => to_string(profile.retention_days || @default_retention_days),
      "partition_id" => profile.partition_id || @default_partition,
      "fingerprint" => %{
        "tcp" => bool_string(map_truthy?(fingerprint, "tcp")),
        "tls" => bool_string(map_truthy?(fingerprint, "tls")),
        "http" => bool_string(map_truthy?(fingerprint, "http"))
      }
    }
  end

  def normalize_form(params) do
    form = Map.merge(default_form(), stringify_params(params || %{}))
    fingerprint = Map.merge(default_form()["fingerprint"], stringify_params(form["fingerprint"] || %{}))
    Map.put(form, "fingerprint", fingerprint)
  end

  def form_attrs(form) do
    %{
      name: trim(form["name"]),
      description: blank_to_nil(form["description"]),
      enabled: truthy?(form["enabled"]),
      target_query: blank_to_nil(form["target_query"]),
      priority: parse_int(form["priority"], 0),
      capture_interfaces: parse_interfaces(form["capture_interfaces"]),
      sample_interval_ms: parse_int(form["sample_interval_ms"], @default_sample_interval_ms),
      retention_days: parse_int(form["retention_days"], @default_retention_days),
      partition_id: blank_to_nil(form["partition_id"]) || @default_partition,
      fingerprint: %{
        "tcp" => truthy?(form["fingerprint"]["tcp"]),
        "tls" => truthy?(form["fingerprint"]["tls"]),
        "http" => truthy?(form["fingerprint"]["http"])
      }
    }
  end

  def validate_form(form) do
    []
    |> maybe_error(trim(form["name"]) == "", "Name is required")
    |> maybe_error(
      truthy?(form["enabled"]) and parse_interfaces(form["capture_interfaces"]) == [],
      "At least one capture interface is required when enabled"
    )
    |> maybe_error(
      Enum.any?(parse_interfaces(form["capture_interfaces"]), &(&1 == "any" or String.contains?(&1, "*"))),
      "Capture interfaces cannot use any or wildcards"
    )
    |> maybe_error(parse_int(form["sample_interval_ms"], -1) < 0, "Sample interval must be zero or greater")
    |> maybe_error(parse_int(form["retention_days"], 0) < 1, "Retention must be at least one day")
  end

  def target_count_label(nil), do: "Target count unknown"
  def target_count_label(1), do: "Targets 1 device"
  def target_count_label(count), do: "Targets #{count} devices"

  def fingerprint_enabled?(profile, name), do: map_truthy?(profile.fingerprint || %{}, name)
  def map_truthy?(map, "tcp"), do: Map.get(map, "tcp", Map.get(map, :tcp, false)) in [true, "true", "1", 1]
  def map_truthy?(map, "tls"), do: Map.get(map, "tls", Map.get(map, :tls, false)) in [true, "true", "1", 1]
  def map_truthy?(map, "http"), do: Map.get(map, "http", Map.get(map, :http, false)) in [true, "true", "1", 1]
  def map_truthy?(_map, _key), do: false

  def truthy?(value), do: value in [true, "true", "1", 1, "on"]

  def parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {int, ""} -> int
      _ -> default
    end
  end

  def parse_interfaces(value) do
    value
    |> to_string()
    |> String.split([",", "\n", "\r", "\t"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def stringify_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  def stringify_params(_params), do: %{}

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
  defp bool_string(true), do: "true"
  defp bool_string(_), do: "false"
  defp trim(value), do: String.trim(to_string(value || ""))
  defp blank_to_nil(value), do: if(trim(value) == "", do: nil, else: trim(value))
end
