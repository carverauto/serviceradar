defmodule ServiceRadarCoreElx.CameraRecording.RecorderRenewal do
  @moduledoc """
  Whether `ServiceRadarCoreElx.CameraRecording.NVRWorker` skips a due renewal of
  its recorder claim. Times are monotonic milliseconds on the worker's node.

  A renewal's database budget is `min(@call_cap_ms, time left until the capture
  deadline)`, so it falls below the 2 s floor exactly when less than 2 s of the
  capture remain. The chart runs core-elx with a 2 s `DATABASE_QUEUE_TARGET_MS`,
  so a checkout can legitimately queue about that long; a renewal that cannot
  outlast a normal queue wait can only overrun, and an overrun disconnects its
  connection and aborts the stream. Such a renewal is skipped when the lease
  already held outlives the capture deadline plus the worker's teardown: its
  claim release (2 s cleanup timeout) and relay close wait (2 s). When the held
  lease does not cover that, the renewal runs as before.
  """

  @floor_ms 2_000
  @cleanup_timeout_ms 2_000

  def cleanup_timeout_ms, do: @cleanup_timeout_ms
  def teardown_ms, do: 2 * @cleanup_timeout_ms

  @spec skip?(integer(), integer(), integer()) :: boolean()
  def skip?(now, capture_deadline, lease_deadline),
    do: capture_deadline - now < @floor_ms and lease_deadline >= capture_deadline + teardown_ms()
end
