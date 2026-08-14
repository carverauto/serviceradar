defmodule ServiceRadar.CompositeChecks.Resolvers.VantagePoint do
  @moduledoc """
  Resolves a `:vantage_point` input from a device's latest per-agent
  availability row.

  `:blocked` means *no positive response from any enabled probe from that
  vantage point*. It does NOT mean "provably filtered": per-target
  refused-vs-timeout outcomes are not carried from the scanner into sweep
  results (`go/pkg/scan/tcp_scanner.go` counts `connection refused` only as an
  aggregate `DialResets` statistic), so a firewalled device and a powered-off
  device produce the same row. Distinguishing them is the job of a second
  vantage point that is expected to reach the device — the liveness witness.

  Pure: the caller batch-loads availability rows and passes the matching row (or
  `nil`) in. Nothing here touches the repo, which is what lets an evaluation
  pass resolve a page of devices without an N+1.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  @type value :: :available | :blocked | :unknown
  @type resolution :: %{
          value: value(),
          observed_at: DateTime.t() | nil,
          stale: boolean(),
          reason: nil | :no_result | :stale
        }

  @spec resolve(CompositeCheckInput.t(), DeviceAgentAvailability.t() | nil, DateTime.t()) ::
          resolution()
  def resolve(input, row, now)

  def resolve(%CompositeCheckInput{}, nil, _now) do
    %{value: :unknown, observed_at: nil, stale: false, reason: :no_result}
  end

  def resolve(%CompositeCheckInput{config: config}, %DeviceAgentAvailability{} = row, now) do
    max_age = Map.get(config, "max_age_seconds")

    if stale?(row.checked_at, max_age, now) do
      %{value: :unknown, observed_at: row.checked_at, stale: true, reason: :stale}
    else
      %{
        value: value_for(row.is_available),
        observed_at: row.checked_at,
        stale: false,
        reason: nil
      }
    end
  end

  defp value_for(true), do: :available
  defp value_for(_), do: :blocked

  defp stale?(_checked_at, nil, _now), do: false
  defp stale?(nil, _max_age, _now), do: true

  defp stale?(checked_at, max_age, now) when is_integer(max_age) do
    DateTime.diff(now, checked_at, :second) > max_age
  end
end
