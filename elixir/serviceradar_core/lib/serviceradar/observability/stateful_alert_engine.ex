defmodule ServiceRadar.Observability.StatefulAlertEngine do
  @moduledoc """
  Durable, bounded admission for log, event and metric alert evaluation.

  Success means every eligible rule occurrence was accepted durably; it does not
  promise that alert effects are already visible. The bounded Oban pool evaluates
  each rule in committed order under its database ownership fence. No engine
  process or Horde registration lies on this admission path.

  Callers requiring effects must observe persisted alerts or completion receipts.
  Stale-anomaly maintenance retains its synchronous count by waiting for an
  ordered maintenance receipt, with a bounded timeout.
  """

  alias ServiceRadar.Observability.StatefulAlertEngine.Completion
  alias ServiceRadar.Observability.StatefulAlertEngine.EdgeAnomalyDisposition
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Record

  @maintenance_timeout_ms 20_000

  @spec evaluate_logs([map()]) :: :ok | {:error, term()}
  def evaluate_logs(rows) when is_list(rows), do: admit(:log, rows)

  @spec evaluate_events([map()]) :: :ok | {:error, term()}
  def evaluate_events(events) when is_list(events) do
    admit(:event, Enum.reject(events, &Record.skip_engine_event?/1))
  end

  @spec evaluate_metrics([map()]) :: :ok | {:error, term()}
  def evaluate_metrics(rows) when is_list(rows), do: admit(:metric, rows)

  defp admit(_signal, []), do: :ok

  defp admit(signal, records) do
    case Inbox.admit(signal, records) do
      {:ok, _keys} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Resolves stale groups after previously accepted inputs for the named rule commit."
  @spec resolve_stale_anomalies(String.t(), DateTime.t(), DateTime.t(), MapSet.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def resolve_stale_anomalies(
        rule_name,
        %DateTime{} = cutoff,
        %DateTime{} = now,
        %MapSet{} = live_series_keys \\ MapSet.new()
      )
      when is_binary(rule_name) do
    with {:ok, keys} <- Inbox.admit_maintenance(rule_name, cutoff, now, live_series_keys),
         {:ok, receipts} <- Completion.await(keys, @maintenance_timeout_ms) do
      {:ok, Enum.reduce(receipts, 0, &(&1.resolved_count + &2))}
    end
  end

  @doc false
  defdelegate seasonal_disposition_suppresses_edge_anomaly?(event, rule),
    to: EdgeAnomalyDisposition

  @doc false
  defdelegate seasonal_disposition_action_for_edge_anomaly(event, rule),
    to: EdgeAnomalyDisposition

  @doc false
  defdelegate seasonal_disposition_for_edge_anomaly(event, rule), to: EdgeAnomalyDisposition
  @doc false
  defdelegate tag_edge_anomaly_disposition(event, action, attrs, disposition),
    to: EdgeAnomalyDisposition

  @doc false
  defdelegate seasonal_disposition_action(disposition), to: EdgeAnomalyDisposition
end
