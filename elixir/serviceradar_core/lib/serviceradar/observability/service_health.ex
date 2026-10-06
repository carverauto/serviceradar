defmodule ServiceRadar.Observability.ServiceHealth do
  @moduledoc """
  Unified service health and availability summary.

  Provides distinct active plugin service health metrics shared between the
  operations dashboard Network Health card and the `/services` catalog.
  Counts are based on active plugin identities in `platform.service_state`,
  ensuring both views share the same semantics and cannot drift.
  """

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Repo

  @type summary :: %{
          total: non_neg_integer(),
          available: non_neg_integer(),
          unavailable: non_neg_integer(),
          availability_pct: float(),
          last_updated: DateTime.t() | nil,
          check_count: non_neg_integer()
        }

  @doc """
  Returns an empty service health summary.
  """
  @spec empty_summary() :: summary()
  def empty_summary do
    %{
      total: 0,
      available: 0,
      unavailable: 0,
      availability_pct: 0.0,
      last_updated: nil,
      check_count: 0
    }
  end

  @doc """
  Computes the distinct service availability summary.

  Accepts:
  - a list of `ServiceState` structs or maps (computed in memory)
  - a keyword list of options (e.g. `[states: ...]` or `[scope: ...]`)
  - a scope struct or map or `nil` (queries `platform.service_state`)
  """
  @spec summary(list() | map() | keyword() | term()) :: summary()
  def summary(target \\ [])

  def summary(states) when is_list(states) and states != [] do
    if Keyword.keyword?(states) do
      summary_from_opts(states)
    else
      summary_from_states(states)
    end
  end

  def summary([]), do: empty_summary()

  def summary(%{} = map) do
    summary_from_db(scope: map)
  end

  def summary(scope) do
    summary_from_db(scope: scope)
  end

  @doc """
  Computes the distinct service availability summary with options.
  """
  @spec summary(list() | term(), keyword()) :: summary()
  def summary(states, opts) when is_list(opts) do
    if is_list(states) and states != [] do
      summary_from_states(states)
    else
      summary_from_db(opts)
    end
  end

  @doc """
  Computes the distinct service summary from a list of `ServiceState` records.
  """
  @spec summary_from_states(list()) :: summary()
  def summary_from_states(states) when is_list(states) do
    unique_states = dedupe_states(states)
    total = length(unique_states)

    {available, unavailable, last_updated} =
      Enum.reduce(unique_states, {0, 0, nil}, fn state, {avail, unavail, latest_ts} ->
        is_available = extract_available(state)
        new_avail = if is_available, do: avail + 1, else: avail
        new_unavail = if is_available, do: unavail, else: unavail + 1
        new_ts = max_datetime(extract_observed_at(state), latest_ts)
        {new_avail, new_unavail, new_ts}
      end)

    availability_pct = compute_availability_pct(total, available)

    %{
      total: total,
      available: available,
      unavailable: unavailable,
      availability_pct: availability_pct,
      last_updated: last_updated,
      check_count: total
    }
  end

  @doc """
  Queries `platform.service_state` for active plugin services and returns the distinct summary.
  """
  @spec summary_from_db(keyword()) :: summary()
  def summary_from_db(_opts \\ []) do
    sql = summary_sql()

    case Repo.query(sql, []) do
      {:ok, %{rows: [[total, available, unavailable, last_updated]]}} ->
        total = to_int(total)
        available = to_int(available)
        unavailable = to_int(unavailable)
        availability_pct = compute_availability_pct(total, available)

        %{
          total: total,
          available: available,
          unavailable: unavailable,
          availability_pct: availability_pct,
          last_updated: normalize_datetime(last_updated),
          check_count: total
        }

      _ ->
        empty_summary()
    end
  rescue
    _ -> empty_summary()
  end

  @doc """
  SQL query used to aggregate distinct active plugin service states.
  """
  def summary_sql do
    """
    WITH distinct_services AS (
      SELECT DISTINCT ON (
        service_state.agent_id,
        service_state.partition,
        service_state.service_type,
        service_state.service_name
      )
        service_state.available,
        service_state.last_observed_at
      FROM platform.service_state AS service_state
      WHERE service_state.state = 'active'
        AND service_state.service_type = 'plugin'
      ORDER BY
        service_state.agent_id,
        service_state.partition,
        service_state.service_type,
        service_state.service_name,
        #{PluginStateContract.state_winner_order_sql()}
    )
    SELECT
      COUNT(*)::bigint AS total,
      COUNT(*) FILTER (WHERE available = true)::bigint AS available,
      COUNT(*) FILTER (WHERE available = false)::bigint AS unavailable,
      MAX(last_observed_at) AS last_updated
    FROM distinct_services
    """
  end

  @doc """
  Deduplicates `ServiceState` records to select one winner per logical identity.
  """
  def dedupe_states(states) when is_list(states) do
    states
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&state_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn state, acc ->
      Map.put_new(acc, state_identity_key(state), state)
    end)
    |> Map.values()
  end

  defp summary_from_opts(opts) do
    states = Keyword.get(opts, :states) || Keyword.get(opts, :plugin_states)

    if states do
      if is_list(states) and states != [] do
        summary_from_states(states)
      else
        empty_summary()
      end
    else
      summary_from_db(opts)
    end
  end

  defp state_sort_key(%ServiceState{} = state), do: PluginStateContract.state_rank(state)

  defp state_sort_key(%{} = state),
    do: PluginStateContract.snapshot_rank(state_to_snapshot(state))

  defp state_sort_key(_), do: -1

  defp state_to_snapshot(state) do
    timestamp =
      Map.get(state, :last_observed_at) || Map.get(state, "last_observed_at") ||
        Map.get(state, :timestamp) || Map.get(state, "timestamp")

    %{
      agent_id: Map.get(state, :agent_id) || Map.get(state, "agent_id"),
      gateway_id: Map.get(state, :gateway_id) || Map.get(state, "gateway_id"),
      partition: Map.get(state, :partition) || Map.get(state, "partition"),
      service_type: Map.get(state, :service_type) || Map.get(state, "service_type"),
      service_name: Map.get(state, :service_name) || Map.get(state, "service_name"),
      message: Map.get(state, :message) || Map.get(state, "message"),
      details: Map.get(state, :details) || Map.get(state, "details"),
      timestamp: normalize_snapshot_timestamp(timestamp),
      available: Map.get(state, :available, Map.get(state, "available"))
    }
  end

  defp normalize_snapshot_timestamp(value) when is_binary(value) do
    parse_iso_datetime(value) || value
  end

  defp normalize_snapshot_timestamp(value), do: value

  defp state_identity_key(state) do
    agent_id = Map.get(state, :agent_id) || Map.get(state, "agent_id") || ""
    partition = Map.get(state, :partition) || Map.get(state, "partition") || ""
    service_type = Map.get(state, :service_type) || Map.get(state, "service_type") || ""
    service_name = Map.get(state, :service_name) || Map.get(state, "service_name") || ""

    "#{agent_id}:#{partition}:#{service_type}:#{service_name}"
  end

  defp parse_iso_datetime(%DateTime{} = dt), do: dt

  defp parse_iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_iso_datetime(_), do: nil

  defp extract_available(%{available: avail}) when is_boolean(avail), do: avail
  defp extract_available(%{"available" => avail}) when is_boolean(avail), do: avail
  defp extract_available(%{available: avail}), do: normalize_available(avail)
  defp extract_available(%{"available" => avail}), do: normalize_available(avail)
  defp extract_available(_), do: false

  defp normalize_available(true), do: true
  defp normalize_available("true"), do: true
  defp normalize_available("t"), do: true
  defp normalize_available("1"), do: true
  defp normalize_available(1), do: true
  defp normalize_available(_), do: false

  defp compute_availability_pct(total, available) when total > 0 and available >= 0 do
    Float.round(available / total * 100.0, 1)
  end

  defp compute_availability_pct(_total, _available), do: 0.0

  defp to_int(nil), do: 0
  defp to_int(val) when is_integer(val), do: max(val, 0)
  defp to_int(val) when is_float(val), do: val |> trunc() |> max(0)
  defp to_int(%Decimal{} = val), do: val |> Decimal.to_integer() |> max(0)
  defp to_int(_), do: 0

  defp max_datetime(nil, current), do: current
  defp max_datetime(current, nil), do: current

  defp max_datetime(dt1, dt2) do
    if DateTime.after?(dt1, dt2), do: dt1, else: dt2
  end

  defp extract_observed_at(%{last_observed_at: %DateTime{} = dt}), do: dt

  defp extract_observed_at(%{last_observed_at: %NaiveDateTime{} = ndt}),
    do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp extract_observed_at(%{"last_observed_at" => %DateTime{} = dt}), do: dt

  defp extract_observed_at(%{"last_observed_at" => %NaiveDateTime{} = ndt}),
    do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp extract_observed_at(%{"last_observed_at" => str}) when is_binary(str),
    do: parse_iso_datetime(str)

  defp extract_observed_at(_), do: nil

  defp normalize_datetime(%DateTime{} = dt), do: dt
  defp normalize_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp normalize_datetime(_), do: nil
end
