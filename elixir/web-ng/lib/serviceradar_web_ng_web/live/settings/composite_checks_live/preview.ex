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
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNGWeb.CompositeChecks.Snapshot

  require Ash.Query

  @sample_size 25

  @doc "How many devices a preview evaluates."
  def sample_size, do: @sample_size

  @type row :: %{
          device_uid: String.t(),
          device_ip: String.t() | nil,
          verdict: String.t(),
          status: atom(),
          explanation: String.t() | nil,
          inputs: [Snapshot.view()]
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
      {:ok, summarize(rows, inputs, rules, total, now, addresses(uids, scope))}
    end
  end

  # A uid identifies a device; an address is how an operator recognises one. The
  # evaluation returns uids alone because that is all a verdict needs, so the
  # addresses are fetched here rather than threaded through the engine for a
  # display concern.
  #
  # A failure yields no addresses rather than failing the preview: an operator
  # reading verdicts is not helped by losing them because a name lookup broke.
  defp addresses([], _scope), do: %{}

  defp addresses(uids, scope) do
    Device
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.Query.select([:uid, :ip])
    |> Ash.read(scope: scope, page: [limit: length(uids)])
    |> case do
      {:ok, %{results: devices}} -> Map.new(devices, &{&1.uid, &1.ip})
      {:ok, devices} when is_list(devices) -> Map.new(devices, &{&1.uid, &1.ip})
      {:error, _reason} -> %{}
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

  defp summarize(rows, inputs, rules, total, now, addresses) do
    rules_by_id = Map.new(rules, &{&1.id, &1})
    vantage_keys = inputs |> Enum.filter(&(&1.kind == :vantage_point)) |> Enum.map(& &1.key)

    views = Enum.map(rows, &row_view(&1, inputs, rules_by_id, now, addresses))

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

  defp row_view(row, inputs, rules_by_id, now, addresses) do
    matched = Map.get(rules_by_id, row.matched_rule_id)

    %{
      device_uid: row.device_uid,
      device_ip: Map.get(addresses, row.device_uid),
      verdict: row.verdict,
      status: row.status,
      explanation: matched && matched.verdict_description,
      inputs: Enum.map(inputs, &Snapshot.view(&1, Map.get(row.inputs, &1.key), now))
    }
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
