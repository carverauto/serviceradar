defmodule ServiceRadar.Core.ResultProcessor do
  @moduledoc """
  Processes sweep results and converts them to device updates.

  Port of Go core's result_processor.go. Handles:
  - Processing host results from network sweeps
  - Building metadata (response time, ICMP status, port results)
  - Resolving canonical identities via DeviceLookup
  - Converting to DeviceUpdate format for persistence

  ## Usage

      # Process sweep host results
      device_updates = ResultProcessor.process_host_results(
        hosts,
        poller_id: "poller-1",
        partition: "default",
        agent_id: "agent-1"
      )
  """

  alias ServiceRadar.Identity.DeviceLookup

  require Logger

  # Limits for metadata encoding
  @max_port_results_detailed 512
  @max_open_ports_detailed 256

  @type host_result :: %{
          optional(:host) => String.t(),
          optional(:available) => boolean(),
          optional(:response_time_ns) => non_neg_integer(),
          optional(:icmp_status) => icmp_status(),
          optional(:port_results) => [port_result()]
        }

  @type icmp_status :: %{
          optional(:available) => boolean(),
          optional(:round_trip_ns) => non_neg_integer(),
          optional(:packet_loss) => float()
        }

  @type port_result :: %{
          optional(:port) => non_neg_integer(),
          optional(:available) => boolean(),
          optional(:response_time_ns) => non_neg_integer()
        }

  @type device_update :: %{
          agent_id: String.t(),
          poller_id: String.t(),
          partition: String.t(),
          device_id: String.t() | nil,
          source: atom(),
          ip: String.t(),
          mac: String.t() | nil,
          hostname: String.t() | nil,
          timestamp: DateTime.t(),
          is_available: boolean(),
          metadata: map()
        }

  @doc """
  Process host results from a sweep and convert to device updates.

  ## Options

  - `:poller_id` - ID of the poller that ran the sweep (required)
  - `:partition` - Partition context (required)
  - `:agent_id` - ID of the agent managing the poller (required)
  - `:timestamp` - Timestamp for the results (default: now)
  - `:resolve_identities` - Whether to lookup canonical identities (default: true)
  - `:actor` - Actor for authorization context

  ## Examples

      hosts = [
        %{host: "192.168.1.100", available: true, response_time_ns: 5_000_000},
        %{host: "192.168.1.101", available: false}
      ]

      updates = ResultProcessor.process_host_results(hosts,
        poller_id: "poller-1",
        partition: "default",
        agent_id: "agent-1"
      )
  """
  @spec process_host_results([host_result()], keyword()) :: [device_update()]
  def process_host_results(hosts, opts \\ []) do
    poller_id = Keyword.fetch!(opts, :poller_id)
    partition = Keyword.fetch!(opts, :partition)
    agent_id = Keyword.fetch!(opts, :agent_id)
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    resolve_identities = Keyword.get(opts, :resolve_identities, true)
    actor = Keyword.get(opts, :actor)

    # Extract unique IPs for batch identity resolution
    canonical_by_ip =
      if resolve_identities do
        hosts
        |> Enum.map(&get_host_ip/1)
        |> Enum.reject(&(&1 == ""))
        |> lookup_canonical_sweep_identities(actor: actor)
      else
        %{}
      end

    hosts
    |> Enum.filter(&valid_host?/1)
    |> Enum.map(fn host ->
      build_device_update(host, %{
        poller_id: poller_id,
        partition: partition,
        agent_id: agent_id,
        timestamp: timestamp,
        canonical_by_ip: canonical_by_ip
      })
    end)
  end

  @doc """
  Build host metadata from a host result.

  Extracts response time, ICMP status, and port results into
  a flat metadata map suitable for storage.
  """
  @spec build_host_metadata(host_result()) :: map()
  def build_host_metadata(host) do
    %{}
    |> add_response_time_metadata(host)
    |> add_icmp_metadata(host)
    |> add_port_metadata(host)
  end

  # Private functions

  defp valid_host?(host) do
    ip = get_host_ip(host)
    ip != ""
  end

  defp get_host_ip(host) do
    host[:host] || host["host"] || ""
  end

  defp build_device_update(host, context) do
    ip = get_host_ip(host)
    available = host[:available] || host["available"] || false
    metadata = build_host_metadata(host)

    update = %{
      agent_id: context.agent_id,
      poller_id: context.poller_id,
      partition: context.partition,
      device_id: nil,
      source: :sweep,
      ip: ip,
      mac: nil,
      hostname: nil,
      timestamp: context.timestamp,
      is_available: available,
      metadata: metadata
    }

    # Apply canonical identity if found
    case Map.get(context.canonical_by_ip, ip) do
      nil -> update
      snapshot -> apply_canonical_snapshot(update, snapshot)
    end
  end

  defp add_response_time_metadata(metadata, host) do
    response_time = host[:response_time_ns] || host["response_time_ns"]

    if is_integer(response_time) and response_time > 0 do
      Map.put(metadata, "response_time_ns", Integer.to_string(response_time))
    else
      metadata
    end
  end

  defp add_icmp_metadata(metadata, host) do
    icmp_status = host[:icmp_status] || host["icmp_status"]

    if is_map(icmp_status) do
      metadata
      |> put_if_present(
        "icmp_available",
        icmp_status[:available] || icmp_status["available"],
        &to_string/1
      )
      |> put_if_present(
        "icmp_round_trip_ns",
        icmp_status[:round_trip_ns] || icmp_status["round_trip_ns"],
        &Integer.to_string/1
      )
      |> put_if_present(
        "icmp_packet_loss",
        icmp_status[:packet_loss] || icmp_status["packet_loss"],
        &Float.to_string/1
      )
    else
      metadata
    end
  end

  defp add_port_metadata(metadata, host) do
    port_results = host[:port_results] || host["port_results"] || []

    if is_list(port_results) and length(port_results) > 0 do
      encode_port_results(metadata, port_results)
    else
      metadata
    end
  end

  defp encode_port_results(metadata, port_results) do
    total_ports = length(port_results)
    trim_limit = @max_port_results_detailed

    {encoded_ports, truncated} =
      if total_ports > trim_limit do
        {Enum.take(port_results, trim_limit), true}
      else
        {port_results, false}
      end

    metadata =
      metadata
      |> Map.put("port_result_count", Integer.to_string(total_ports))
      |> Map.put("port_results_truncated", to_string(truncated))
      |> Map.put("port_results_retained", Integer.to_string(length(encoded_ports)))

    # Encode port results as JSON
    metadata =
      case Jason.encode(encoded_ports) do
        {:ok, json} -> Map.put(metadata, "port_results", json)
        {:error, error} -> Map.put(metadata, "port_results_error", inspect(error))
      end

    # Extract open ports
    open_ports =
      port_results
      |> Enum.filter(fn pr ->
        (pr[:available] || pr["available"]) == true
      end)
      |> Enum.map(fn pr ->
        pr[:port] || pr["port"]
      end)
      |> Enum.filter(&is_integer/1)

    if length(open_ports) > 0 do
      encode_open_ports(metadata, open_ports)
    else
      metadata
    end
  end

  defp encode_open_ports(metadata, open_ports) do
    open_limit = @max_open_ports_detailed

    {encoded_ports, truncated} =
      if length(open_ports) > open_limit do
        {Enum.take(open_ports, open_limit), true}
      else
        {open_ports, false}
      end

    metadata =
      metadata
      |> Map.put("open_port_count", Integer.to_string(length(open_ports)))
      |> Map.put("open_ports_truncated", to_string(truncated))

    case Jason.encode(encoded_ports) do
      {:ok, json} -> Map.put(metadata, "open_ports", json)
      {:error, error} -> Map.put(metadata, "open_ports_error", inspect(error))
    end
  end

  defp put_if_present(metadata, _key, nil, _formatter), do: metadata

  defp put_if_present(metadata, key, value, formatter) do
    Map.put(metadata, key, formatter.(value))
  end

  @doc false
  @spec lookup_canonical_sweep_identities([String.t()], keyword()) :: %{String.t() => map()}
  def lookup_canonical_sweep_identities(ips, opts \\ []) do
    unique_ips =
      ips
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if Enum.empty?(unique_ips) do
      %{}
    else
      DeviceLookup.batch_lookup_by_ip(unique_ips, opts)
    end
  end

  defp apply_canonical_snapshot(update, snapshot) do
    update =
      if is_binary(snapshot.canonical_device_id) and snapshot.canonical_device_id != "" do
        metadata =
          update.metadata
          |> Map.put("canonical_device_id", snapshot.canonical_device_id)

        %{update | device_id: snapshot.canonical_device_id, metadata: metadata}
      else
        update
      end

    # Apply MAC if available in attributes
    update =
      case get_in(snapshot, [:attributes, "mac"]) do
        mac when is_binary(mac) and mac != "" ->
          mac = String.upcase(mac)
          metadata = Map.put(update.metadata, "mac", mac)
          %{update | mac: mac, metadata: metadata}

        _ ->
          update
      end

    # Apply hostname if available
    update =
      case get_in(snapshot, [:attributes, "hostname"]) do
        hostname when is_binary(hostname) and hostname != "" ->
          %{update | hostname: hostname}

        _ ->
          update
      end

    # Copy integration identifiers
    copy_if_empty = fn update, key ->
      case get_in(snapshot, [:attributes, key]) do
        value when is_binary(value) and value != "" ->
          if Map.get(update.metadata, key, "") == "" do
            %{update | metadata: Map.put(update.metadata, key, value)}
          else
            update
          end

        _ ->
          update
      end
    end

    update
    |> copy_if_empty.("armis_device_id")
    |> copy_if_empty.("integration_id")
    |> copy_if_empty.("integration_type")
    |> copy_if_empty.("netbox_device_id")
    |> copy_if_empty.("canonical_partition")
    |> copy_if_empty.("canonical_hostname")
  end

  @doc """
  Check if a snapshot has strong identity markers.

  A "strong" identity means the device can be reliably identified
  by something other than just IP address.
  """
  @spec has_strong_identity?(map()) :: boolean()
  def has_strong_identity?(snapshot) when is_map(snapshot) do
    device_id =
      Map.get(snapshot, :canonical_device_id) || Map.get(snapshot, "canonical_device_id")

    attributes = Map.get(snapshot, :attributes) || Map.get(snapshot, "attributes") || %{}

    cond do
      is_binary(device_id) and String.trim(device_id) != "" ->
        true

      is_binary(Map.get(attributes, "mac")) and String.trim(Map.get(attributes, "mac", "")) != "" ->
        true

      is_binary(Map.get(attributes, "armis_device_id")) and
          String.trim(Map.get(attributes, "armis_device_id", "")) != "" ->
        true

      is_binary(Map.get(attributes, "integration_id")) and
          String.trim(Map.get(attributes, "integration_id", "")) != "" ->
        true

      is_binary(Map.get(attributes, "netbox_device_id")) and
          String.trim(Map.get(attributes, "netbox_device_id", "")) != "" ->
        true

      true ->
        false
    end
  end

  def has_strong_identity?(_), do: false
end
