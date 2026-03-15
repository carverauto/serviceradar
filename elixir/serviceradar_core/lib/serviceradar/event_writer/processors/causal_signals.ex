defmodule ServiceRadar.EventWriter.Processors.CausalSignals do
  @moduledoc """
  Processor for external causal signals (BMP and SIEM) consumed via JetStream.

  This processor normalizes external events into a common causal envelope and
  persists them in `ocsf_events` so downstream topology overlays can evaluate
  causality from a durable source.

  Expected subjects include:
  - `arancini.updates.>`
  - `siem.events.>`
  - `signals.causal.>`
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Observability.BmpSettingsRuntime
  alias ServiceRadar.Observability.CausalPubSub

  require Logger

  @schema_version "1.0"
  @max_grouped_contexts 32
  @routing_table "bmp_routing_events"

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    parsed_rows =
      messages
      |> Enum.map(&parse_components/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(parsed_rows) do
      {:ok, 0}
    else
      routing_rows =
        parsed_rows
        |> Enum.filter(&(&1.normalized["signal_type"] == "bmp"))
        |> Enum.map(&build_routing_event_row/1)
        |> Enum.reject(&is_nil/1)

      ocsf_rows =
        parsed_rows
        |> Enum.filter(&persist_to_ocsf?/1)
        |> Enum.map(fn %{
                         normalized: normalized,
                         payload: payload,
                         raw_data: raw_data,
                         metadata: metadata
                       } ->
          build_ocsf_event_row(normalized, payload, raw_data, metadata)
        end)

      _ = insert_rows(@routing_table, routing_rows)
      ocsf_count = insert_rows(table_name(), ocsf_rows)

      CausalPubSub.broadcast_ingest(%{count: ocsf_count})
      {:ok, length(parsed_rows)}
    end
  rescue
    e ->
      Logger.error("Causal signals batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case parse_components(%{data: data, metadata: metadata}) do
      %{normalized: normalized, payload: payload, raw_data: raw_data, metadata: row_metadata} ->
        build_ocsf_event_row(normalized, payload, raw_data, row_metadata)

      nil ->
        nil
    end
  end

  defp parse_components(%{data: data, metadata: metadata}) do
    with {:ok, payload} <- decode_payload(data, metadata),
         {:ok, normalized} <- normalize_payload(payload, metadata, data) do
      %{
        normalized: normalized,
        payload: payload,
        raw_data: data,
        metadata: metadata
      }
    else
      _ ->
        Logger.debug("Failed to parse causal signal payload", subject: metadata[:subject])
        nil
    end
  end

  defp parse_components(_), do: nil

  defp decode_payload(data, metadata) when is_binary(data) and is_map(metadata) do
    case Jason.decode(data) do
      {:ok, payload} ->
        {:ok, payload}

      _ ->
        decode_arancini_capnp_payload(data, metadata)
    end
  end

  defp decode_payload(_data, _metadata), do: {:error, :invalid_payload}

  defp decode_arancini_capnp_payload(data, %{subject: subject}) when is_binary(subject) do
    if arancini_subject?(subject) do
      with {:ok, json_payload} <- ServiceRadarSRQL.Native.decode_arancini_update_capnp(data),
           {:ok, payload} <- Jason.decode(json_payload) do
        {:ok, payload}
      else
        _ -> {:error, :invalid_payload}
      end
    else
      {:error, :invalid_payload}
    end
  end

  defp decode_arancini_capnp_payload(_data, _metadata), do: {:error, :invalid_payload}

  defp insert_rows(_table, []), do: 0

  defp insert_rows(table, rows) when is_list(rows) do
    {count, _} =
      ServiceRadar.Repo.insert_all(table, rows, on_conflict: :nothing, returning: false)

    count
  end

  defp persist_to_ocsf?(%{normalized: normalized}) when is_map(normalized) do
    signal_type = normalized["signal_type"]
    event_type = normalized["event_type"]
    severity_id = normalized["severity_id"] || 0

    cond do
      signal_type != "bmp" ->
        true

      event_type in ["peer_up", "peer_down"] ->
        true

      severity_id >= bmp_ocsf_min_severity() ->
        true

      true ->
        false
    end
  end

  defp persist_to_ocsf?(_), do: false

  defp bmp_ocsf_min_severity do
    BmpSettingsRuntime.bmp_ocsf_min_severity()
  end

  defp build_routing_event_row(%{normalized: normalized, payload: payload, raw_data: raw_data}) do
    correlation = normalized["routing_correlation"] || %{}
    source_identity = normalized["source_identity"] || %{}

    %{
      id: Ecto.UUID.dump!(normalized["event_identity"]),
      time: normalized["event_time"],
      event_type: normalized["event_type"] || "unknown",
      severity_id: normalized["severity_id"],
      router_id: merged_identity(correlation, source_identity, "router_id"),
      router_ip: merged_identity(correlation, source_identity, "router_ip"),
      peer_ip: merged_identity(correlation, source_identity, "peer_ip"),
      peer_asn: correlation["peer_asn"],
      local_asn: correlation["local_asn"],
      prefix: correlation["prefix"],
      message: routing_message(payload, normalized),
      metadata: normalized,
      raw_data: normalize_raw_data(raw_data),
      created_at: DateTime.utc_now()
    }
  end

  defp build_routing_event_row(_), do: nil

  defp merged_identity(correlation, source_identity, key) do
    correlation[key] || source_identity[key]
  end

  defp routing_message(payload, normalized) do
    payload["message"] || payload["description"] ||
      "#{normalized["signal_type"] || "bmp"} routing signal"
  end

  defp normalize_payload(payload, metadata, raw_data) when is_map(payload) do
    subject = metadata[:subject] || ""

    if arancini_subject?(subject) and not valid_arancini_payload?(payload) do
      {:error, :invalid_arancini_payload}
    else
      signal_type = infer_signal_type(subject, payload)
      event_type = infer_event_type(subject, payload)
      severity_id = normalize_severity(payload)
      grouped_contexts = grouped_contexts(payload)
      routing_correlation = routing_correlation(payload)
      domains = signal_domains(payload, signal_type)
      {primary_domain, precedence_rank} = primary_domain(domains)
      truncated_contexts = Enum.take(grouped_contexts, @max_grouped_contexts)
      contexts_truncated = length(grouped_contexts) > length(truncated_contexts)

      event_time =
        payload["timestamp"] ||
          payload["time"] ||
          payload["event_time"] ||
          payload["time_bmp_header_ns"] ||
          payload["time_received_ns"] ||
          metadata[:received_at]

      envelope = %{
        "schema_version" => @schema_version,
        "signal_type" => signal_type,
        "event_type" => event_type,
        "severity_id" => severity_id,
        "source" => normalize_source(payload, subject),
        "source_identity" => source_identity(payload),
        "event_identity" => stable_event_identity(subject, payload, raw_data),
        "event_time" => normalize_time(event_time),
        "routing_correlation" => routing_correlation,
        "grouped_contexts" => truncated_contexts,
        "signal_domains" => domains,
        "primary_domain" => primary_domain,
        "explainability" => %{
          "source_signal_refs" => source_signal_refs(payload),
          "context_ids" => Enum.map(truncated_contexts, & &1["id"]),
          "routing_topology_keys" => routing_correlation["topology_keys"],
          "primary_domain" => primary_domain,
          "precedence_rank" => precedence_rank
        },
        "guardrails" => %{
          "max_grouped_contexts" => @max_grouped_contexts,
          "contexts_truncated" => contexts_truncated,
          "input_context_count" => length(grouped_contexts),
          "applied_context_count" => length(truncated_contexts)
        }
      }

      {:ok, envelope}
    end
  end

  defp normalize_payload(_, _, _), do: {:error, :invalid_payload}

  defp arancini_subject?(subject) when is_binary(subject),
    do: subject == "arancini.updates" or String.starts_with?(subject, "arancini.updates.")

  defp arancini_subject?(_), do: false

  defp valid_arancini_payload?(payload) when is_map(payload) do
    required_string_keys_present? =
      Enum.all?(["router_addr", "peer_addr", "prefix_addr"], fn key ->
        payload[key] |> normalize_optional_string() |> is_binary()
      end)

    required_numeric_keys_present? =
      is_integer(normalize_int(payload["peer_asn"])) and
        is_integer(normalize_int(payload["prefix_len"]))

    required_boolean_keys_present? = is_boolean(payload["announced"])

    required_string_keys_present? and required_numeric_keys_present? and
      required_boolean_keys_present?
  end

  defp valid_arancini_payload?(_), do: false

  defp infer_event_type(subject, payload) when is_binary(subject) and is_map(payload) do
    candidate =
      payload["event_type"] ||
        payload["eventType"] ||
        arancini_event_type(payload) ||
        subject_to_event_type(subject)

    normalize_event_type(candidate)
  end

  defp infer_event_type(subject, _payload) when is_binary(subject) do
    subject_to_event_type(subject)
  end

  defp infer_event_type(_, _), do: "unknown"

  defp subject_to_event_type(subject) do
    case String.split(subject, ".", trim: true) do
      ["bmp", "events", suffix | _] -> normalize_event_type(suffix)
      _ -> "unknown"
    end
  end

  defp arancini_event_type(payload) when is_map(payload) do
    cond do
      is_boolean(payload["announced"]) and payload["announced"] ->
        "route_update"

      is_boolean(payload["announced"]) and not payload["announced"] ->
        "route_withdraw"

      true ->
        nil
    end
  end

  defp arancini_event_type(_), do: nil

  defp normalize_event_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp normalize_event_type(_), do: "unknown"

  defp build_ocsf_event_row(normalized, payload, raw_data, metadata) do
    severity_id = normalized["severity_id"]
    signal_type = normalized["signal_type"]
    event_identity = normalized["event_identity"]

    %{
      id: Ecto.UUID.dump!(event_identity),
      time: normalized["event_time"],
      class_uid: 1008,
      category_uid: 1,
      type_uid: type_uid_for(signal_type),
      activity_id: 1,
      activity_name: "Causal Signal",
      severity_id: severity_id,
      severity: severity_name(severity_id),
      message: payload["message"] || payload["description"] || "#{signal_type} causal signal",
      status_id: nil,
      status: nil,
      status_code: nil,
      status_detail: nil,
      metadata: normalized,
      observables: [],
      trace_id: nil,
      span_id: nil,
      actor: %{},
      device: normalize_device(payload),
      src_endpoint: normalize_src_endpoint(payload),
      dst_endpoint: %{},
      log_name: metadata[:subject],
      log_provider: payload["provider"] || payload["source"] || "external",
      log_level: payload["level"],
      log_version: payload["version"] || @schema_version,
      unmapped: payload,
      raw_data: normalize_raw_data(raw_data),
      created_at: DateTime.utc_now()
    }
  end

  defp infer_signal_type(subject, payload) do
    cond do
      is_binary(payload["signal_type"]) -> String.downcase(payload["signal_type"])
      String.starts_with?(subject, "bmp.events.") -> "bmp"
      arancini_subject?(subject) -> "bmp"
      String.starts_with?(subject, "siem.events.") -> "siem"
      true -> "unknown"
    end
  end

  defp normalize_source(payload, subject) do
    %{
      "subject" => subject,
      "collector" => payload["collector"] || payload["source_collector"],
      "system" =>
        payload["source"] ||
          payload["provider"] ||
          if(arancini_subject?(subject), do: "arancini", else: "external")
    }
  end

  defp source_identity(payload) do
    %{
      "device_uid" =>
        first_non_blank([
          payload["device_id"],
          payload["deviceId"],
          payload["router_id"],
          payload["routerId"]
        ]),
      "router_id" => first_non_blank([payload["router_id"], payload["routerId"]]),
      "router_ip" =>
        first_non_blank([
          payload["router_ip"],
          payload["routerIp"],
          payload["router_addr"],
          payload["device_ip"],
          payload["source_ip"]
        ]),
      "peer_ip" =>
        first_non_blank([
          payload["peer_ip"],
          payload["peerIp"],
          payload["peer_addr"],
          payload["src_ip"]
        ])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp routing_correlation(payload) do
    router_id =
      first_non_blank([
        payload["router_id"],
        payload["routerId"],
        payload["router_addr"],
        payload["device_id"],
        payload["deviceId"]
      ])

    router_ip =
      first_non_blank([
        payload["router_ip"],
        payload["routerIp"],
        payload["router_addr"],
        payload["device_ip"],
        payload["source_ip"]
      ])

    peer_ip =
      first_non_blank([
        payload["peer_ip"],
        payload["peerIp"],
        payload["peer_addr"],
        payload["src_ip"]
      ])

    peer_asn = normalize_int(payload["peer_asn"] || payload["peerAsn"])

    local_asn =
      normalize_int(
        payload["local_asn"] || payload["localAsn"] || payload["local_as"] || payload["asn"]
      )

    vrf = first_non_blank([payload["vrf"], payload["routing_instance"]])

    prefix =
      first_non_blank([
        payload["prefix"],
        payload["nlri"],
        payload["announced_prefix"],
        arancini_prefix(payload)
      ])

    topology_keys =
      [router_id, router_ip, peer_ip, prefix]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      "router_id" => router_id,
      "router_ip" => router_ip,
      "peer_ip" => peer_ip,
      "peer_asn" => peer_asn,
      "local_asn" => local_asn,
      "vrf" => vrf,
      "prefix" => prefix,
      "topology_keys" => topology_keys
    }
  end

  defp grouped_contexts(payload) when is_map(payload) do
    security_zones =
      payload
      |> list_or_scalar(["security_zones", "security_zone"])
      |> Enum.map(&build_context("security_zone", &1))

    bgp_prefix_groups =
      payload
      |> list_or_scalar(["bgp_prefix_groups", "bgp_prefix_group"])
      |> Enum.map(&build_context("bgp_prefix_group", &1))

    (security_zones ++ bgp_prefix_groups)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1["type"], &1["id"]})
  end

  defp grouped_contexts(_), do: []

  defp list_or_scalar(payload, [list_key, scalar_key]) do
    cond do
      is_list(payload[list_key]) ->
        payload[list_key]

      is_binary(payload[scalar_key]) ->
        [payload[scalar_key]]

      true ->
        []
    end
  end

  defp build_context(type, id) when is_binary(id) do
    normalized = String.trim(id)
    if normalized == "", do: nil, else: %{"type" => type, "id" => normalized}
  end

  defp build_context(_type, _id), do: nil

  defp signal_domains(payload, signal_type) do
    case_result =
      case payload["signal_domains"] do
        values when is_list(values) ->
          Enum.map(values, &normalize_domain/1)

        _ ->
          [normalize_domain(payload["signal_domain"] || signal_type)]
      end

    normalized =
      case_result
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if normalized == [], do: ["unknown"], else: normalized
  end

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "security" -> "security"
      "routing" -> "routing"
      "health" -> "health"
      "bmp" -> "routing"
      "siem" -> "security"
      "unknown" -> "unknown"
      "" -> nil
      _ -> "unknown"
    end
  end

  defp normalize_domain(_), do: nil

  defp primary_domain(domains) when is_list(domains) do
    domains
    |> Enum.map(&{&1, domain_rank(&1)})
    |> Enum.max_by(fn {domain, rank} -> {rank, domain} end, fn -> {"unknown", 0} end)
  end

  defp primary_domain(_), do: {"unknown", 0}

  defp domain_rank("security"), do: 3
  defp domain_rank("routing"), do: 2
  defp domain_rank("health"), do: 1
  defp domain_rank(_), do: 0

  defp source_signal_refs(payload) when is_map(payload) do
    [
      payload["event_id"],
      payload["id"],
      payload["eventId"],
      payload["alert_id"],
      payload["arancini_message_id"],
      payload["bmp_message_id"],
      payload["message_id"]
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp source_signal_refs(_), do: []

  defp normalize_time(%DateTime{} = dt), do: dt

  defp normalize_time(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp normalize_severity(payload) do
    cond do
      is_integer(payload["severity_id"]) -> clamp_severity(payload["severity_id"])
      is_integer(payload["severity"]) -> clamp_severity(payload["severity"])
      is_binary(payload["severity"]) -> severity_from_string(payload["severity"])
      true -> 3
    end
  end

  defp clamp_severity(value) when value < 0, do: 0
  defp clamp_severity(value) when value > 6, do: 6
  defp clamp_severity(value), do: value

  @severity_map %{
    "unknown" => 0,
    "informational" => 1,
    "info" => 1,
    "low" => 2,
    "medium" => 3,
    "high" => 4,
    "critical" => 5,
    "fatal" => 6
  }

  defp severity_from_string(value) do
    Map.get(@severity_map, String.downcase(value), 3)
  end

  defp severity_name(0), do: "Unknown"
  defp severity_name(1), do: "Informational"
  defp severity_name(2), do: "Low"
  defp severity_name(3), do: "Medium"
  defp severity_name(4), do: "High"
  defp severity_name(5), do: "Critical"
  defp severity_name(6), do: "Fatal"
  defp severity_name(_), do: "Unknown"

  defp type_uid_for("bmp"), do: 100_811
  defp type_uid_for("siem"), do: 100_812
  defp type_uid_for(_), do: 100_810

  defp normalize_device(payload) do
    device_id =
      payload["device_id"] || payload["deviceId"] || payload["router_id"] ||
        payload["router_addr"]

    if is_binary(device_id) and device_id != "" do
      %{"uid" => device_id}
    else
      %{}
    end
  end

  defp normalize_src_endpoint(payload) do
    ip = payload["peer_ip"] || payload["peer_addr"] || payload["src_ip"] || payload["source_ip"]
    asn = normalize_int(payload["peer_asn"] || payload["peerAsn"])

    %{"ip" => normalize_optional_string(ip), "asn" => asn}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stable_event_identity(subject, payload, raw_data) do
    source_id =
      payload["event_id"] ||
        payload["id"] ||
        payload["eventId"] ||
        payload["alert_id"] ||
        payload["arancini_message_id"] ||
        payload["bmp_message_id"] ||
        payload["message_id"]

    stable_key =
      if is_binary(source_id) and source_id != "" do
        "#{subject}:#{source_id}"
      else
        hash = Base.encode16(:crypto.hash(:sha256, raw_data), case: :lower)
        "#{subject}:#{hash}"
      end

    deterministic_uuid(stable_key)
  end

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    # Set version 4 and variant 10xx for UUID compliance.
    versioned_a3 = a3 |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x4000)
    versioned_a4 = a4 |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
    |> IO.iodata_to_binary()
  end

  defp first_non_blank(values) when is_list(values) do
    values
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.find(&is_binary/1)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(value) when is_float(value), do: Float.to_string(value)
  defp normalize_optional_string(_), do: nil

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp arancini_prefix(payload) when is_map(payload) do
    with prefix_addr when is_binary(prefix_addr) <-
           normalize_optional_string(payload["prefix_addr"]),
         prefix_len when is_integer(prefix_len) <- normalize_int(payload["prefix_len"]) do
      "#{prefix_addr}/#{prefix_len}"
    else
      _ -> nil
    end
  end

  defp arancini_prefix(_), do: nil

  defp normalize_raw_data(data) when is_binary(data) do
    if String.valid?(data) do
      data
    else
      Base.encode64(data)
    end
  end

  defp normalize_raw_data(data), do: inspect(data)
end
