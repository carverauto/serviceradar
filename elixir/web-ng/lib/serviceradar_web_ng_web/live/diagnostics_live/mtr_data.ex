defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrData do
  @moduledoc false

  import Ash.Expr
  require Ash.Query

  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo

  @default_pending_states [:queued, :sent, :acknowledged, :running]
  @default_sort {"time", "DESC"}
  @allowed_sort_fields %{
    "time" => "time",
    "target" => "target",
    "target_ip" => "target_ip",
    "agent_id" => "agent_id",
    "protocol" => "protocol",
    "total_hops" => "total_hops",
    "target_reached" => "target_reached"
  }
  @allowed_filter_fields MapSet.new([
                           "target",
                           "target_ip",
                           "agent_id",
                           "protocol",
                           "check_name",
                           "device_id",
                           "target_reached",
                           "error"
                         ])
  @boolean_filter_fields MapSet.new(["target_reached"])
  @exact_filter_fields MapSet.new(["protocol", "device_id", "target_reached"])
  @safe_filter_columns %{
    "target" => "target",
    "target_ip" => "target_ip",
    "agent_id" => "agent_id",
    "protocol" => "protocol",
    "check_name" => "check_name",
    "device_id" => "device_id::text",
    "target_reached" => "target_reached",
    "error" => "error"
  }

  def list_traces(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    limit = normalize_limit(Keyword.get(opts, :limit, 50))

    {where_clause, params} = build_trace_where(target_filter, agent_filter, device_uid, device_ip)

    query = """
    SELECT id::text AS id, time, agent_id, check_id, check_name, device_id, target, target_ip,
           target_reached, total_hops, protocol, ip_version, error
    FROM mtr_traces
    #{where_clause}
    ORDER BY time DESC
    LIMIT $#{length(params) + 1}
    """

    case Repo.query(query, params ++ [limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_traces_paginated(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    srql_query = normalize_string(Keyword.get(opts, :srql_query, ""))
    page = normalize_page(Keyword.get(opts, :page, 1))
    per_page = normalize_limit(Keyword.get(opts, :limit, 50))

    {where_clause, params, srql_sort} =
      build_trace_where_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query)

    {sort_field, sort_dir} = srql_sort || @default_sort
    offset = (page - 1) * per_page

    query = """
    SELECT id::text AS id, time, agent_id, check_id, check_name, device_id, target, target_ip,
           target_reached, total_hops, protocol, ip_version, error
    FROM mtr_traces
    #{where_clause}
    ORDER BY #{sort_field} #{sort_dir}
    LIMIT $#{length(params) + 1}
    OFFSET $#{length(params) + 2}
    """

    count_query = """
    SELECT COUNT(*)::bigint AS total
    FROM mtr_traces
    #{where_clause}
    """

    with {:ok, %{rows: rows, columns: columns}} <- Repo.query(query, params ++ [per_page, offset]),
         {:ok, %{rows: [[total]]}} <- Repo.query(count_query, params) do
      {:ok,
       %{
         rows: Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end),
         total_count: total || 0,
         page: page,
         per_page: per_page
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_pending_jobs(scope, opts \\ []) do
    pending_states = Keyword.get(opts, :states, @default_pending_states)
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))

    query =
      AgentCommand
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(command_type == "mtr.run" and status in ^pending_states))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(100)

    with {:ok, jobs} <- read_all(query, scope) do
      jobs
      |> Enum.filter(fn job ->
        match_target?(job, target_filter) and
          match_agent?(job, agent_filter) and
          match_device?(job, device_uid, device_ip)
      end)
      |> Enum.take(25)
      |> then(&{:ok, &1})
    end
  end

  def build_trends(traces) when is_list(traces) do
    sorted = Enum.reverse(traces)

    hops =
      Enum.map(sorted, fn trace ->
        {trace["time"], trace["total_hops"] || 0}
      end)

    latency = load_last_hop_latencies(sorted)

    %{hops: hops, latency: latency}
  end

  def build_trends(_), do: %{hops: [], latency: []}

  def get_trace_detail(trace_id) when is_binary(trace_id) and trace_id != "" do
    trace_query = """
    SELECT id::text AS id, time, agent_id, gateway_id, check_id, check_name, device_id,
           target, target_ip, target_reached, total_hops, protocol,
           ip_version, packet_size, partition, error
    FROM mtr_traces
    WHERE id::text = $1
    LIMIT 1
    """

    hops_query = """
    SELECT hop_number, addr, hostname, ecmp_addrs, asn, asn_org,
           mpls_labels, sent, received, loss_pct,
           last_us, avg_us, min_us, max_us, stddev_us,
           jitter_us, jitter_worst_us, jitter_interarrival_us
    FROM mtr_hops
    WHERE trace_id::text = $1
    ORDER BY hop_number ASC
    """

    with {:ok, %{rows: [trace_row], columns: trace_cols}} <- Repo.query(trace_query, [trace_id]),
         trace <- Enum.zip(trace_cols, trace_row) |> Map.new(),
         {:ok, %{rows: hop_rows, columns: hop_cols}} <- Repo.query(hops_query, [trace_id]) do
      hops = Enum.map(hop_rows, fn row -> Enum.zip(hop_cols, row) |> Map.new() end)
      {:ok, trace, hops}
    else
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_trace_detail(_), do: {:error, :invalid_trace_id}

  def suppress_completed_pending_jobs(pending_jobs, traces)
      when is_list(pending_jobs) and is_list(traces) do
    completed_command_ids =
      traces
      |> Enum.map(&Map.get(&1, "check_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.reject(pending_jobs, fn job ->
      job_id = Map.get(job, :id) || Map.get(job, "id")
      is_binary(job_id) and MapSet.member?(completed_command_ids, job_id)
    end)
  end

  def suppress_completed_pending_jobs(pending_jobs, _traces), do: pending_jobs

  defp build_trace_where(target_filter, agent_filter, device_uid, device_ip) do
    {conditions, params} =
      build_trace_conditions(target_filter, agent_filter, device_uid, device_ip)

    where_clause =
      if conditions == [] do
        ""
      else
        "WHERE " <> Enum.join(conditions, " AND ")
      end

    {where_clause, params}
  end

  defp build_trace_conditions(target_filter, agent_filter, device_uid, device_ip) do
    conditions = []
    params = []
    idx = 1

    {conditions, params, idx} =
      if target_filter != "" do
        {conditions ++ ["(target ILIKE $#{idx} OR target_ip ILIKE $#{idx})"],
         params ++ ["%#{target_filter}%"], idx + 1}
      else
        {conditions, params, idx}
      end

    {conditions, params, idx} =
      if agent_filter != "" do
        {conditions ++ ["agent_id ILIKE $#{idx}"], params ++ ["%#{agent_filter}%"], idx + 1}
      else
        {conditions, params, idx}
      end

    {conditions, params, _idx} =
      case {device_uid, device_ip} do
        {uid, ip} when is_binary(uid) and uid != "" and is_binary(ip) and ip != "" ->
          {conditions ++ ["(device_id::text = $#{idx} OR target_ip = $#{idx + 1})"],
           params ++ [uid, ip], idx + 2}

        {uid, _ip} when is_binary(uid) and uid != "" ->
          {conditions ++ ["device_id::text = $#{idx}"], params ++ [uid], idx + 1}

        {_uid, ip} when is_binary(ip) and ip != "" ->
          {conditions ++ ["target_ip = $#{idx}"], params ++ [ip], idx + 1}

        _ ->
          {conditions, params, idx}
      end

    {conditions, params}
  end

  defp load_last_hop_latencies([]), do: []

  defp load_last_hop_latencies(traces) do
    trace_ids = valid_trace_ids(traces)

    case trace_ids do
      [] ->
        []

      _ ->
        latency_map = fetch_last_hop_latency_map(trace_ids)

        Enum.map(traces, fn trace ->
          {trace["time"], Map.get(latency_map, trace["id"], 0)}
        end)
    end
  end

  defp valid_trace_ids(traces) do
    traces
    |> Enum.map(& &1["id"])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.filter(&uuid?/1)
  end

  defp fetch_last_hop_latency_map(trace_ids) do
    placeholders = Enum.map_join(1..length(trace_ids), ", ", fn i -> "$#{i}" end)

    query = """
    SELECT DISTINCT ON (trace_id) trace_id::text, avg_us
    FROM mtr_hops
    WHERE trace_id::text IN (#{placeholders})
      AND addr IS NOT NULL
    ORDER BY trace_id, hop_number DESC
    """

    case Repo.query(query, trace_ids) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [trace_id, avg_us] -> {trace_id, avg_us || 0} end)

      {:error, _reason} ->
        %{}
    end
  end

  defp uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> true
      :error -> false
    end
  end

  defp uuid?(_value), do: false

  defp read_all(query, scope) do
    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{results: jobs}} -> {:ok, jobs}
      {:ok, jobs} when is_list(jobs) -> {:ok, jobs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_target?(_job, ""), do: true

  defp match_target?(job, target_filter) do
    target =
      job
      |> Map.get(:payload, %{})
      |> fetch_map("target")
      |> to_string_safe()
      |> String.downcase()

    String.contains?(target, String.downcase(target_filter))
  end

  defp match_agent?(_job, ""), do: true

  defp match_agent?(job, agent_filter) do
    job
    |> Map.get(:agent_id, "")
    |> to_string_safe()
    |> String.downcase()
    |> String.contains?(String.downcase(agent_filter))
  end

  defp match_device?(_job, nil, nil), do: true

  defp match_device?(job, device_uid, device_ip) do
    device_uid =
      if is_binary(device_uid) and String.trim(device_uid) == "", do: nil, else: device_uid

    device_ip = if is_binary(device_ip) and String.trim(device_ip) == "", do: nil, else: device_ip

    context = Map.get(job, :context, %{})
    payload = Map.get(job, :payload, %{})
    context_device_uid = fetch_map(context, "device_uid") |> to_string_safe()
    payload_target = fetch_map(payload, "target") |> to_string_safe()

    uid_match? = is_binary(device_uid) and context_device_uid == device_uid
    ip_match? = is_binary(device_ip) and payload_target == device_ip
    uid_match? || ip_match?
  end

  defp fetch_map(map, key) when is_map(map) and is_binary(key) do
    case key do
      "target" -> Map.get(map, "target") || Map.get(map, :target)
      "device_uid" -> Map.get(map, "device_uid") || Map.get(map, :device_uid)
      _ -> Map.get(map, key)
    end
  end

  defp fetch_map(_map, _key), do: nil

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "", else: value
  end

  defp normalize_string(value), do: to_string(value)

  defp normalize_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_page(_), do: 1

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(200)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> 50
    end
  end

  defp normalize_limit(_), do: 50

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp build_trace_where_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query) do
    {conditions, params} =
      build_trace_conditions(target_filter, agent_filter, device_uid, device_ip)

    idx = length(params) + 1

    {srql_conditions, srql_params, _idx, srql_sort} = parse_srql_conditions(srql_query, idx)
    all_conditions = conditions ++ srql_conditions
    all_params = params ++ srql_params

    final_where =
      if all_conditions == [] do
        ""
      else
        "WHERE " <> Enum.join(all_conditions, " AND ")
      end

    {final_where, all_params, srql_sort}
  end

  defp parse_srql_conditions(query, start_idx) when is_binary(query) do
    query
    |> tokenize_srql()
    |> Enum.reduce({[], [], start_idx, nil}, fn token, {conditions, params, idx, sort} ->
      token
      |> String.trim()
      |> maybe_parse_token(conditions, params, idx, sort)
    end)
  end

  defp parse_srql_conditions(_, start_idx), do: {[], [], start_idx, nil}

  defp maybe_parse_token("", conditions, params, idx, sort), do: {conditions, params, idx, sort}

  defp maybe_parse_token(token, conditions, params, idx, sort) do
    cond do
      String.starts_with?(token, "in:") ->
        {conditions, params, idx, sort}

      String.starts_with?(token, "limit:") ->
        {conditions, params, idx, sort}

      String.starts_with?(token, "sort:") ->
        {conditions, params, idx, parse_sort_token(token) || sort}

      String.starts_with?(token, "time:") ->
        {conditions, params, idx, sort}

      String.contains?(token, ":") ->
        apply_field_filter(token, conditions, params, idx, sort)

      true ->
        text = normalize_srql_value(token)

        if text == "" do
          {conditions, params, idx, sort}
        else
          condition =
            "(target ILIKE $#{idx} OR target_ip ILIKE $#{idx} OR agent_id ILIKE $#{idx} OR check_name ILIKE $#{idx})"

          {conditions ++ [condition], params ++ ["%#{text}%"], idx + 1, sort}
        end
    end
  end

  defp apply_field_filter(token, conditions, params, idx, sort) do
    case String.split(token, ":", parts: 2) do
      [raw_field, raw_value] ->
        field = String.downcase(raw_field)
        value = normalize_srql_value(raw_value)
        apply_filter_by_field(field, value, conditions, params, idx, sort)

      _ ->
        {conditions, params, idx, sort}
    end
  end

  defp apply_filter_by_field("", _value, conditions, params, idx, sort),
    do: {conditions, params, idx, sort}

  defp apply_filter_by_field(_field, value, conditions, params, idx, sort)
       when not is_binary(value) or value == "" do
    {conditions, params, idx, sort}
  end

  defp apply_filter_by_field(field, value, conditions, params, idx, sort) do
    col = Map.get(@safe_filter_columns, field)

    cond do
      is_nil(col) or not MapSet.member?(@allowed_filter_fields, field) ->
        {conditions, params, idx, sort}

      MapSet.member?(@boolean_filter_fields, field) ->
        maybe_add_boolean_filter(parse_boolean(value), col, conditions, params, idx, sort)

      MapSet.member?(@exact_filter_fields, field) ->
        {conditions ++ ["#{col} = $#{idx}"], params ++ [value], idx + 1, sort}

      true ->
        {conditions ++ ["#{col} ILIKE $#{idx}"], params ++ ["%#{value}%"], idx + 1, sort}
    end
  end

  defp maybe_add_boolean_filter(nil, _field, conditions, params, idx, sort),
    do: {conditions, params, idx, sort}

  defp maybe_add_boolean_filter(bool_value, field, conditions, params, idx, sort) do
    {conditions ++ ["#{field} = $#{idx}"], params ++ [bool_value], idx + 1, sort}
  end

  defp parse_sort_token("sort:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [field, dir] -> parse_sort_mapping(field, dir)
      _ -> nil
    end
  end

  defp parse_sort_token(_token), do: nil

  defp parse_sort_mapping(field, dir) do
    case Map.fetch(@allowed_sort_fields, field) do
      {:ok, mapped_field} ->
        mapped_dir = if String.downcase(dir) == "asc", do: "ASC", else: "DESC"
        {mapped_field, mapped_dir}

      :error ->
        nil
    end
  end

  defp tokenize_srql(query) do
    ~r/"[^"]*"|\S+/
    |> Regex.scan(query)
    |> Enum.map(&List.first/1)
  end

  defp normalize_srql_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim("\"")
  end

  defp normalize_srql_value(_), do: ""

  defp parse_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      _ -> nil
    end
  end

  defp parse_boolean(_), do: nil
end
