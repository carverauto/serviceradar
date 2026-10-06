defmodule ServiceRadar.Observability.StatefulAlertEngine.RuntimeMetrics do
  @moduledoc """
  Bounded alert evaluation observations through the shared JetStream publisher.

  Labels are a closed set of input types and failure classes. Rule identities,
  source identities and payloads never become labels. Durable control rows are
  read for health; telemetry itself is published to JetStream, never a database.
  """

  alias ServiceRadar.Ingestion.RuntimeMetrics, as: Publisher
  alias ServiceRadar.Repo

  def admission(signal, result, started) do
    lane = lane(signal)
    Publisher.record(lane, :admission, %{acknowledgement_ms: elapsed(started)})

    case result do
      {:ok, keys} when keys != [] -> Publisher.record(lane, :admitted, %{count: length(keys)})
      {:ok, []} -> :ok
      {:error, reason} -> Publisher.record(lane, :rejected, %{reason: rejection(reason)})
    end
  end

  def completion(disposition, measurements) do
    lane = lane(measurements.signal)
    Publisher.record(lane, :execution, Map.take(measurements, [:execution_ms, :queue_wait_ms]))

    event =
      case disposition do
        :completed -> :completion
        :cancelled -> :cancellation
        :failed -> :failed
      end

    Publisher.record(lane, event, %{})
  end

  def retry, do: Publisher.record(:alert_maintenance, :retry, %{})

  def store_failure,
    do: Publisher.record(:alert_maintenance, :rejected, %{reason: :store_unavailable})

  def sample_health do
    with {:ok, %{rows: rows}} <-
           Repo.query("""
           SELECT signal, count(*), coalesce(sum(payload_bytes), 0)::bigint,
                  greatest(extract(epoch FROM (timezone('utc', now()) - min(accepted_at))) * 1000, 0)::bigint,
                  count(*) FILTER (WHERE attempts > 0)
           FROM platform.alert_evaluation_work GROUP BY signal
           """),
         {:ok, %{rows: [[failed]]}} <-
           Repo.query("""
           SELECT count(*) FROM platform.alert_evaluation_receipts
           WHERE disposition = 'failed' AND completed_at >= timezone('utc', now()) - interval '1 hour'
           """) do
      sampled =
        Map.new(rows, fn [signal, count, bytes, age, retrying] ->
          {signal,
           %{
             pending_count: count,
             pending_bytes: bytes,
             oldest_pending_ms: age,
             retrying_count: retrying
           }}
        end)

      Enum.each([:log, :event, :metric, :maintenance], fn signal ->
        measurements =
          Map.get(sampled, Atom.to_string(signal), %{
            pending_count: 0,
            pending_bytes: 0,
            oldest_pending_ms: 0,
            retrying_count: 0
          })

        Publisher.record(lane(signal), :state, measurements)
      end)

      Publisher.record(:alert_maintenance, :state, %{failed_count: failed})
      :ok
    else
      {:error, _} = error ->
        store_failure()
        error
    end
  end

  defp lane(:log), do: :alert_log
  defp lane(:event), do: :alert_event
  defp lane(:metric), do: :alert_metric
  defp lane(_maintenance), do: :alert_maintenance

  defp rejection({:overloaded, dimension}) when dimension in [:pending_bytes, :rule_bytes],
    do: :configured_byte_full

  defp rejection({:overloaded, :rule_inventory}), do: :rule_inventory_full
  defp rejection({:overloaded, _dimension}), do: :count_full
  defp rejection({:invalid_payload, _}), do: :malformed_payload
  defp rejection(:invalid_payload), do: :malformed_payload
  defp rejection(_store_error), do: :store_unavailable

  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
