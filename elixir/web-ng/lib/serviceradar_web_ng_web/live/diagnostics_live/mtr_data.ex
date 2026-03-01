defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrData do
  @moduledoc false

  import Ash.Expr
  require Ash.Query

  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo

  @default_pending_states [:queued, :sent, :acknowledged, :running]

  def list_traces(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    limit = Keyword.get(opts, :limit, 50)

    {where_clause, params} = build_trace_where(target_filter, agent_filter, device_uid, device_ip)

    query = """
    SELECT id::text AS id, time, agent_id, check_name, device_id, target, target_ip,
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
    WHERE id = $1
    LIMIT 1
    """

    hops_query = """
    SELECT hop_number, addr, hostname, ecmp_addrs, asn, asn_org,
           mpls_labels, sent, received, loss_pct,
           last_us, avg_us, min_us, max_us, stddev_us,
           jitter_us, jitter_worst_us, jitter_interarrival_us
    FROM mtr_hops
    WHERE trace_id = $1
    ORDER BY hop_number ASC
    """

    with {:ok, %{rows: [trace_row], columns: trace_cols}} <- Repo.query(trace_query, [trace_id]),
         {:ok, %{rows: hop_rows, columns: hop_cols}} <- Repo.query(hops_query, [trace_id]) do
      trace = Enum.zip(trace_cols, trace_row) |> Map.new()
      hops = Enum.map(hop_rows, fn row -> Enum.zip(hop_cols, row) |> Map.new() end)
      {:ok, trace, hops}
    else
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_trace_detail(_), do: {:error, :invalid_trace_id}

  defp build_trace_where(target_filter, agent_filter, device_uid, device_ip) do
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
          {conditions ++ ["(device_id = $#{idx} OR target_ip = $#{idx + 1})"],
           params ++ [uid, ip], idx + 2}

        {uid, _ip} when is_binary(uid) and uid != "" ->
          {conditions ++ ["device_id = $#{idx}"], params ++ [uid], idx + 1}

        {_uid, ip} when is_binary(ip) and ip != "" ->
          {conditions ++ ["target_ip = $#{idx}"], params ++ [ip], idx + 1}

        _ ->
          {conditions, params, idx}
      end

    if conditions == [] do
      {"", params}
    else
      {"WHERE " <> Enum.join(conditions, " AND "), params}
    end
  end

  defp load_last_hop_latencies([]), do: []

  defp load_last_hop_latencies(traces) do
    trace_ids = Enum.map(traces, & &1["id"])
    placeholders = Enum.map_join(1..length(trace_ids), ", ", fn i -> "$#{i}" end)

    query = """
    SELECT DISTINCT ON (trace_id) trace_id::text, avg_us
    FROM mtr_hops
    WHERE trace_id IN (#{placeholders})
      AND addr IS NOT NULL
    ORDER BY trace_id, hop_number DESC
    """

    case Repo.query(query, trace_ids) do
      {:ok, %{rows: rows}} ->
        latency_map = Map.new(rows, fn [trace_id, avg_us] -> {trace_id, avg_us || 0} end)

        Enum.map(traces, fn trace ->
          {trace["time"], Map.get(latency_map, trace["id"], 0)}
        end)

      {:error, _reason} ->
        []
    end
  end

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
    context = Map.get(job, :context, %{})
    payload = Map.get(job, :payload, %{})
    context_device_uid = fetch_map(context, "device_uid") |> to_string_safe()
    payload_target = fetch_map(payload, "target") |> to_string_safe()

    uid_match? = device_uid && context_device_uid == device_uid
    ip_match? = device_ip && payload_target == device_ip
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

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)
end
