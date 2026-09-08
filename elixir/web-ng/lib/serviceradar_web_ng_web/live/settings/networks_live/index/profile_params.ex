defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.ProfileParams do
  @moduledoc false
  import ServiceRadarWebNGWeb.Settings.NetworksLive.FormComponents, only: [banner_grab_protocol_options: 0]

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperParams,
    only: [normalize_boolean: 2, normalize_integer: 2]

  def transform_profile_params(params) do
    params
    |> transform_ports_to_array()
    |> transform_banner_grab_params()
  end

  def transform_banner_grab_params(%{"banner_grab" => banner_grab} = params) when is_map(banner_grab) do
    Map.put(params, "banner_grab", normalize_banner_grab_params(banner_grab))
  end

  def transform_banner_grab_params(params), do: params

  def normalize_banner_grab_params(params) do
    params
    |> normalize_boolean("enabled")
    |> normalize_banner_protocols_param()
    |> normalize_banner_ports_param()
    |> normalize_integer("connect_timeout_ms")
    |> normalize_integer("read_timeout_ms")
    |> normalize_integer("max_banner_bytes")
    |> normalize_integer("max_concurrency_per_host")
    |> normalize_integer("max_global_concurrency")
    |> normalize_integer("max_probe_rate_per_second")
    |> normalize_integer("max_candidate_queue")
    |> normalize_integer("match_batch_size")
    |> normalize_integer("match_batch_max_bytes")
    |> normalize_integer("min_reprobe_interval_s")
    |> normalize_integer("per_host_rate_limit_ms")
  end

  def normalize_banner_protocols_param(params) do
    protocols =
      params
      |> Map.get("protocols", [])
      |> List.wrap()
      |> Enum.flat_map(&banner_protocol_atom/1)
      |> Enum.uniq()

    Map.put(params, "protocols", protocols)
  end

  def normalize_banner_ports_param(params) do
    selected_protocols =
      params
      |> Map.get("protocols", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    ports =
      params
      |> Map.get("ports", %{})
      |> normalize_banner_ports()
      |> Map.take(selected_protocols)

    Map.put(params, "ports", ports)
  end

  def normalize_banner_ports(ports) when is_map(ports) do
    Map.new(banner_grab_protocol_options(), fn {protocol, _label} ->
      values =
        ports
        |> Map.get(protocol, "")
        |> parse_banner_ports()

      {protocol, values}
    end)
  end

  def normalize_banner_ports(_ports), do: %{}

  def parse_banner_ports(value) when is_binary(value) do
    value
    |> String.split([",", " ", "\n", "\t"], trim: true)
    |> Enum.flat_map(&parse_port/1)
    |> Enum.uniq()
  end

  def parse_banner_ports(values) when is_list(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 > 0 and &1 <= 65_535))
    |> Enum.uniq()
  end

  def parse_banner_ports(_value), do: []

  def banner_protocol_atom(value) do
    case to_string(value) do
      "ssh" -> [:ssh]
      "http" -> [:http]
      "smb" -> [:smb]
      "ftp" -> [:ftp]
      "telnet" -> [:telnet]
      "smtp" -> [:smtp]
      "ntp" -> [:ntp]
      "dns" -> [:dns]
      "rdp" -> [:rdp]
      _ -> []
    end
  end

  def transform_ports_to_array(params) do
    case Map.get(params, "ports") do
      nil ->
        params

      "" ->
        Map.put(params, "ports", [])

      value when is_binary(value) ->
        ports =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&parse_port/1)

        Map.put(params, "ports", ports)

      value when is_list(value) ->
        params

      _ ->
        params
    end
  end

  def parse_port(port_str) do
    case Integer.parse(port_str) do
      {port, _} when port > 0 and port <= 65_535 -> [port]
      _ -> []
    end
  end
end
