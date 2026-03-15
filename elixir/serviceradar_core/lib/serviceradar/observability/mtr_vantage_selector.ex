defmodule ServiceRadar.Observability.MtrVantageSelector do
  @moduledoc """
  Pure scoring and source-agent selection for automated MTR dispatch.

  Selector behavior:
  - baseline: primary vantage + optional canaries
  - incident: bounded fanout cohort

  The selector is deterministic: ties are broken by `agent_id` ascending.
  """

  @freshness_horizon_seconds 3600
  @default_capacity_limit 10

  @default_weights %{
    affinity: 0.40,
    health: 0.25,
    freshness: 0.15,
    capacity: 0.15,
    rtt_penalty: 0.05
  }

  @type target_ctx :: map()
  @type policy :: map()
  @type candidate :: map()

  @spec select_baseline_vantages(target_ctx(), policy(), [candidate()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def select_baseline_vantages(target_ctx, policy, candidates) when is_list(candidates) do
    with {:ok, ranked} <- score_and_rank(target_ctx, policy, candidates) do
      canaries =
        policy
        |> get_int([:baseline_canary_vantages, "baseline_canary_vantages"], 0)
        |> max(0)

      selected = ranked |> Enum.take(1 + canaries) |> Enum.map(& &1.agent_id)
      {:ok, selected}
    end
  end

  @spec select_incident_vantages(target_ctx(), policy(), [candidate()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def select_incident_vantages(target_ctx, policy, candidates) when is_list(candidates) do
    with {:ok, ranked} <- score_and_rank(target_ctx, policy, candidates) do
      fanout =
        policy
        |> get_int([:incident_fanout_max_agents, "incident_fanout_max_agents"], 3)
        |> max(1)

      selected = ranked |> Enum.take(fanout) |> Enum.map(& &1.agent_id)
      {:ok, selected}
    end
  end

  @spec score_candidates(target_ctx(), policy(), [candidate()]) :: [map()]
  def score_candidates(target_ctx, policy, candidates) when is_list(candidates) do
    target_partition = get_value(target_ctx, [:partition_id, "partition_id"])

    weights = normalized_weights(policy)

    candidates
    |> Enum.map(&normalize_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&candidate_eligible?(&1, target_partition))
    |> Enum.map(fn candidate ->
      affinity = affinity_component(candidate, target_ctx)
      health = health_component(candidate)
      freshness = freshness_component(candidate)
      capacity = capacity_component(candidate, policy)
      rtt_penalty = rtt_penalty_component(candidate)

      score =
        weights.affinity * affinity +
          weights.health * health +
          weights.freshness * freshness +
          weights.capacity * capacity -
          weights.rtt_penalty * rtt_penalty

      %{
        agent_id: candidate.agent_id,
        score: score,
        components: %{
          affinity: affinity,
          health: health,
          freshness: freshness,
          capacity: capacity,
          rtt_penalty: rtt_penalty
        }
      }
    end)
    |> Enum.sort_by(fn row -> {-row.score, row.agent_id} end)
  end

  def score_candidates(_, _, _), do: []

  defp score_and_rank(target_ctx, policy, candidates) do
    ranked = score_candidates(target_ctx, policy, candidates)

    if ranked == [] do
      {:error, :no_candidates}
    else
      {:ok, ranked}
    end
  end

  defp normalize_candidate(candidate) when is_map(candidate) do
    agent_id = candidate |> get_value([:agent_id, "agent_id"]) |> normalize_string()

    if is_nil(agent_id) do
      nil
    else
      %{
        agent_id: agent_id,
        partition_id:
          candidate |> get_value([:partition_id, "partition_id"]) |> normalize_string(),
        gateway_id: candidate |> get_value([:gateway_id, "gateway_id"]) |> normalize_string(),
        status: get_value(candidate, [:status, "status"]),
        capabilities:
          normalize_capabilities(get_value(candidate, [:capabilities, "capabilities"])),
        mtr_capable: normalize_bool(get_value(candidate, [:mtr_capable, "mtr_capable"])),
        in_flight: get_int(candidate, [:in_flight, "in_flight"], 0),
        control_rtt_ms: get_int(candidate, [:control_rtt_ms, "control_rtt_ms"], 0),
        last_success_at: get_value(candidate, [:last_success_at, "last_success_at"])
      }
    end
  end

  defp normalize_candidate(_), do: nil

  defp candidate_eligible?(candidate, target_partition) do
    partition_ok =
      if is_binary(target_partition) and target_partition != "" do
        candidate.partition_id == target_partition
      else
        true
      end

    partition_ok and mtr_capable?(candidate) and health_component(candidate) > 0.0
  end

  defp mtr_capable?(candidate) do
    candidate.mtr_capable == true or "mtr" in candidate.capabilities
  end

  defp affinity_component(candidate, target_ctx) do
    target_partition =
      target_ctx |> get_value([:partition_id, "partition_id"]) |> normalize_string()

    target_gateway = target_ctx |> get_value([:gateway_id, "gateway_id"]) |> normalize_string()

    cond do
      match?(
        ^target_partition when is_binary(target_partition) and target_partition != "",
        candidate.partition_id
      ) and
          match?(
            ^target_gateway when is_binary(target_gateway) and target_gateway != "",
            candidate.gateway_id
          ) ->
        1.0

      match?(
        ^target_partition when is_binary(target_partition) and target_partition != "",
        candidate.partition_id
      ) ->
        0.6

      true ->
        0.0
    end
  end

  defp health_component(candidate) do
    case normalize_string(candidate.status) do
      "connected" -> 1.0
      "healthy" -> 1.0
      "degraded" -> 0.5
      _ -> 0.0
    end
  end

  defp freshness_component(candidate) do
    case normalize_datetime(candidate.last_success_at) do
      %DateTime{} = dt ->
        age_sec = DateTime.diff(DateTime.utc_now(), dt, :second)
        bounded_age = min(max(age_sec, 0), @freshness_horizon_seconds)
        1.0 - bounded_age / @freshness_horizon_seconds

      _ ->
        0.0
    end
  end

  defp capacity_component(candidate, policy) do
    limit = get_int(policy, [:capacity_limit, "capacity_limit"], @default_capacity_limit)

    if limit <= 0 do
      0.0
    else
      ratio = candidate.in_flight / limit
      max(0.0, 1.0 - ratio)
    end
  end

  defp rtt_penalty_component(candidate) do
    if candidate.control_rtt_ms <= 0 do
      0.0
    else
      min(1.0, candidate.control_rtt_ms / 500.0)
    end
  end

  defp normalized_weights(policy) do
    base = @default_weights

    custom = %{
      affinity: max(get_float(policy, [:w_affinity, "w_affinity"], base.affinity), 0.0),
      health: max(get_float(policy, [:w_health, "w_health"], base.health), 0.0),
      freshness: max(get_float(policy, [:w_freshness, "w_freshness"], base.freshness), 0.0),
      capacity: max(get_float(policy, [:w_capacity, "w_capacity"], base.capacity), 0.0),
      rtt_penalty:
        max(get_float(policy, [:w_rtt_penalty, "w_rtt_penalty"], base.rtt_penalty), 0.0)
    }

    total =
      custom.affinity + custom.health + custom.freshness + custom.capacity + custom.rtt_penalty

    if total > 0 do
      %{
        affinity: custom.affinity / total,
        health: custom.health / total,
        freshness: custom.freshness / total,
        capacity: custom.capacity / total,
        rtt_penalty: custom.rtt_penalty / total
      }
    else
      base
    end
  end

  defp get_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_value(_, _), do: nil

  defp get_int(map, keys, default) do
    case get_value(map, keys) do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        trunc(v)

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp get_float(map, keys, default) do
    case get_value(map, keys) do
      v when is_float(v) ->
        v

      v when is_integer(v) ->
        v / 1.0

      v when is_binary(v) ->
        case Float.parse(v) do
          {n, ""} -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_capabilities(v) when is_list(v) do
    v
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn item ->
      item
      |> to_string()
      |> String.trim()
      |> String.downcase()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_capabilities(v) when is_binary(v), do: [String.downcase(v)]
  defp normalize_capabilities(_), do: []

  defp normalize_bool(v) when is_boolean(v), do: v
  defp normalize_bool(v) when is_binary(v), do: String.downcase(v) == "true"
  defp normalize_bool(_), do: false

  defp normalize_string(v) when is_binary(v) do
    v = String.trim(v)
    if v == "", do: nil, else: v
  end

  defp normalize_string(v) when is_atom(v), do: v |> Atom.to_string() |> normalize_string()
  defp normalize_string(_), do: nil

  defp normalize_datetime(%DateTime{} = dt), do: dt

  defp normalize_datetime(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp normalize_datetime(_), do: nil
end
