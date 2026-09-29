defmodule ServiceRadar.SweepJobs.LeaseSchedule do
  @moduledoc """
  The slots of a sweep group's schedule over a stretch of time.

  A group runs on an interval (`"15m"`, `"1h30m"`, `"1d"`) or a cron expression (UTC). Each
  slot has a start and an end: the end of an interval slot is the next start, and the end of
  a cron slot is the next fire. Interval slots start on multiples of the interval counted
  from the Unix epoch, so two passes that look at overlapping stretches of time agree on
  where the slots are and a slot is never planned twice.

  An interval shorter than `min_interval_seconds/0` is refused: it bounds how many slots a
  horizon holds.
  """

  alias Oban.Cron.Expression

  @min_interval_seconds 300

  @unit_seconds %{
    "ns" => 1.0e-9,
    "us" => 1.0e-6,
    "µs" => 1.0e-6,
    "ms" => 1.0e-3,
    "s" => 1,
    "m" => 60,
    "h" => 3_600,
    "d" => 86_400
  }

  @type spec :: {:interval, pos_integer()} | {:cron, term()}
  @type slot :: %{start: DateTime.t(), expires: DateTime.t()}
  @type reason :: :invalid_interval | :interval_too_short | :invalid_cron

  @doc "The shortest interval a lease will schedule."
  @spec min_interval_seconds() :: pos_integer()
  def min_interval_seconds, do: @min_interval_seconds

  @doc "The schedule of a group: its interval, or its cron expression."
  @spec parse(map()) :: {:ok, spec()} | {:error, reason()}
  def parse(%{schedule_type: :cron, cron_expression: cron}) when is_binary(cron) do
    case Expression.parse(cron) do
      {:ok, expression} -> {:ok, {:cron, expression}}
      _ -> {:error, :invalid_cron}
    end
  end

  def parse(%{schedule_type: :cron}), do: {:error, :invalid_cron}
  def parse(%{interval: interval}) when is_binary(interval), do: parse_interval(interval)
  def parse(_group), do: {:error, :invalid_interval}

  @doc """
  The slots that start in `[from, until)`.

  Every fire in the window is returned. The scheduler (M2.0b3b) is responsible
  for bounding density, not this function.
  """
  @spec slots(spec(), DateTime.t(), DateTime.t()) :: [slot()]
  def slots({:interval, seconds}, %DateTime{} = from, %DateTime{} = until) do
    first = ceil_div(ceil_second(from), seconds) * seconds

    first
    |> Stream.iterate(&(&1 + seconds))
    |> Enum.take_while(&(DateTime.compare(DateTime.from_unix!(&1), until) == :lt))
    |> Enum.map(&%{start: DateTime.from_unix!(&1), expires: DateTime.from_unix!(&1 + seconds)})
  end

  def slots({:cron, expression}, %DateTime{} = from, %DateTime{} = until) do
    collect_cron(expression, DateTime.add(from, -1, :microsecond), until, [])
  end

  defp collect_cron(expression, base, until, acc) do
    with %DateTime{} = start <- Expression.next_at(expression, base),
         :lt <- DateTime.compare(start, until),
         %DateTime{} = expires <- Expression.next_at(expression, start) do
      slot = %{
        start: DateTime.truncate(start, :second),
        expires: DateTime.truncate(expires, :second)
      }

      collect_cron(expression, start, until, [slot | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  # `from` rounded up to a whole second, as Unix seconds: a slot never starts before it.
  defp ceil_second(%DateTime{microsecond: {0, _}} = from), do: DateTime.to_unix(from)
  defp ceil_second(%DateTime{} = from), do: DateTime.to_unix(from) + 1

  # Go's time.ParseDuration syntax (`90s`, `1h30m`, `1.5h`) plus `d` for days.
  defp parse_interval(text) do
    trimmed = String.trim(text)
    token = ~r/(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h|d)/u
    tokens = Regex.scan(token, trimmed)

    if tokens == [] or Regex.replace(token, trimmed, "") != "" do
      {:error, :invalid_interval}
    else
      seconds =
        tokens
        |> Enum.map(fn [_all, amount, unit] -> to_number(amount) * @unit_seconds[unit] end)
        |> Enum.sum()
        |> trunc()

      if seconds < @min_interval_seconds,
        do: {:error, :interval_too_short},
        else: {:ok, {:interval, seconds}}
    end
  end

  defp to_number(text) do
    case Integer.parse(text) do
      {integer, ""} -> integer
      _ -> String.to_float(text)
    end
  end
end
