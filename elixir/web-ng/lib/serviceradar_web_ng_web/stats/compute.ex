defmodule ServiceRadarWebNGWeb.Stats.Compute do
  @moduledoc """
  Compute derived values from extracted stats.

  These functions calculate percentages, rates, and other derived metrics
  from the raw extracted stats.
  """

  alias ServiceRadarWebNGWeb.Stats.Extract

  @doc """
  Compute error rate from traces summary.

  Returns the percentage of traces that had errors (0.0 to 100.0).
  """
  @spec traces_error_rate(Extract.traces_summary()) :: float()
  def traces_error_rate(%{total: total, errors: errors}) when total > 0 do
    Float.round(errors / total * 100.0, 1)
  end

  def traces_error_rate(_), do: 0.0

  @doc """
  Compute successful trace count from traces summary.
  """
  @spec traces_successful(Extract.traces_summary()) :: non_neg_integer()
  def traces_successful(%{total: total, errors: errors}) do
    max(total - errors, 0)
  end

  def traces_successful(_), do: 0

  @doc """
  Compute severity percentages from logs severity stats.

  Returns a map with percentage for each severity level.
  """
  @spec logs_severity_percentages(Extract.logs_severity()) :: %{
          fatal_pct: float(),
          error_pct: float(),
          warning_pct: float(),
          info_pct: float(),
          debug_pct: float()
        }
  def logs_severity_percentages(%{total: total} = stats) when total > 0 do
    %{
      fatal_pct: Float.round(Map.get(stats, :fatal, 0) / total * 100.0, 1),
      error_pct: Float.round(Map.get(stats, :error, 0) / total * 100.0, 1),
      warning_pct: Float.round(Map.get(stats, :warning, 0) / total * 100.0, 1),
      info_pct: Float.round(Map.get(stats, :info, 0) / total * 100.0, 1),
      debug_pct: Float.round(Map.get(stats, :debug, 0) / total * 100.0, 1)
    }
  end

  def logs_severity_percentages(_) do
    %{fatal_pct: 0.0, error_pct: 0.0, warning_pct: 0.0, info_pct: 0.0, debug_pct: 0.0}
  end

  @doc """
  Check if services availability is healthy (above threshold).

  Default threshold is 95%.
  """
  @spec services_healthy?(Extract.services_availability(), keyword()) :: boolean()
  def services_healthy?(stats, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 95.0)
    Map.get(stats, :availability_pct, 0.0) >= threshold
  end

  @doc """
  Compute change between two stats values.

  Returns :up, :down, or :stable along with the absolute difference.
  """
  @spec compute_change(number(), number()) :: {:up | :down | :stable, number()}
  def compute_change(current, previous) when is_number(current) and is_number(previous) do
    diff = current - previous

    cond do
      diff > 0 -> {:up, abs(diff)}
      diff < 0 -> {:down, abs(diff)}
      true -> {:stable, 0}
    end
  end

  def compute_change(_, _), do: {:stable, 0}

  @doc """
  Compute percentage change between two values.

  Returns the percentage difference (can be negative).
  """
  @spec percentage_change(number(), number()) :: float()
  def percentage_change(current, previous)
      when is_number(current) and is_number(previous) and previous > 0 do
    Float.round((current - previous) / previous * 100.0, 1)
  end

  def percentage_change(_, _), do: 0.0
end
