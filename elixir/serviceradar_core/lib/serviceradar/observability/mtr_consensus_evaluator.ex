defmodule ServiceRadar.Observability.MtrConsensusEvaluator do
  @moduledoc """
  Pure consensus evaluator for multi-agent MTR outcomes.
  """

  @default_consensus_mode "majority"
  @default_consensus_threshold 0.66
  @default_consensus_min_agents 2
  @default_loss_threshold_pct 20.0
  @default_rtt_threshold_ms 250.0

  @type outcome :: map()
  @type policy :: map()

  @spec aggregate_weighted_votes([outcome()], policy()) :: %{
          p_unreachable: float(),
          p_anomalous: float(),
          p_success: float(),
          counts: %{
            unreachable: non_neg_integer(),
            anomalous: non_neg_integer(),
            success: non_neg_integer()
          },
          cohort_size: non_neg_integer(),
          weight_total: float()
        }
  def aggregate_weighted_votes(outcomes \\ [], policy \\ %{})

  def aggregate_weighted_votes(outcomes, policy) when is_list(outcomes) and is_map(policy) do
    normalized = Enum.map(outcomes, &normalize_outcome(&1, policy))

    totals =
      Enum.reduce(
        normalized,
        %{unreachable: 0.0, anomalous: 0.0, success: 0.0, weight_total: 0.0},
        fn outcome, acc ->
          category = categorize(outcome, policy)
          weight = max(outcome.weight, 0.0)

          acc
          |> Map.update!(:weight_total, &(&1 + weight))
          |> Map.update!(category, &(&1 + weight))
        end
      )

    counts = Enum.frequencies_by(normalized, &categorize(&1, policy))
    weight_total = totals.weight_total

    %{
      p_unreachable: probability(totals.unreachable, weight_total),
      p_anomalous: probability(totals.anomalous, weight_total),
      p_success: probability(totals.success, weight_total),
      counts: %{
        unreachable: Map.get(counts, :unreachable, 0),
        anomalous: Map.get(counts, :anomalous, 0),
        success: Map.get(counts, :success, 0)
      },
      cohort_size: length(normalized),
      weight_total: weight_total
    }
  end

  def aggregate_weighted_votes(_, _), do: aggregate_weighted_votes([], %{})

  @spec classify([outcome()], policy()) :: %{
          classification: atom(),
          confidence: float(),
          evidence: map()
        }
  def classify(outcomes \\ [], policy \\ %{})

  def classify(outcomes, policy) when is_list(outcomes) and is_map(policy) do
    votes = aggregate_weighted_votes(outcomes, policy)
    mode = consensus_mode(policy)
    threshold = consensus_threshold(policy)
    min_agents = consensus_min_agents(policy)
    coverage_factor = coverage_factor(votes.cohort_size, min_agents)

    classification =
      cond do
        votes.cohort_size < min_agents ->
          :insufficient_evidence

        quorum?(votes.p_unreachable, mode, threshold) ->
          :target_outage

        votes.p_unreachable > 0.0 and votes.p_success > 0.0 ->
          :path_scoped_issue

        quorum?(votes.p_anomalous, mode, threshold) ->
          :degraded_path

        quorum?(votes.p_success, mode, threshold) ->
          :healthy

        true ->
          :insufficient_evidence
      end

    confidence =
      [votes.p_unreachable, votes.p_anomalous, votes.p_success]
      |> Enum.max(fn -> 0.0 end)
      |> Kernel.*(coverage_factor)
      |> clamp01()

    %{
      classification: classification,
      confidence: confidence,
      evidence: %{
        votes: votes,
        consensus: %{
          mode: mode,
          threshold: threshold,
          min_agents: min_agents
        },
        per_agent:
          Enum.map(outcomes, fn outcome ->
            normalized = normalize_outcome(outcome, policy)

            %{
              agent_id: normalized.agent_id,
              category: categorize(normalized, policy),
              status: normalized.status,
              target_reached: normalized.target_reached,
              packet_loss_pct: normalized.packet_loss_pct,
              avg_rtt_ms: normalized.avg_rtt_ms,
              path_changed: normalized.path_changed
            }
          end)
      }
    }
  end

  def classify(_, _), do: classify([], %{})

  defp categorize(outcome, policy) do
    cond do
      unreachable?(outcome) ->
        :unreachable

      anomalous?(outcome, policy) ->
        :anomalous

      true ->
        :success
    end
  end

  defp unreachable?(outcome) do
    outcome.target_reached == false or
      outcome.status in ["unreachable", "error", "failed"] or
      (is_binary(outcome.error) and outcome.error != "")
  end

  defp anomalous?(outcome, policy) do
    loss_threshold =
      get_float(
        policy,
        [:anomalous_loss_threshold_pct, "anomalous_loss_threshold_pct"],
        @default_loss_threshold_pct
      )

    rtt_threshold =
      get_float(
        policy,
        [:anomalous_rtt_threshold_ms, "anomalous_rtt_threshold_ms"],
        @default_rtt_threshold_ms
      )

    outcome.path_changed == true or
      outcome.hop_anomaly == true or
      outcome.packet_loss_pct >= loss_threshold or
      outcome.avg_rtt_ms >= rtt_threshold
  end

  defp quorum?(probability_value, "unanimous", _threshold), do: probability_value >= 1.0
  defp quorum?(probability_value, "threshold", threshold), do: probability_value >= threshold
  defp quorum?(probability_value, _mode, _threshold), do: probability_value > 0.5

  defp coverage_factor(cohort_size, min_agents) when min_agents > 0 do
    cohort_size
    |> Kernel./(min_agents)
    |> clamp01()
  end

  defp coverage_factor(_, _), do: 1.0

  defp probability(_numerator, denominator) when denominator <= 0, do: 0.0
  defp probability(numerator, denominator), do: clamp01(numerator / denominator)

  defp normalize_outcome(outcome, policy) when is_map(outcome) do
    %{
      agent_id: normalize_string(get_value(outcome, [:agent_id, "agent_id"])) || "unknown",
      target_reached: normalize_bool(get_value(outcome, [:target_reached, "target_reached"])),
      packet_loss_pct: get_float(outcome, [:packet_loss_pct, "packet_loss_pct"], 0.0),
      avg_rtt_ms: get_float(outcome, [:avg_rtt_ms, "avg_rtt_ms"], 0.0),
      path_changed: normalize_bool(get_value(outcome, [:path_changed, "path_changed"])),
      hop_anomaly: normalize_bool(get_value(outcome, [:hop_anomaly, "hop_anomaly"])),
      error: normalize_string(get_value(outcome, [:error, "error"])),
      status:
        normalize_string(get_value(outcome, [:status, "status"])) ||
          infer_status(get_value(outcome, [:target_reached, "target_reached"]), policy),
      weight: get_float(outcome, [:weight, "weight"], 1.0)
    }
  end

  defp normalize_outcome(_, policy), do: normalize_outcome(%{}, policy)

  defp infer_status(target_reached, _policy) do
    if normalize_bool(target_reached), do: "success", else: "unreachable"
  end

  defp consensus_mode(policy) do
    policy
    |> get_value([:consensus_mode, "consensus_mode"])
    |> normalize_string()
    |> case do
      "unanimous" -> "unanimous"
      "threshold" -> "threshold"
      _ -> @default_consensus_mode
    end
  end

  defp consensus_threshold(policy) do
    policy
    |> get_float([:consensus_threshold, "consensus_threshold"], @default_consensus_threshold)
    |> clamp01()
  end

  defp consensus_min_agents(policy) do
    policy
    |> get_int([:consensus_min_agents, "consensus_min_agents"], @default_consensus_min_agents)
    |> max(1)
  end

  defp get_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_value(_, _), do: nil

  defp get_int(map, keys, default) do
    case get_value(map, keys) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp get_float(map, keys, default) do
    case get_value(map, keys) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_bool(value) when is_boolean(value), do: value
  defp normalize_bool(value) when is_atom(value), do: value in [true, :yes]

  defp normalize_bool(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["true", "1", "yes", "on"]
  end

  defp normalize_bool(_), do: false

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_), do: nil

  defp clamp01(value) when value < 0.0, do: 0.0
  defp clamp01(value) when value > 1.0, do: 1.0
  defp clamp01(value), do: value
end
