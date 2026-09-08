defmodule ServiceRadar.Inventory.Discovery.Decoders.TimestampsTest do
  @moduledoc """
  Parity with Go's `time.RFC3339Nano`.

  Every expected value here was produced by the Go translator and captured in
  the discovery golden fixtures, or follows the same `.999999999` format verb.
  The obvious Elixir spelling disagrees with all of them.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Discovery.Decoders.Timestamps

  test "a whole second carries no fractional part at all" do
    # DateTime.to_iso8601/1 on a nanosecond-built DateTime gives
    # "2023-11-14T22:14:20.000000Z" here. Go gives this. The fixtures have this.
    assert Timestamps.rfc3339_nano(1_700_000_060_000_000_000) == "2023-11-14T22:14:20Z"
  end

  test "trailing zeros are stripped rather than padded" do
    assert Timestamps.rfc3339_nano(1_700_000_060_500_000_000) == "2023-11-14T22:14:20.5Z"
    assert Timestamps.rfc3339_nano(1_700_000_060_120_000_000) == "2023-11-14T22:14:20.12Z"
  end

  test "sub-microsecond digits survive" do
    # DateTime carries at most microsecond precision, so the obvious spelling
    # silently drops the last three digits of a real bpf_ktime_get_ns value.
    assert Timestamps.rfc3339_nano(1_700_000_060_123_456_789) ==
             "2023-11-14T22:14:20.123456789Z"
  end

  test "leading zeros inside the fraction are preserved" do
    # 000000001ns. Formatting the integer without padding would give ".1Z",
    # which is a hundred million times larger.
    assert Timestamps.rfc3339_nano(1_700_000_060_000_000_001) ==
             "2023-11-14T22:14:20.000000001Z"
  end

  test "a non-positive or non-integer timestamp is empty, not year 1" do
    # Matches observedAtUnixNano/1: nano <= 0 yields a zero time, which the
    # translator renders as an empty string and then omits the key entirely.
    assert Timestamps.rfc3339_nano(0) == ""
    assert Timestamps.rfc3339_nano(-1) == ""
    assert Timestamps.rfc3339_nano(nil) == ""
    assert Timestamps.rfc3339_nano("1700000060000000000") == ""
  end
end
