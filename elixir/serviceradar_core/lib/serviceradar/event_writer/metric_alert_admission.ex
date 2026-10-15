defmodule ServiceRadar.EventWriter.MetricAlertAdmission do
  @moduledoc """
  Admits stored metric points to stateful evaluation for enabled metric rules.

  `metrics.>` is the high-rate stream, so each batch is first matched in
  process against the active `signal: metric` rules, which every EventWriter
  process caches for a short TTL. With no enabled metric rule a batch costs a
  cached lookup and no database work; only matching points reach the engine's
  admission transaction, which stays the authoritative eligibility check. A rule
  enabled or edited takes effect within one TTL.

  Each admitted point carries an id derived from its stored identity
  (`timestamp`, `gateway_id`, `series_key`, the key of `timeseries_metrics` in
  CNPG and StarRocks alike). A JetStream redelivery therefore rewrites the same
  stored point and is deduplicated by the engine's replay check rather than
  counted again, which is what lets a refused admission fail the batch.

  Configuration:

      config :serviceradar_core, :metric_alert_rule_cache_ttl_ms, 5_000
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulEvaluationLedger

  require Ash.Query

  @cache_key {__MODULE__, :active_metric_rules}
  @default_rule_cache_ttl_ms 5_000

  @doc """
  Admits the rows matching at least one active metric rule. Returns `:ok` when
  nothing matched, every match was accepted, or alert evaluation is not
  activated; otherwise the engine's error, so the caller fails its batch.
  """
  @spec admit([map()]) :: :ok | {:error, term()}
  def admit(rows) when is_list(rows) do
    case active_metric_rules() do
      [] ->
        :ok

      rules ->
        rows
        |> Enum.filter(fn row -> Enum.any?(rules, &RuleMatcher.rule_matches_metric?(row, &1)) end)
        |> Enum.map(&Map.put(&1, :id, occurrence_id(&1)))
        |> Enum.chunk_every(Inbox.limits().batch_records)
        |> Enum.reduce_while(:ok, fn chunk, :ok ->
          case StatefulEvaluationLedger.evaluate_metrics(chunk) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  # Per process rather than :persistent_term: a refresh every TTL would make
  # each :persistent_term update a node-wide GC scan.
  defp active_metric_rules do
    now = System.monotonic_time(:millisecond)

    case Process.get(@cache_key) do
      {expires_at, rules} when expires_at > now ->
        rules

      _ ->
        rules = load_active_metric_rules()
        Process.put(@cache_key, {now + rule_cache_ttl_ms(), rules})
        rules
    end
  end

  defp load_active_metric_rules do
    StatefulAlertRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(signal == ^:metric)
    |> Ash.read!(actor: SystemActor.system(:metric_alert_admission))
    |> Page.unwrap!()
  end

  defp rule_cache_ttl_ms do
    Application.get_env(
      :serviceradar_core,
      :metric_alert_rule_cache_ttl_ms,
      @default_rule_cache_ttl_ms
    )
  end

  defp occurrence_id(row) do
    <<id::binary-size(16), _rest::binary>> =
      :crypto.hash(
        :sha256,
        Enum.join(
          [
            "metric",
            DateTime.to_iso8601(row.timestamp),
            to_string(row[:gateway_id]),
            to_string(row[:series_key])
          ],
          "|"
        )
      )

    Ecto.UUID.load!(id)
  end
end
