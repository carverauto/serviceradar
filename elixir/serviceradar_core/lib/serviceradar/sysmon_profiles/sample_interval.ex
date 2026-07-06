defmodule ServiceRadar.SysmonProfiles.SampleInterval do
  @moduledoc """
  Parsing and validation for sysmon `sample_interval` duration strings.

  Values are Go-style duration strings (e.g. `"5s"`, `"10s"`, `"500ms"`,
  `"1m30s"`) because the agent-side collector parses them with Go's
  `time.ParseDuration`. The accepted range mirrors the agent collector's own
  clamp bounds (`MinSampleInterval`..`MaxSampleInterval` in
  `go/pkg/sysmon/config.go`) so that an admin-configured interval is honored end
  to end without any silent clamp.

  Few-second sampling (e.g. `"5s"`) is deliberately allowed as a *per-profile
  opt-in*: it raises data volume, so it is never forced as a global default —
  the floor here only rejects nonsensical sub-`50ms` values, matching what the
  agent would otherwise clamp away.
  """

  # Mirror go/pkg/sysmon/config.go: MinSampleInterval (50ms) / MaxSampleInterval (5m).
  @min_ms 50
  @max_ms 5 * 60 * 1000

  @unit_ms %{
    "ns" => 1.0e-6,
    "us" => 1.0e-3,
    "µs" => 1.0e-3,
    "ms" => 1.0,
    "s" => 1_000.0,
    "m" => 60_000.0,
    "h" => 3_600_000.0
  }

  # A single "<number><unit>" component of a Go duration string.
  @component_regex ~r/([0-9]+(?:\.[0-9]+)?)([a-zµ]+)/

  @doc "Minimum accepted interval in milliseconds."
  @spec min_milliseconds() :: non_neg_integer()
  def min_milliseconds, do: @min_ms

  @doc "Maximum accepted interval in milliseconds."
  @spec max_milliseconds() :: non_neg_integer()
  def max_milliseconds, do: @max_ms

  @doc """
  Parses a Go-style duration string into a millisecond total.

  Returns `{:ok, milliseconds}` for a well-formed duration, otherwise
  `{:error, message}`. Bounds are *not* enforced here — see `validate/1`.
  """
  @spec parse(term()) :: {:ok, float()} | {:error, String.t()}
  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, "sample_interval cannot be blank"}
    else
      sum_components(trimmed, value)
    end
  end

  def parse(_value), do: {:error, ~s|sample_interval must be a duration string like "10s"|}

  @doc """
  Validates that a `sample_interval` string is well-formed and within the
  agent-honored range. Returns `:ok` or `{:error, message}`.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(value) do
    case parse(value) do
      {:ok, ms} when ms < @min_ms ->
        {:error, "sample_interval #{inspect(value)} is below the #{@min_ms}ms minimum"}

      {:ok, ms} when ms > @max_ms ->
        {:error, "sample_interval #{inspect(value)} is above the 5m maximum"}

      {:ok, _ms} ->
        :ok

      {:error, _message} = error ->
        error
    end
  end

  defp sum_components(trimmed, original) do
    components = Regex.scan(@component_regex, trimmed)
    reconstructed = Enum.map_join(components, "", fn [whole | _rest] -> whole end)

    if components != [] and reconstructed == trimmed do
      accumulate(components, original)
    else
      {:error, invalid_message(original)}
    end
  end

  defp accumulate(components, original) do
    Enum.reduce_while(components, {:ok, 0.0}, fn [_whole, number, unit], {:ok, acc} ->
      case Map.get(@unit_ms, unit) do
        nil -> {:halt, {:error, invalid_message(original)}}
        factor -> {:cont, {:ok, acc + to_number(number) * factor}}
      end
    end)
  end

  defp to_number(number) do
    case Float.parse(number) do
      {value, ""} -> value
      _ -> 0.0
    end
  end

  defp invalid_message(value) do
    ~s|sample_interval #{inspect(value)} is not a valid duration (use e.g. "5s", "10s", "500ms", "1m")|
  end
end
