defmodule ServiceRadarWebNGWeb.Settings.NetperfLive.Forms do
  @moduledoc """
  Pure form parameter builders, selector parsers, error formatters, and
  `ControlStream` command status reducers for `Settings.NetperfLive.Index`.
  """

  @default_profile_params %{
    "name" => "",
    "description" => "",
    "protocol" => "tcp",
    "direction" => "upload",
    "bandwidth_bps" => "50000000",
    "duration_sec" => "5",
    "omit_sec" => "1",
    "parallel" => "1",
    "packet_length" => "1200",
    "interval_seconds" => "900"
  }

  @default_responder_params %{
    "agent_uid" => "",
    "name" => "",
    "enabled" => "true",
    "advertise_address" => "",
    "listen_port" => "5199",
    "udp_enabled" => "true",
    "max_concurrent_sessions" => "4",
    "max_total_bandwidth_bps" => "1000000000"
  }

  @default_policy_params %{
    "name" => "",
    "description" => "",
    "enabled" => "true",
    "mode" => "hub_and_spoke",
    "profile_id" => "",
    "responder_ids" => [],
    "spoke_partition_id" => "",
    "spoke_tags_text" => "",
    "spoke_srql_query" => "",
    "spoke_agent_uids_text" => ""
  }

  @default_run_params %{
    "sender_agent_id" => "",
    "responder_agent_id" => "",
    "target_address" => "",
    "target_port" => "5199",
    "profile_id" => "",
    "protocol" => "tcp",
    "direction" => "upload",
    "bandwidth_bps" => "50000000",
    "duration_sec" => "5",
    "omit_sec" => "1",
    "parallel" => "1",
    "packet_length" => "1200"
  }

  @spec default_profile_params() :: map()
  def default_profile_params, do: @default_profile_params

  @spec default_responder_params() :: map()
  def default_responder_params, do: @default_responder_params

  @spec default_policy_params([map()]) :: map()
  def default_policy_params(profiles \\ []) do
    default_profile_id =
      case profiles do
        [first | _] -> to_string(first.id)
        _ -> ""
      end

    Map.put(@default_policy_params, "profile_id", default_profile_id)
  end

  @spec default_run_params() :: map()
  def default_run_params, do: @default_run_params

  @spec profile_to_form_params(map()) :: map()
  def profile_to_form_params(profile) do
    %{
      "name" => profile.name || "",
      "description" => profile.description || "",
      "protocol" => to_string(profile.protocol || :tcp),
      "direction" => to_string(profile.direction || :upload),
      "bandwidth_bps" => to_string(profile.bandwidth_bps || 50_000_000),
      "duration_sec" => to_string(profile.duration_sec || 5),
      "omit_sec" => to_string(profile.omit_sec || 1),
      "parallel" => to_string(profile.parallel || 1),
      "packet_length" => to_string(profile.packet_length || 1200),
      "interval_seconds" => to_string(profile.interval_seconds || 900)
    }
  end

  @spec responder_to_form_params(map()) :: map()
  def responder_to_form_params(responder) do
    %{
      "agent_uid" => responder.agent_uid || "",
      "name" => responder.name || "",
      "enabled" => to_string(responder.enabled != false),
      "advertise_address" => responder.advertise_address || "",
      "listen_port" => to_string(responder.listen_port || 5199),
      "udp_enabled" => to_string(responder.udp_enabled != false),
      "max_concurrent_sessions" => to_string(responder.max_concurrent_sessions || 4),
      "max_total_bandwidth_bps" => to_string(responder.max_total_bandwidth_bps || 1_000_000_000)
    }
  end

  @spec policy_to_form_params(map()) :: map()
  def policy_to_form_params(policy) do
    selector = policy.spoke_selector || %{}
    responder_ids = policy |> Map.get(:responders, []) |> Enum.map(&to_string(&1.id))

    %{
      "name" => policy.name || "",
      "description" => policy.description || "",
      "enabled" => to_string(policy.enabled != false),
      "mode" => to_string(policy.mode || :hub_and_spoke),
      "profile_id" => to_string(policy.profile_id || ""),
      "responder_ids" => responder_ids,
      "spoke_partition_id" => selector_string(selector, "partition_id"),
      "spoke_tags_text" => format_spoke_tags(selector_value(selector, "tags")),
      "spoke_srql_query" => selector_string(selector, "srql_query"),
      "spoke_agent_uids_text" => format_agent_uids(selector_value(selector, "agent_uids"))
    }
  end

  @spec build_profile_attrs(map()) :: map()
  def build_profile_attrs(params) when is_map(params) do
    %{
      name: trim_string(Map.get(params, "name")),
      description: blank_to_nil(Map.get(params, "description")),
      protocol: parse_protocol(Map.get(params, "protocol")),
      direction: parse_direction(Map.get(params, "direction")),
      bandwidth_bps: parse_int(Map.get(params, "bandwidth_bps"), 50_000_000),
      duration_sec: parse_int(Map.get(params, "duration_sec"), 5),
      omit_sec: parse_int(Map.get(params, "omit_sec"), 1),
      parallel: parse_int(Map.get(params, "parallel"), 1),
      packet_length: parse_int(Map.get(params, "packet_length"), 1200),
      interval_seconds: parse_int(Map.get(params, "interval_seconds"), 900)
    }
  end

  @spec build_responder_attrs(map(), boolean()) :: map()
  def build_responder_attrs(params, include_agent_uid? \\ true) when is_map(params) do
    base = %{
      name: trim_string(Map.get(params, "name")),
      enabled: parse_bool(Map.get(params, "enabled"), true),
      advertise_address: blank_to_nil(Map.get(params, "advertise_address")),
      listen_port: parse_int(Map.get(params, "listen_port"), 5199),
      udp_enabled: parse_bool(Map.get(params, "udp_enabled"), true),
      max_concurrent_sessions: parse_int(Map.get(params, "max_concurrent_sessions"), 4),
      max_total_bandwidth_bps: parse_int(Map.get(params, "max_total_bandwidth_bps"), 1_000_000_000)
    }

    if include_agent_uid? do
      Map.put(base, :agent_uid, trim_string(Map.get(params, "agent_uid")))
    else
      base
    end
  end

  @spec build_policy_attrs(map()) :: {map(), [String.t()]}
  def build_policy_attrs(params) when is_map(params) do
    mode = parse_policy_mode(Map.get(params, "mode"))

    spoke_selector =
      if mode == :hub_and_spoke do
        build_spoke_selector(params)
      else
        %{}
      end

    responder_ids =
      params
      |> Map.get("responder_ids", [])
      |> List.wrap()
      |> Enum.map(&trim_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    attrs = %{
      name: trim_string(Map.get(params, "name")),
      description: blank_to_nil(Map.get(params, "description")),
      enabled: parse_bool(Map.get(params, "enabled"), true),
      mode: mode,
      profile_id: blank_to_nil(Map.get(params, "profile_id")),
      spoke_selector: spoke_selector
    }

    {attrs, responder_ids}
  end

  @spec build_spoke_selector(map()) :: map()
  def build_spoke_selector(params) when is_map(params) do
    %{}
    |> maybe_put_nonempty("partition_id", blank_to_nil(Map.get(params, "spoke_partition_id")))
    |> maybe_put_nonempty("tags", parse_spoke_tags(Map.get(params, "spoke_tags_text")))
    |> maybe_put_nonempty("srql_query", blank_to_nil(Map.get(params, "spoke_srql_query")))
    |> maybe_put_nonempty("agent_uids", parse_agent_uids(Map.get(params, "spoke_agent_uids_text")))
  end

  @spec parse_spoke_tags(String.t() | nil) :: map() | nil
  def parse_spoke_tags(nil), do: nil

  def parse_spoke_tags(text) when is_binary(text) do
    tags =
      text
      |> String.split(~r/[,\n]+/, trim: true)
      |> Enum.reduce(%{}, fn entry, acc ->
        case String.split(entry, "=", parts: 2) do
          [k, v] ->
            key = String.trim(k)
            val = String.trim(v)
            if key != "" and val != "", do: Map.put(acc, key, val), else: acc

          _ ->
            acc
        end
      end)

    if map_size(tags) == 0, do: nil, else: tags
  end

  def parse_spoke_tags(_), do: nil

  @spec format_spoke_tags(map() | nil) :: String.t()
  def format_spoke_tags(tags) when is_map(tags) do
    tags
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
  end

  def format_spoke_tags(_), do: ""

  @spec parse_agent_uids(String.t() | [String.t()] | nil) :: [String.t()] | nil
  def parse_agent_uids(nil), do: nil

  def parse_agent_uids(uids) when is_list(uids) do
    cleaned =
      uids
      |> Enum.map(&trim_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if cleaned == [], do: nil, else: cleaned
  end

  def parse_agent_uids(text) when is_binary(text) do
    text
    |> String.split(~r/[,\s]+/, trim: true)
    |> parse_agent_uids()
  end

  def parse_agent_uids(_), do: nil

  @spec format_agent_uids([String.t()] | nil) :: String.t()
  def format_agent_uids(uids) when is_list(uids) do
    Enum.map_join(uids, ", ", &to_string/1)
  end

  def format_agent_uids(_), do: ""

  @spec summarize_spoke_selector(map() | nil) :: String.t()
  def summarize_spoke_selector(selector) when not is_map(selector) or map_size(selector) == 0 do
    "All eligible agents"
  end

  def summarize_spoke_selector(selector) do
    parts =
      []
      |> append_summary_part("partition", selector_string(selector, "partition_id"))
      |> append_tags_summary(selector_value(selector, "tags"))
      |> append_summary_part("srql", selector_string(selector, "srql_query"))
      |> append_uids_summary(selector_value(selector, "agent_uids"))

    if parts == [], do: "All eligible agents", else: Enum.join(parts, " · ")
  end

  @spec apply_run_presets(map(), [map()], [map()], (map() -> String.t() | nil)) :: map()
  def apply_run_presets(params, responders, profiles, address_resolver)
      when is_map(params) and is_list(responders) and is_list(profiles) do
    params
    |> maybe_apply_responder_preset(responders, address_resolver)
    |> maybe_apply_profile_preset(profiles)
  end

  defp maybe_apply_responder_preset(params, responders, address_resolver) do
    responder_uid = trim_string(Map.get(params, "responder_agent_id"))

    case Enum.find(responders, &(&1.agent_uid == responder_uid)) do
      nil ->
        params

      responder ->
        resolved_address = address_resolver.(responder) || ""

        params
        |> maybe_fill_blank("target_address", resolved_address)
        |> maybe_fill_blank("target_port", to_string(responder.listen_port || 5199))
    end
  end

  defp maybe_apply_profile_preset(params, profiles) do
    profile_id = trim_string(Map.get(params, "profile_id"))

    case Enum.find(profiles, &(to_string(&1.id) == profile_id)) do
      nil ->
        params

      profile ->
        params
        |> Map.put("protocol", to_string(profile.protocol))
        |> Map.put("direction", to_string(profile.direction))
        |> Map.put("bandwidth_bps", to_string(profile.bandwidth_bps))
        |> Map.put("duration_sec", to_string(profile.duration_sec))
        |> Map.put("omit_sec", to_string(profile.omit_sec))
        |> Map.put("parallel", to_string(profile.parallel))
        |> Map.put("packet_length", to_string(profile.packet_length))
    end
  end

  @spec build_run_params(map()) :: map()
  def build_run_params(params) when is_map(params) do
    %{
      responder_agent_id: trim_string(Map.get(params, "responder_agent_id")),
      target_address: trim_string(Map.get(params, "target_address")),
      target_port: parse_int(Map.get(params, "target_port"), 5199),
      protocol: trim_string(Map.get(params, "protocol", "tcp")),
      direction: trim_string(Map.get(params, "direction", "upload")),
      bandwidth_bps: parse_int(Map.get(params, "bandwidth_bps"), 50_000_000),
      duration_sec: parse_int(Map.get(params, "duration_sec"), 5),
      omit_sec: parse_int(Map.get(params, "omit_sec"), 1),
      parallel: parse_int(Map.get(params, "parallel"), 1),
      packet_length: parse_int(Map.get(params, "packet_length"), 1200)
    }
  end

  @spec format_bps(integer() | float() | nil) :: String.t()
  def format_bps(nil), do: "—"

  def format_bps(bps) when is_number(bps) do
    cond do
      bps >= 1_000_000_000 -> "#{format_decimal(bps / 1_000_000_000)} Gbps"
      bps >= 1_000_000 -> "#{format_decimal(bps / 1_000_000)} Mbps"
      bps >= 1_000 -> "#{format_decimal(bps / 1_000)} Kbps"
      true -> "#{trunc(bps)} bps"
    end
  end

  def format_bps(_), do: "—"

  defp format_decimal(value) when is_float(value) do
    rounded = Float.round(value, 2)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: "#{rounded}"
  end

  @spec format_dispatch_error(term()) :: String.t()
  def format_dispatch_error(:netperf_run_unauthorized),
    do: "You do not have permission to dispatch on-demand network performance tests."

  def format_dispatch_error(:invalid_sender_agent_id), do: "Select a valid Spoke Sender agent."

  def format_dispatch_error(:responder_agent_id_required), do: "Select a Hub Responder agent."

  def format_dispatch_error(:netperf_self_target_forbidden),
    do: "Sender agent and Hub Responder agent cannot be the same agent."

  def format_dispatch_error(:target_address_required),
    do: "Target address is required (set an advertise address on the Hub Responder or enter one manually)."

  def format_dispatch_error(:netperf_responder_disabled), do: "The selected Hub Responder is currently disabled."

  def format_dispatch_error(:invalid_authority_epoch),
    do: "Invalid authority epoch override (must be a positive 64-bit integer)."

  def format_dispatch_error(:invalid_netperf_protocol), do: "Protocol must be tcp or udp."

  def format_dispatch_error(:invalid_netperf_direction), do: "Direction must be upload, download, or bidirectional."

  def format_dispatch_error({:agent_offline, agent_id}),
    do: "Sender agent #{agent_id} is offline (no active ControlStream session)."

  def format_dispatch_error({:agent_capability_missing, agent_id, capability}),
    do: "Sender agent #{agent_id} does not advertise the '#{capability}' capability."

  def format_dispatch_error({:agent_busy, :netperf_run_running}),
    do: "Sender agent already has an active netperf.run execution in progress."

  def format_dispatch_error(:registry_unavailable), do: "Agent registry is currently unavailable."

  def format_dispatch_error(:control_session_unavailable),
    do: "ControlStream session is unavailable for the selected sender agent."

  def format_dispatch_error(%Ash.Error.Invalid{} = err), do: Exception.message(err)
  def format_dispatch_error(%Ash.Error.Forbidden{} = err), do: Exception.message(err)
  def format_dispatch_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")
  def format_dispatch_error(reason), do: inspect(reason)

  @doc """
  Reduces `{:command_ack, data}`, `{:command_progress, data}`, or
  `{:command_result, data}` into the `:active_run` assign when it matches the
  currently tracked command.
  """
  @spec reduce_command_event(map() | nil, {:command_ack | :command_progress | :command_result, map()}) ::
          map() | nil
  def reduce_command_event(nil, _event), do: nil

  def reduce_command_event(%{command_id: active_id} = active_run, {kind, data}) when is_map(data) do
    event_id = Map.get(data, :command_id) || Map.get(data, "command_id")

    if event_id == active_id do
      apply_command_event(active_run, kind, data)
    else
      active_run
    end
  end

  def reduce_command_event(active_run, _event), do: active_run

  defp apply_command_event(active_run, :command_ack, data) do
    %{
      active_run
      | state: :acknowledged,
        message: Map.get(data, :message) || "Acknowledged by sender agent"
    }
  end

  defp apply_command_event(active_run, :command_progress, data) do
    percent = Map.get(data, :progress_percent)
    msg = Map.get(data, :message) || "Running network performance test"

    message =
      if is_integer(percent), do: "#{msg} (#{percent}%)", else: msg

    %{
      active_run
      | state: :running,
        progress_percent: percent,
        message: message
    }
  end

  defp apply_command_event(active_run, :command_result, data) do
    success? = Map.get(data, :success) == true
    payload = Map.get(data, :payload) || %{}
    error_text = Map.get(payload, "error") || Map.get(data, :message)

    %{
      active_run
      | state: if(success?, do: :completed, else: :failed),
        message:
          if(success?,
            do: Map.get(data, :message) || "Test completed",
            else: error_text || "Test failed"
          ),
        result_payload: payload
    }
  end

  defp parse_protocol("udp"), do: :udp
  defp parse_protocol(:udp), do: :udp
  defp parse_protocol(_), do: :tcp

  defp parse_direction("download"), do: :download
  defp parse_direction(:download), do: :download
  defp parse_direction("bidirectional"), do: :bidirectional
  defp parse_direction(:bidirectional), do: :bidirectional
  defp parse_direction(_), do: :upload

  defp parse_policy_mode("hub_mesh"), do: :hub_mesh
  defp parse_policy_mode(:hub_mesh), do: :hub_mesh
  defp parse_policy_mode(_), do: :hub_and_spoke

  defp parse_bool(true, _default), do: true
  defp parse_bool(false, _default), do: false

  defp parse_bool(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      v when v in ~w(true 1 yes on) -> true
      v when v in ~w(false 0 no off) -> false
      _ -> default
    end
  end

  defp parse_bool(_, default), do: default

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(_), do: ""

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp maybe_put_nonempty(map, _key, nil), do: map
  defp maybe_put_nonempty(map, _key, ""), do: map
  defp maybe_put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp maybe_fill_blank(params, key, value) when is_binary(value) and value != "" do
    Map.put(params, key, value)
  end

  defp maybe_fill_blank(params, _key, _value), do: params

  defp selector_value(selector, key) when is_map(selector) do
    Map.get(selector, key) || Enum.find_value(selector, fn {k, v} -> if to_string(k) == key, do: v end)
  end

  defp selector_string(selector, key) do
    case selector_value(selector, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp append_summary_part(parts, _label, ""), do: parts
  defp append_summary_part(parts, label, value), do: parts ++ ["#{label}: #{value}"]

  defp append_tags_summary(parts, tags) when is_map(tags) and map_size(tags) > 0 do
    parts ++ ["tags: #{format_spoke_tags(tags)}"]
  end

  defp append_tags_summary(parts, _), do: parts

  defp append_uids_summary(parts, uids) when is_list(uids) and uids != [] do
    parts ++ ["agents: #{length(uids)}"]
  end

  defp append_uids_summary(parts, _), do: parts
end
