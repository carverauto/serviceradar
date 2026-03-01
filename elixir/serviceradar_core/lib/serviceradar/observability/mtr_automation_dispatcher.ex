defmodule ServiceRadar.Observability.MtrAutomationDispatcher do
  @moduledoc """
  Shared dispatch orchestration for automated MTR baseline and incident runs.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.{MtrDispatchWindow, MtrVantageSelector, SRQLRunner}
  alias ServiceRadar.ProcessRegistry

  require Ash.Query
  require Logger

  @default_target_limit 100

  @type target_ctx :: %{
          optional(:target) => String.t(),
          optional(:target_ip) => String.t(),
          optional(:target_device_uid) => String.t(),
          optional(:partition_id) => String.t(),
          optional(:gateway_id) => String.t(),
          optional(:target_key) => String.t()
        }

  @spec baseline_targets(map()) :: [target_ctx()]
  def baseline_targets(policy) when is_map(policy) do
    actor = SystemActor.system(:mtr_automation)
    selector = Map.get(policy, :target_selector, %{}) || %{}
    limit = selector_int(selector, "limit", @default_target_limit)
    ips = selector_list(selector, "ips")
    device_uids = selector_list(selector, "device_uids")
    srql_query = selector_string(selector, "srql_query")

    if is_binary(srql_query) and srql_query != "" do
      baseline_targets_from_srql(srql_query, limit)
    else
      query =
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: false})
        |> Ash.Query.filter(expr(is_managed == true and not is_nil(ip)))
        |> maybe_filter_uids(device_uids)
        |> maybe_filter_ips(ips)
        |> Ash.Query.limit(limit)

      case Ash.read(query, actor: actor) do
        {:ok, %Ash.Page.Keyset{results: results}} ->
          Enum.map(results, &device_to_target_ctx/1)

        {:ok, results} when is_list(results) ->
          Enum.map(results, &device_to_target_ctx/1)

        {:error, reason} ->
          Logger.warning("MTR baseline target query failed", reason: inspect(reason))
          []
      end
    end
  end

  defp baseline_targets_from_srql(srql_query, limit) do
    query = normalize_srql_target_query(srql_query, limit)

    case SRQLRunner.query(query, limit: limit) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.map(&row_to_target_ctx/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("MTR baseline SRQL query failed",
          query: srql_query,
          reason: inspect(reason)
        )

        []
    end
  end

  @spec dispatch_for_mode(
          target_ctx(),
          map(),
          :baseline | :incident | :recovery,
          String.t() | nil,
          keyword()
        ) ::
          {:ok, [String.t()]} | {:error, term()}
  def dispatch_for_mode(target_ctx, policy, mode, incident_correlation_id \\ nil, opts \\ [])
      when mode in [:baseline, :incident, :recovery] do
    transition_class = Keyword.get(opts, :transition_class, transition_class(mode))

    with {:ok, target_ctx} <- normalize_target_ctx(target_ctx),
         true <- target_matches_policy_scope?(target_ctx, policy),
         {:ok, selected_agents} <- select_agents(target_ctx, policy, mode),
         false <- cooldown_active?(target_ctx, mode, transition_class),
         {:ok, _} <-
           dispatch_to_agents(
             selected_agents,
             target_ctx,
             policy,
             mode,
             incident_correlation_id,
             transition_class
           ) do
      {:ok, selected_agents}
    else
      true ->
        {:error, :cooldown_active}

      {:error, _} = error ->
        error

      other ->
        {:error, other}
    end
  end

  @spec classify_transition(atom() | nil, atom() | nil) ::
          {:incident, String.t()} | {:recovery, String.t()} | :ignore
  def classify_transition(old_state, new_state) do
    degraded_states = [:degraded, :unhealthy]
    unavailable_states = [:unavailable, :offline, :down]
    baseline_states = [:healthy, :available]

    cond do
      old_state in baseline_states and new_state in degraded_states ->
        {:incident, "degraded"}

      old_state in baseline_states and new_state in unavailable_states ->
        {:incident, "unavailable"}

      old_state in (degraded_states ++ unavailable_states) and new_state in baseline_states ->
        {:recovery, "recovery"}

      true ->
        :ignore
    end
  end

  @spec target_ctx_from_health_event(struct() | map()) :: {:ok, target_ctx()} | {:error, term()}
  def target_ctx_from_health_event(event) do
    metadata = event_metadata(event)
    entity_id = Map.get(event, :entity_id)
    entity_type = Map.get(event, :entity_type)
    target_ip = health_event_target_ip(metadata, entity_id)
    target_device_uid = health_event_target_device_uid(metadata)

    normalize_target_ctx(%{
      target: metadata_value(metadata, "target") || target_ip,
      target_ip: target_ip,
      target_device_uid: target_device_uid,
      partition_id: health_event_partition_id(metadata),
      gateway_id: metadata_value(metadata, "gateway_id"),
      target_key: target_key(target_device_uid, target_ip, entity_type, entity_id)
    })
  end

  defp select_agents(target_ctx, policy, :baseline) do
    candidates = candidate_agents(target_ctx)

    with {:ok, preferred} <- select_preferred_agents(policy, candidates) do
      if preferred == [] do
        MtrVantageSelector.select_baseline_vantages(target_ctx, policy, candidates)
      else
        {:ok, preferred}
      end
    end
  end

  defp select_agents(target_ctx, policy, mode) when mode in [:incident, :recovery] do
    candidates = candidate_agents(target_ctx)

    with {:ok, preferred} <- select_preferred_agents(policy, candidates) do
      if preferred == [] do
        MtrVantageSelector.select_incident_vantages(target_ctx, policy, candidates)
      else
        {:ok, preferred}
      end
    end
  end

  defp select_preferred_agents(policy, candidates) do
    selector = Map.get(policy, :target_selector, %{}) || %{}
    preferred = selector_list(selector, "agent_ids")
    preferred_single = selector_string(selector, "agent_id")

    preferred =
      if is_binary(preferred_single) and preferred_single != "" do
        Enum.uniq([preferred_single | preferred])
      else
        preferred
      end

    if preferred == [] do
      {:ok, []}
    else
      selected =
        candidates
        |> Enum.filter(fn candidate -> candidate.agent_id in preferred end)
        |> Enum.map(& &1.agent_id)
        |> Enum.uniq()

      if selected == [] do
        {:error, :preferred_agent_unavailable}
      else
        {:ok, selected}
      end
    end
  end

  defp dispatch_to_agents(
         [],
         _target_ctx,
         _policy,
         _mode,
         _incident_correlation_id,
         _transition_class
       ),
       do: {:error, :no_selected_agents}

  defp dispatch_to_agents(
         agent_ids,
         target_ctx,
         policy,
         mode,
         incident_correlation_id,
         transition_class
       ) do
    target = target_from_ctx(target_ctx)

    if is_binary(target) and target != "" do
      trigger_mode = trigger_mode(mode)
      partition_id = normalize_partition(Map.get(target_ctx, :partition_id))
      payload = %{"target" => target, "protocol" => normalize_protocol(Map.get(policy, :baseline_protocol))}
      context = dispatch_context(target_ctx, trigger_mode, incident_correlation_id)
      actor = SystemActor.system(:mtr_automation)
      now = DateTime.utc_now()

      dispatched =
        Enum.filter(agent_ids, fn agent_id ->
          dispatch_agent(
            agent_id,
            payload,
            context,
            partition_id,
            actor,
            trigger_mode
          )
        end)

      finalize_dispatch(
        dispatched,
        target_ctx,
        policy,
        mode,
        %{
          transition_class: transition_class,
          incident_correlation_id: incident_correlation_id,
          trigger_mode: trigger_mode,
          partition_id: partition_id,
          now: now
        }
      )
    else
      {:error, :missing_target}
    end
  end

  defp candidate_agents(target_ctx) do
    target_partition = normalize_partition(Map.get(target_ctx, :partition_id))

    ProcessRegistry.select_by_type(:agent_control)
    |> Enum.map(&session_to_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn candidate ->
      target_partition == "" or candidate.partition_id == target_partition
    end)
  end

  defp session_to_candidate({key, _pid, metadata}) do
    agent_id = agent_id_from_key(key)
    metadata = metadata || %{}

    if is_binary(agent_id) and agent_id != "" do
      %{
        agent_id: agent_id,
        partition_id: normalize_partition(metadata_value(metadata, "partition_id")),
        gateway_id: metadata_value(metadata, "gateway_id"),
        status: metadata_value(metadata, "status") || "connected",
        capabilities: List.wrap(metadata_value(metadata, "capabilities")),
        mtr_capable:
          metadata_value(metadata, "mtr_capable") ||
            "mtr" in Enum.map(List.wrap(metadata_value(metadata, "capabilities")), &to_string/1),
        in_flight: metadata_value(metadata, "in_flight") || 0,
        control_rtt_ms: metadata_value(metadata, "control_rtt_ms") || 0,
        last_success_at: metadata_value(metadata, "last_success_at")
      }
    else
      nil
    end
  end

  defp session_to_candidate(_), do: nil

  defp agent_id_from_key({:agent_control, agent_id}) when is_binary(agent_id), do: agent_id
  defp agent_id_from_key({:agent_control, agent_id, _node}) when is_binary(agent_id), do: agent_id
  defp agent_id_from_key(_), do: nil

  defp normalize_target_ctx(ctx) when is_map(ctx) do
    target = read_ctx_value(ctx, :target)
    target_ip = read_ctx_value(ctx, :target_ip)
    target_device_uid = read_ctx_value(ctx, :target_device_uid)
    partition_id = normalize_partition(read_ctx_value(ctx, :partition_id))
    gateway_id = read_ctx_value(ctx, :gateway_id)
    target_key = read_ctx_value(ctx, :target_key) || target_key(target_device_uid, target_ip, nil, nil)

    if missing_target_context?(target_key, target, target_ip) do
      {:error, :missing_target}
    else
      {:ok, normalized_target_ctx(target, target_ip, target_device_uid, partition_id, gateway_id, target_key)}
    end
  end

  defp normalize_target_ctx(_), do: {:error, :invalid_target_context}

  defp target_matches_policy_scope?(target_ctx, policy) do
    selector = Map.get(policy, :target_selector, %{}) || %{}
    srql_query = selector_string(selector, "srql_query")

    case scope_constraint(target_ctx) do
      nil ->
        true

      constraint when is_binary(srql_query) and srql_query != "" ->
        scope_query_matches?(srql_query, constraint)

      _ ->
        true
    end
  end

  defp cooldown_active?(target_ctx, mode, transition_class) do
    actor = SystemActor.system(:mtr_automation)
    trigger_mode = trigger_mode(mode)
    partition_id = normalize_partition(Map.get(target_ctx, :partition_id))
    target_key = Map.get(target_ctx, :target_key)

    query =
      MtrDispatchWindow
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        expr(
          target_key == ^target_key and
            trigger_mode == ^trigger_mode and
            transition_class == ^transition_class and
            partition_id == ^partition_id
        )
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [%{cooldown_until: %DateTime{} = cooldown_until}]} ->
        DateTime.compare(cooldown_until, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end

  defp put_dispatch_window(
         target_key,
         trigger_mode,
         transition_class,
         partition_id,
         now,
         cooldown_seconds,
         incident_correlation_id,
         source_agent_ids
       ) do
    actor = SystemActor.system(:mtr_automation)
    cooldown_until = DateTime.add(now, cooldown_seconds, :second)

    query =
      MtrDispatchWindow
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        expr(
          target_key == ^target_key and
            trigger_mode == ^trigger_mode and
            transition_class == ^transition_class and
            partition_id == ^partition_id
        )
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [window]} ->
        MtrDispatchWindow.update_window(
          window,
          %{
            last_dispatched_at: now,
            cooldown_until: cooldown_until,
            incident_correlation_id: incident_correlation_id,
            source_agent_ids: source_agent_ids,
            dispatch_count: (window.dispatch_count || 0) + 1
          },
          actor: actor
        )

      {:ok, []} ->
        MtrDispatchWindow.create_window(
          %{
            target_key: target_key,
            trigger_mode: trigger_mode,
            transition_class: transition_class,
            partition_id: partition_id,
            last_dispatched_at: now,
            cooldown_until: cooldown_until,
            incident_correlation_id: incident_correlation_id,
            source_agent_ids: source_agent_ids,
            dispatch_count: 1
          },
          actor: actor
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp device_to_target_ctx(device) do
    target_ip = blank_to_nil(device.ip)
    target = blank_to_nil(device.hostname) || target_ip
    device_uid = blank_to_nil(device.uid)

    %{
      target: target,
      target_ip: target_ip,
      target_device_uid: device_uid,
      partition_id: nil,
      gateway_id: blank_to_nil(device.gateway_id),
      target_key: target_key(device_uid, target_ip, :device, device_uid)
    }
  end

  defp row_to_target_ctx(row) when is_map(row) do
    target_ip = row_value(row, ["ip", "target_ip"])
    target = blank_to_nil(Map.get(row, "hostname")) || target_ip
    device_uid = row_value(row, ["uid", "device_uid", "id"])
    partition_id = normalize_partition(row_value(row, ["partition_id", "partition"]))
    gateway_id = blank_to_nil(Map.get(row, "gateway_id"))
    target_key = target_key(device_uid, target_ip, :device, device_uid)

    if valid_row_target?(target_key, target_ip) do
      %{
        target: target,
        target_ip: target_ip,
        target_device_uid: device_uid,
        partition_id: partition_id,
        gateway_id: gateway_id,
        target_key: target_key
      }
    else
      nil
    end
  end

  defp row_to_target_ctx(_), do: nil

  defp maybe_filter_uids(query, []), do: query

  defp maybe_filter_uids(query, uids) do
    Ash.Query.filter(query, expr(uid in ^uids))
  end

  defp maybe_filter_ips(query, []), do: query

  defp maybe_filter_ips(query, ips) do
    Ash.Query.filter(query, expr(ip in ^ips))
  end

  defp target_from_ctx(target_ctx) do
    Map.get(target_ctx, :target) || Map.get(target_ctx, :target_ip)
  end

  defp dispatch_context(target_ctx, trigger_mode, incident_correlation_id) do
    %{
      "trigger_mode" => trigger_mode,
      "target_device_uid" => Map.get(target_ctx, :target_device_uid),
      "target_ip" => Map.get(target_ctx, :target_ip),
      "target_key" => Map.get(target_ctx, :target_key),
      "incident_correlation_id" => incident_correlation_id
    }
  end

  defp dispatch_agent(agent_id, payload, context, partition_id, actor, trigger_mode) do
    case AgentCommandBus.dispatch(agent_id, "mtr.run", payload,
           context: context,
           partition_id: partition_id,
           required_partition: partition_id,
           required_capability: "mtr",
           actor: actor
         ) do
      {:ok, _command_id} ->
        true

      {:error, reason} ->
        Logger.warning("MTR automated dispatch failed",
          trigger_mode: trigger_mode,
          agent_id: agent_id,
          reason: inspect(reason)
        )

        false
    end
  end

  defp finalize_dispatch(
         [],
         _target_ctx,
         _policy,
         _mode,
         _meta
       ),
       do: {:error, :dispatch_failed}

  defp finalize_dispatch(
         dispatched,
         target_ctx,
         policy,
         mode,
         meta
       ) do
    transition_class = Map.fetch!(meta, :transition_class)
    incident_correlation_id = Map.fetch!(meta, :incident_correlation_id)
    trigger_mode = Map.fetch!(meta, :trigger_mode)
    partition_id = Map.fetch!(meta, :partition_id)
    now = Map.fetch!(meta, :now)

    _ =
      put_dispatch_window(
        Map.get(target_ctx, :target_key),
        trigger_mode,
        transition_class,
        partition_id,
        now,
        cooldown_seconds(policy, mode),
        incident_correlation_id,
        dispatched
      )

    {:ok, :dispatched}
  end

  defp read_ctx_value(ctx, key) do
    blank_to_nil(Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)))
  end

  defp missing_target_context?(target_key, target, target_ip) do
    is_nil(target_key) or (is_nil(target) and is_nil(target_ip))
  end

  defp normalized_target_ctx(target, target_ip, target_device_uid, partition_id, gateway_id, target_key) do
    %{
      target: target || target_ip,
      target_ip: target_ip || target,
      target_device_uid: target_device_uid,
      partition_id: partition_id,
      gateway_id: gateway_id,
      target_key: target_key
    }
  end

  defp scope_constraint(target_ctx) do
    target_device_uid = blank_to_nil(Map.get(target_ctx, :target_device_uid))
    target_ip = blank_to_nil(Map.get(target_ctx, :target_ip))

    cond do
      is_binary(target_device_uid) and target_device_uid != "" -> ~s(uid:"#{target_device_uid}")
      is_binary(target_ip) and target_ip != "" -> ~s(ip:"#{target_ip}")
      true -> nil
    end
  end

  defp scope_query_matches?(srql_query, constraint) do
    query = normalize_srql_target_query("#{srql_query} #{constraint}", 1)
    match?({:ok, [_ | _]}, SRQLRunner.query(query, limit: 1))
  end

  defp row_value(row, keys) when is_map(row) and is_list(keys) do
    keys
    |> Enum.find_value(fn key -> Map.get(row, key) end)
    |> blank_to_nil()
  end

  defp valid_row_target?(target_key, target_ip) do
    is_binary(target_key) and target_key != "" and is_binary(target_ip) and target_ip != ""
  end

  defp event_metadata(event) do
    Map.get(event, :metadata, %{}) || %{}
  end

  defp health_event_target_ip(metadata, entity_id) do
    metadata_value(metadata, "target_ip") ||
      metadata_value(metadata, "ip") ||
      if(ip_string?(entity_id), do: entity_id, else: nil)
  end

  defp health_event_target_device_uid(metadata) do
    metadata_value(metadata, "target_device_uid") || metadata_value(metadata, "device_uid")
  end

  defp health_event_partition_id(metadata) do
    metadata_value(metadata, "partition_id") || metadata_value(metadata, "partition")
  end

  defp target_key(device_uid, target_ip, entity_type, entity_id) do
    cond do
      is_binary(device_uid) and device_uid != "" ->
        "device:#{device_uid}"

      is_binary(target_ip) and target_ip != "" ->
        "ip:#{target_ip}"

      not is_nil(entity_type) and is_binary(entity_id) and entity_id != "" ->
        "entity:#{entity_type}:#{entity_id}"

      true ->
        nil
    end
  end

  defp transition_class(:incident), do: "incident"
  defp transition_class(:recovery), do: "recovery"
  defp transition_class(_), do: "baseline"

  defp trigger_mode(:baseline), do: "baseline"
  defp trigger_mode(:incident), do: "incident"
  defp trigger_mode(:recovery), do: "recovery"

  defp cooldown_seconds(policy, :baseline) do
    int_value(Map.get(policy, :baseline_interval_sec), 300)
  end

  defp cooldown_seconds(policy, _mode) do
    int_value(Map.get(policy, :incident_cooldown_sec), 600)
  end

  defp normalize_protocol(nil), do: "icmp"

  defp normalize_protocol(protocol) do
    value =
      protocol
      |> to_string()
      |> String.downcase()

    if value in ["icmp", "udp", "tcp"], do: value, else: "icmp"
  end

  defp selector_int(selector, key, default) do
    selector
    |> selector_value(key)
    |> int_value(default)
  end

  defp selector_list(selector, key) do
    case selector_value(selector, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&blank_to_nil/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp selector_string(selector, key) do
    selector
    |> selector_value(key)
    |> blank_to_nil()
  end

  defp selector_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    _ -> nil
  end

  defp selector_value(_, _), do: nil

  defp normalize_srql_target_query(query, limit) when is_binary(query) do
    query =
      query
      |> String.trim()
      |> normalize_srql_entity_prefix()

    if String.contains?(query, " limit:") or String.starts_with?(query, "limit:") do
      query
    else
      "#{query} limit:#{limit}"
    end
  end

  defp normalize_srql_entity_prefix(""), do: "in:devices"

  defp normalize_srql_entity_prefix(query) when is_binary(query) do
    if String.starts_with?(query, "in:") do
      query
    else
      "in:devices " <> query
    end
  end

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    _ -> nil
  end

  defp metadata_value(_, _), do: nil

  defp int_value(value, _default) when is_integer(value), do: value
  defp int_value(value, _default) when is_float(value), do: trunc(value)

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp int_value(_, default), do: default

  defp ip_string?(value) when is_binary(value) do
    value != "" and match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(value)))
  rescue
    _ -> false
  end

  defp ip_string?(_), do: false

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(value), do: to_string(value)

  defp normalize_partition(value) do
    case blank_to_nil(value) do
      nil -> ""
      partition -> partition
    end
  end
end
