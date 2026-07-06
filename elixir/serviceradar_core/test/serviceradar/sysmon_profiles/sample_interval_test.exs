defmodule ServiceRadar.SysmonProfiles.SampleIntervalTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SysmonProfiles.SampleInterval

  describe "parse/1" do
    test "parses simple single-unit durations" do
      assert {:ok, 5_000.0} = SampleInterval.parse("5s")
      assert {:ok, 10_000.0} = SampleInterval.parse("10s")
      assert {:ok, 500.0} = SampleInterval.parse("500ms")
      assert {:ok, 60_000.0} = SampleInterval.parse("1m")
    end

    test "parses compound Go durations" do
      assert {:ok, 90_000.0} = SampleInterval.parse("1m30s")
    end

    test "trims surrounding whitespace" do
      assert {:ok, 5_000.0} = SampleInterval.parse("  5s ")
    end

    test "rejects blank, non-string, and malformed values" do
      assert {:error, _} = SampleInterval.parse("")
      assert {:error, _} = SampleInterval.parse("   ")
      assert {:error, _} = SampleInterval.parse(nil)
      assert {:error, _} = SampleInterval.parse(5)
      assert {:error, _} = SampleInterval.parse("5 s")
      assert {:error, _} = SampleInterval.parse("5sec")
      assert {:error, _} = SampleInterval.parse("-5s")
      assert {:error, _} = SampleInterval.parse("fast")
    end
  end

  describe "validate/1" do
    test "accepts few-second sampling (per-profile high-resolution opt-in)" do
      assert :ok = SampleInterval.validate("5s")
      assert :ok = SampleInterval.validate("10s")
      assert :ok = SampleInterval.validate("500ms")
      assert :ok = SampleInterval.validate("30s")
    end

    test "accepts the honored boundaries" do
      assert :ok = SampleInterval.validate("50ms")
      assert :ok = SampleInterval.validate("5m")
    end

    test "rejects sub-minimum intervals below what the agent honors" do
      assert {:error, message} = SampleInterval.validate("10ms")
      assert message =~ "minimum"
    end

    test "rejects intervals above the agent maximum instead of silently clamping" do
      assert {:error, message} = SampleInterval.validate("10m")
      assert message =~ "maximum"
    end

    test "surfaces a helpful message for malformed durations" do
      assert {:error, message} = SampleInterval.validate("every 5 seconds")
      assert message =~ "not a valid duration"
    end
  end
end
