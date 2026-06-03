defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.FormState do
  @moduledoc false

  @default_partition "default"
  @default_sample_interval_ms 60_000
  @default_retention_days 30
  @dpi_protocols ~w(http1 http2 tls dns ssh ftp quic mqtt bittorrent)
  @flow_protocols ~w(tcp udp quic)

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
      "fingerprint" => %{"tcp" => "true", "tls" => "true", "http" => "true"},
      "dpi" => %{
        "enabled" => "false",
        "protocols" => Map.new(@dpi_protocols, &{&1, "false"})
      },
      "flow_attribution" => Map.new(@flow_protocols, &{&1, "false"}),
      "process_snapshot_interval_s" => "0"
    }
  end

  def form_from_profile(profile) do
    fingerprint = profile.fingerprint || %{}
    dpi = profile.dpi || %{}
    dpi_protocols = dpi_protocols(dpi)
    flow_attribution = profile.flow_attribution || %{}

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
      },
      "dpi" => %{
        "enabled" => bool_string(map_truthy?(dpi, "enabled") or dpi_protocols != []),
        "protocols" =>
          Map.new(@dpi_protocols, fn protocol ->
            {protocol, bool_string(protocol in dpi_protocols or map_truthy?(dpi, protocol))}
          end)
      },
      "flow_attribution" =>
        Map.new(@flow_protocols, fn protocol ->
          {protocol, bool_string(map_truthy?(flow_attribution, protocol))}
        end),
      "process_snapshot_interval_s" => to_string(profile.process_snapshot_interval_s || 0)
    }
  end

  def normalize_form(params) do
    form = Map.merge(default_form(), stringify_params(params || %{}))

    fingerprint =
      Map.merge(default_form()["fingerprint"], stringify_params(form["fingerprint"] || %{}))

    dpi = Map.merge(default_form()["dpi"], stringify_params(form["dpi"] || %{}))

    dpi_protocols =
      Map.merge(default_form()["dpi"]["protocols"], stringify_params(dpi["protocols"] || %{}))

    flow_attribution =
      Map.merge(
        default_form()["flow_attribution"],
        stringify_params(form["flow_attribution"] || %{})
      )

    form
    |> Map.put("fingerprint", fingerprint)
    |> Map.put("dpi", Map.put(dpi, "protocols", dpi_protocols))
    |> Map.put("flow_attribution", flow_attribution)
  end

  def form_attrs(form) do
    dpi_enabled? = truthy?(form["dpi"]["enabled"])

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
      },
      dpi: %{
        "enabled" => dpi_enabled?,
        "protocols" => if(dpi_enabled?, do: selected_dpi_protocols(form["dpi"]["protocols"]), else: [])
      },
      flow_attribution: selected_flow_attribution(form["flow_attribution"]),
      process_snapshot_interval_s: parse_int(form["process_snapshot_interval_s"], 0)
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
      Enum.any?(
        parse_interfaces(form["capture_interfaces"]),
        &(&1 == "any" or String.contains?(&1, "*"))
      ),
      "Capture interfaces cannot use any or wildcards"
    )
    |> maybe_error(
      parse_int(form["sample_interval_ms"], -1) < 0,
      "Sample interval must be zero or greater"
    )
    |> maybe_error(parse_int(form["retention_days"], 0) < 1, "Retention must be at least one day")
    |> maybe_error(
      parse_int(form["process_snapshot_interval_s"], -1) < 0,
      "Process snapshot interval must be zero or greater"
    )
  end

  def target_count_label(nil), do: "Target count unknown"
  def target_count_label(1), do: "Targets 1 device"
  def target_count_label(count), do: "Targets #{count} devices"

  def dpi_protocols, do: @dpi_protocols
  def flow_protocols, do: @flow_protocols

  def fingerprint_enabled?(profile, name), do: map_truthy?(profile.fingerprint || %{}, name)

  def dpi_enabled?(profile, protocol) when protocol in @dpi_protocols do
    dpi = profile.dpi || %{}
    protocols = dpi_protocols(dpi)

    map_truthy?(dpi, "enabled") and (protocol in protocols or map_truthy?(dpi, protocol))
  end

  def dpi_enabled?(_profile, _protocol), do: false

  def flow_attribution_enabled?(profile, protocol) when protocol in @flow_protocols do
    map_truthy?(profile.flow_attribution || %{}, protocol)
  end

  def flow_attribution_enabled?(_profile, _protocol), do: false

  def process_snapshot_enabled?(profile) do
    (profile.process_snapshot_interval_s || 0) > 0
  end

  def map_truthy?(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key, atom_value(map, key, false)) in [true, "true", "1", 1, "on"]
  end

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

  defp selected_dpi_protocols(protocols) when is_map(protocols) do
    Enum.filter(@dpi_protocols, &truthy?(Map.get(protocols, &1)))
  end

  defp selected_dpi_protocols(_protocols), do: []

  defp selected_flow_attribution(protocols) when is_map(protocols) do
    Map.new(@flow_protocols, &{&1, truthy?(Map.get(protocols, &1))})
  end

  defp selected_flow_attribution(_protocols), do: Map.new(@flow_protocols, &{&1, false})

  defp dpi_protocols(dpi) when is_map(dpi) do
    dpi
    |> Map.get("protocols", atom_value(dpi, "protocols", []))
    |> List.wrap()
    |> Enum.filter(&(&1 in @dpi_protocols))
  end

  defp dpi_protocols(_dpi), do: []

  defp atom_value(map, key, default) do
    case key do
      "enabled" -> Map.get(map, :enabled, default)
      "protocols" -> Map.get(map, :protocols, default)
      "tcp" -> Map.get(map, :tcp, default)
      "tls" -> Map.get(map, :tls, default)
      "http" -> Map.get(map, :http, default)
      "http1" -> Map.get(map, :http1, default)
      "http2" -> Map.get(map, :http2, default)
      "dns" -> Map.get(map, :dns, default)
      "ssh" -> Map.get(map, :ssh, default)
      "ftp" -> Map.get(map, :ftp, default)
      "quic" -> Map.get(map, :quic, default)
      "mqtt" -> Map.get(map, :mqtt, default)
      "bittorrent" -> Map.get(map, :bittorrent, default)
      "udp" -> Map.get(map, :udp, default)
      _ -> default
    end
  end

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
  defp bool_string(true), do: "true"
  defp bool_string(_), do: "false"
  defp trim(value), do: String.trim(to_string(value || ""))
  defp blank_to_nil(value), do: if(trim(value) == "", do: nil, else: trim(value))
end
