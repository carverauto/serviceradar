defmodule ServiceRadar.Backoff do
  @moduledoc """
  Exponential backoff helper with optional jitter.

  Stores the current delay and returns a jittered delay plus updated state.
  """

  @type t :: %{
          base_ms: pos_integer(),
          max_ms: pos_integer(),
          factor: float(),
          jitter: float(),
          current_ms: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_ms = Keyword.get(opts, :base_ms, 1_000)
    max_ms = Keyword.get(opts, :max_ms, 30_000)
    factor = Keyword.get(opts, :factor, 2.0)
    jitter = Keyword.get(opts, :jitter, 0.2)

    %{
      base_ms: base_ms,
      max_ms: max_ms,
      factor: factor,
      jitter: jitter,
      current_ms: base_ms
    }
  end

  @spec reset(t()) :: t()
  def reset(%{base_ms: base_ms} = backoff) do
    %{backoff | current_ms: base_ms}
  end

  @spec next(t()) :: {pos_integer(), t()}
  def next(%{current_ms: current_ms, max_ms: max_ms, factor: factor, jitter: jitter} = backoff) do
    delay_ms = jittered_delay(current_ms, jitter)
    next_ms = current_ms |> round() |> Kernel.*(factor) |> round() |> min(max_ms)
    {delay_ms, %{backoff | current_ms: next_ms}}
  end

  defp jittered_delay(current_ms, jitter) when jitter <= 0 do
    current_ms
  end

  defp jittered_delay(current_ms, jitter) do
    offset = trunc(current_ms * jitter)
    min_ms = max(current_ms - offset, 0)
    max_ms = current_ms + offset

    if max_ms <= min_ms do
      current_ms
    else
      min_ms + :rand.uniform(max_ms - min_ms + 1) - 1
    end
  end
end
