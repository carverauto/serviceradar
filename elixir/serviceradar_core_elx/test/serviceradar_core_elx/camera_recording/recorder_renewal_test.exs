defmodule ServiceRadarCoreElx.CameraRecording.RecorderRenewalTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.RecorderRenewal

  # Monotonic milliseconds; only differences matter.
  @now 1_000_000
  @capture_deadline @now + 1_500

  test "a renewal is skipped only when its budget is under the floor and the held lease covers the capture" do
    # 1.5s left, under a lease that outlives the deadline and the 4s teardown.
    assert RecorderRenewal.skip?(@now, @capture_deadline, @capture_deadline + 4_000)

    # The same lease with 2s or more left: the budget clears the floor.
    refute RecorderRenewal.skip?(@capture_deadline - 2_000, @capture_deadline, @capture_deadline + 4_000)

    # Under the floor, but an owner- or relay-capped lease ends before the
    # teardown does: the renewal runs as before.
    refute RecorderRenewal.skip?(@now, @capture_deadline, @capture_deadline + 3_999)
  end
end
