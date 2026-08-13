defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Preview do
  @moduledoc """
  Runs a composite check over a sample of its scope without persisting anything.

  The preview calls `Evaluation.evaluate_devices/5` — the same function the
  scheduled pass calls per page — rather than reimplementing resolution and
  matching. That is the whole point: a preview that agreed with production only
  by construction would drift the first time a resolver changed, and an operator
  would enable a check based on a verdict the engine never produces.

  Nothing here writes. `evaluate_devices/5` persists nothing by construction,
  and no verdict events are emitted because none are generated.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.Scope

  @sample_size 25

  @doc "How many devices a preview evaluates."
  def sample_size, do: @sample_size

  @type input_view :: %{
          key: String.t(),
          label: String.t(),
          kind: atom(),
          expected: String.t() | nil,
          value: String.t(),
          observed_at: DateTime.t() | nil,
          age: String.t(),
          stale: boolean(),
          reason: String.t() | nil
        }

  @type row :: %{
          device_uid: String.t(),
          verdict: String.t(),
          status: atom(),
          explanation: String.t() | nil,
          inputs: [input_view()]
        }

  @type result :: %{
          rows: [row()],
          sampled: non_neg_integer(),
          total: non_neg_integer() | nil,
          unreachable: non_neg_integer(),
          verdicts: [%{verdict: String.t(), status: atom(), count: non_neg_integer()}]
        }

  @doc """
  Evaluates up to `:sample_size` devices from the check's scope.

  `:total` is passed in rather than counted here: the builder already knows the
  scope size from the count it renders beside the SRQL, and counting again would
  walk the whole population to display a number already on screen.
  """
  @spec run(struct(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def run(check, opts) do
    scope = Keyword.fetch!(opts, :scope)
    sample_size = Keyword.get(opts, :sample_size, @sample_size)
    total = Keyword.get(opts, :total)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- normalize(check),
         {:ok, inputs} <- list(CompositeCheckInput, check, scope),
         {:ok, rules} <- list(CompositeCheckRule, check, scope),
         {:ok, uids} <- sample_uids(normalized, sample_size),
         {:ok, rows} <- Evaluation.evaluate_devices(check, inputs, rules, uids, now: now) do
      {:ok, summarize(rows, inputs, rules, total, now)}
    end
  end

  defp normalize(check) do
    case Scope.normalize(check.scope_query) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :scope_must_target_devices} -> {:error, "The scope must target devices"}
    end
  end

  defp list(resource, check, scope) do
    case resource.list_by_check(check.id, scope: scope) do
      {:ok, records} -> {:ok, records}
      {:error, _reason} -> {:error, "Could not load the check's inputs and rules"}
    end
  end

  # `Scope.stream_uids/2` raises on a runner error, which is right for the
  # evaluation pass — a partial pass must not sweep. A preview has nothing to
  # corrupt, so the failure becomes a message the operator can act on.
  defp sample_uids(normalized, sample_size) do
    uids =
      normalized
      |> Scope.stream_uids(page_limit: sample_size)
      |> Enum.take(1)
      |> List.flatten()

    {:ok, Enum.take(uids, sample_size)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp summarize(rows, inputs, rules, total, now) do
    rules_by_id = Map.new(rules, &{&1.id, &1})
    vantage_keys = inputs |> Enum.filter(&(&1.kind == :vantage_point)) |> Enum.map(& &1.key)

    views = Enum.map(rows, &row_view(&1, inputs, rules_by_id, now))

    %{
      rows: views,
      sampled: length(views),
      total: total,
      unreachable: Enum.count(rows, &unreachable?(&1, vantage_keys)),
      verdicts: verdict_counts(views)
    }
  end

  # A device no vantage point can see. Its verdict is whatever the rules say,
  # but it cannot be counted as evidence of isolation either way, which is why
  # the population is surfaced separately from the verdict rollup.
  #
  # A check with no vantage points has no unreachable population, rather than
  # every device being trivially unreachable.
  defp unreachable?(_row, []), do: false

  defp unreachable?(row, vantage_keys) do
    Enum.all?(vantage_keys, fn key ->
      case get_in(row.inputs, [key, "value"]) do
        "available" -> false
        _other -> true
      end
    end)
  end

  defp row_view(row, inputs, rules_by_id, now) do
    matched = Map.get(rules_by_id, row.matched_rule_id)

    %{
      device_uid: row.device_uid,
      verdict: row.verdict,
      status: row.status,
      explanation: matched && matched.verdict_description,
      inputs: Enum.map(inputs, &input_view(&1, Map.get(row.inputs, &1.key), now))
    }
  end

  defp input_view(input, snapshot, now) do
    observed_at = parse_observed_at(snapshot)

    %{
      key: input.key,
      label: input.label || input.key,
      kind: input.kind,
      expected: input.expected,
      value: snapshot_value(snapshot),
      observed_at: observed_at,
      age: age(observed_at, now),
      stale: snapshot && Map.get(snapshot, "stale") == true,
      reason: snapshot && Map.get(snapshot, "reason")
    }
  end

  # An input with no snapshot is `unknown`, not blank. A blank cell reads as
  # "nothing to say"; `unknown` with its reason is the actual state, and it is
  # the state that keeps a check from being enabled.
  defp snapshot_value(nil), do: "unknown"

  defp snapshot_value(snapshot) do
    case Map.get(snapshot, "value") do
      value when is_binary(value) and value != "" -> value
      _other -> "unknown"
    end
  end

  defp parse_observed_at(nil), do: nil

  defp parse_observed_at(snapshot) do
    case Map.get(snapshot, "observed_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _error -> nil
        end

      _other ->
        nil
    end
  end

  # Ages are measured against the evaluation's own `now`, not the wall clock, so
  # the rendered age and the resolver's staleness verdict cannot disagree.
  defp age(nil, _now), do: "never"

  defp age(observed_at, now) do
    case DateTime.diff(now, observed_at, :second) do
      seconds when seconds < 0 -> "just now"
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp verdict_counts(views) do
    views
    |> Enum.group_by(&{&1.verdict, &1.status})
    |> Enum.map(fn {{verdict, status}, group} ->
      %{verdict: verdict, status: status, count: length(group)}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end
end
