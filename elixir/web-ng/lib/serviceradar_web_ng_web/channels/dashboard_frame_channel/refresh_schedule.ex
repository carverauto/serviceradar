defmodule ServiceRadarWebNGWeb.DashboardFrameChannel.RefreshSchedule do
  @moduledoc """
  Per-frame refresh scheduling for dashboard frame channels.

  A manifest data frame may declare its own `refresh_interval_ms`; frames that do
  not use the package default. Every interval is clamped to one second through
  one minute. The channel ticks at the greatest common divisor of the frame
  intervals (never below one second), so a frame whose deadline falls between
  the ticks of a faster frame still lands on a tick instead of waiting out a
  whole extra fast period. On each periodic tick the channel re-runs only the
  frames whose own interval has elapsed, so a slow frame is not re-queried on
  a fast frame's tick.
  """

  @min_refresh_ms 1_000
  @max_refresh_ms 60_000

  # A tick that lands a few milliseconds before a frame's interval elapses still
  # counts as due; without this slack a 2 s frame on a 2 s tick would skip every
  # other tick.
  @slack_ms 250

  @doc "Clamps an interval to the supported range."
  @spec clamp(integer()) :: pos_integer()
  def clamp(ms) when is_integer(ms), do: ms |> max(@min_refresh_ms) |> min(@max_refresh_ms)

  @doc "The effective refresh interval of one frame."
  @spec frame_interval(map(), pos_integer()) :: pos_integer()
  def frame_interval(frame, default) when is_map(frame) do
    case frame["refresh_interval_ms"] || frame[:refresh_interval_ms] do
      ms when is_integer(ms) -> clamp(ms)
      _other -> default
    end
  end

  @doc "The tick interval: the gcd of the frame intervals, floored at one second, or the default."
  @spec tick_interval([map()], pos_integer()) :: pos_integer()
  def tick_interval(frames, default) when is_list(frames) do
    case Enum.map(frames, &frame_interval(&1, default)) do
      [] -> default
      intervals -> intervals |> Enum.reduce(&Integer.gcd/2) |> max(@min_refresh_ms)
    end
  end

  @doc """
  The frames due for a periodic refresh at `now` (monotonic milliseconds), given
  when each frame id was last refreshed. A frame never refreshed is due.
  """
  @spec due([map()], %{optional(String.t()) => integer()}, integer(), pos_integer(), (map() -> String.t())) ::
          [map()]
  def due(frames, refreshed_at, now, default, frame_id) when is_list(frames) and is_map(refreshed_at) do
    Enum.filter(frames, fn frame ->
      case Map.fetch(refreshed_at, frame_id.(frame)) do
        :error -> true
        {:ok, last} -> now - last + @slack_ms >= frame_interval(frame, default)
      end
    end)
  end
end
