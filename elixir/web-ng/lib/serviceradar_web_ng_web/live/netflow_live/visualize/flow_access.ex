defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_int: 1]

  def flow_get(nil, _keys), do: nil

  # SRQL results are typically JSON maps with string keys, but some code paths can hand us
  # atom-keyed maps (e.g. if decoded/normalized elsewhere). Avoid `String.to_atom/1` here
  # (atom leak); instead, use a fixed allowlist of atoms that exist at compile time.
  @flow_key_atoms [
    :time,
    :timestamp,
    :src_endpoint_ip,
    :dst_endpoint_ip,
    :src_ip,
    :dst_ip,
    :src_endpoint_port,
    :dst_endpoint_port,
    :src_port,
    :dst_port,
    :protocol_name,
    :protocol_group,
    :proto,
    :protocol_num,
    :protocol_source,
    :tcp_flags,
    :tcp_flags_labels,
    :tcp_flags_source,
    :dst_service_label,
    :dst_service_source,
    :packets_total,
    :packets,
    :bytes_total,
    :bytes,
    :bytes_in,
    :bytes_out,
    :direction_label,
    :direction_source,
    :src_hosting_provider,
    :src_hosting_provider_source,
    :dst_hosting_provider,
    :dst_hosting_provider_source,
    :src_prefix_tags,
    :dst_prefix_tags,
    :src_prefix_tags_source,
    :dst_prefix_tags_source,
    :src_mac,
    :dst_mac,
    :src_mac_vendor,
    :src_mac_vendor_source,
    :dst_mac_vendor,
    :dst_mac_vendor_source,
    :sampler_address,
    :src_country_iso2,
    :dst_country_iso2,
    :ocsf_payload,
    :ocsf
  ]

  @flow_key_atom_map Map.new(@flow_key_atoms, fn a -> {Atom.to_string(a), a} end)

  def flow_get(flow, keys) when is_map(flow) and is_list(keys) do
    keys
    |> Enum.find_value(fn k ->
      Map.get(flow, k) ||
        case Map.get(@flow_key_atom_map, k) do
          a when is_atom(a) -> Map.get(flow, a)
          _ -> nil
        end
    end)
    |> case do
      v when is_binary(v) -> String.trim(v)
      v -> v
    end
  end

  def flow_get_in(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case flow_map_get(acc, key) do
        nil -> {:halt, nil}
        v -> {:cont, v}
      end
    end)
  end

  def flow_get_in(_map, _path), do: nil

  def enrich_flow_rows_with_attribution(rows) when is_list(rows) do
    Enum.map(rows, fn
      %{} = row -> Map.put(row, "attribution", flow_attribution(row))
      other -> other
    end)
  end

  def enrich_flow_rows_with_attribution(_rows), do: []

  def flow_attribution(%{} = flow) do
    existing = Map.get(flow, "attribution") || Map.get(flow, :attribution)

    case existing do
      %{attributed?: _} = normalized ->
        normalized

      _ ->
        ocsf = flow_get(flow, ["ocsf_payload", "ocsf"]) || %{}
        raw = flow_get_in(ocsf, ["attribution"]) || %{}
        agent_id = clean_text(flow_get_in(ocsf, ["agent_id"]) || flow_get(flow, ["agent_id"]))
        pid = clean_text(flow_get_in(raw, ["pid"]))
        comm = clean_text(flow_get_in(raw, ["comm"]))
        cmdline = clean_text(flow_get_in(raw, ["redacted_cmdline"]) || flow_get_in(raw, ["cmdline"]))
        uid = clean_text(flow_get_in(raw, ["uid"]))
        container_id = clean_text(flow_get_in(raw, ["container_id"]))
        attributed? = attributed_event?(ocsf) and (present_text?(pid) or present_text?(comm))

        %{
          attributed?: attributed?,
          agent_id: agent_id,
          pid: pid,
          comm: comm,
          cmdline: cmdline,
          uid: uid,
          container_id: container_id,
          process_label: process_attribution_label(comm, pid)
        }
    end
  end

  def flow_attribution(_flow), do: %{attributed?: false, process_label: "—"}

  def attributed_event?(%{} = ocsf) do
    flow_get_in(ocsf, ["event_type"]) == "attributed_flow" or is_map(flow_get_in(ocsf, ["attribution"]))
  end

  def attributed_event?(_), do: false

  def process_attribution_label(comm, pid) do
    cond do
      present_text?(comm) and present_text?(pid) -> "#{comm} ##{pid}"
      present_text?(comm) -> comm
      present_text?(pid) -> "PID #{pid}"
      true -> "—"
    end
  end

  def clean_text(nil), do: nil

  def clean_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def clean_text(value), do: value |> to_string() |> clean_text()

  def present_text?(value), do: is_binary(value) and String.trim(value) != ""

  def display_value(nil), do: "—"
  def display_value(""), do: "—"
  def display_value(value), do: value

  def flow_map_get(%{} = acc, key) when is_atom(key) do
    Map.get(acc, key) || Map.get(acc, Atom.to_string(key))
  end

  def flow_map_get(%{} = acc, key) when is_binary(key) do
    Map.get(acc, key) ||
      case Map.get(@flow_key_atom_map, key) do
        a when is_atom(a) -> Map.get(acc, a)
        _ -> nil
      end
  end

  def flow_map_get(%{} = acc, key), do: Map.get(acc, key)
  def flow_map_get(_acc, _key), do: nil

  def flow_app_label(flow) when is_map(flow) do
    # Prefer persisted enrichment labels first.
    flow_get(flow, ["dst_service_label", "app", "app_label"]) ||
      case to_int(flow_get(flow, ["dst_endpoint_port", "dst_port"])) do
        53 -> "dns"
        80 -> "http"
        443 -> "https"
        22 -> "ssh"
        123 -> "ntp"
        _ -> "unknown"
      end
  rescue
    _ -> "unknown"
  end

  def flow_app_label(_), do: "unknown"
end
