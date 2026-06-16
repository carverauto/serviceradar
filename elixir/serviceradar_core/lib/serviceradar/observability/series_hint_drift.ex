defmodule ServiceRadar.Observability.SeriesHintDrift do
  @moduledoc false

  require Logger

  @log_every 10_000

  @spec record(atom(), String.t(), String.t()) :: :ok
  def record(source, hint, series_key)
      when is_atom(source) and is_binary(hint) and is_binary(series_key) do
    :telemetry.execute(
      [:serviceradar, :observability, :series_identity_hint, :mismatch],
      %{count: 1},
      %{source: source}
    )

    maybe_log(source, hint, series_key)
  end

  defp maybe_log(source, hint, series_key) do
    key = {__MODULE__, source}
    count = Process.get(key, 0) + 1
    Process.put(key, count)

    if count == 1 or rem(count, @log_every) == 0 do
      Logger.debug("series_identity_hint disagrees with derived key",
        source: source,
        hint: hint,
        series_key: series_key,
        process_mismatch_count: count
      )
    end

    :ok
  end
end
