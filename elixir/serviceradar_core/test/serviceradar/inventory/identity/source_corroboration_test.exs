defmodule ServiceRadar.Inventory.Identity.SourceCorroborationTest do
  @moduledoc """
  Unit coverage for the evidence rules that link a source's later observation to an earlier one
  (change `add-source-id-succession`, design D3 and D6): which MACs count as hardware, how
  hostnames and source times are normalized, and when two observations corroborate each other.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.SourceCorroboration

  describe "hardware_macs/1" do
    test "keeps universally administered unicast MACs, normalized" do
      assert SourceCorroboration.hardware_macs(["00:00:5e:00:53:01", "00-00-5E-00-53-02"]) ==
               MapSet.new(["00005E005301", "00005E005302"])
    end

    # A group address is universally administered, so the universal filter alone keeps it.
    test "drops a multicast MAC, which names no single interface" do
      assert SourceCorroboration.hardware_macs(["01:00:5e:90:10:01", "00:00:5e:00:53:01"]) ==
               MapSet.new(["00005E005301"])
    end

    test "drops locally administered, all-zero, broadcast and malformed values" do
      assert SourceCorroboration.hardware_macs([
               "02:00:5e:00:53:01",
               "00:00:00:00:00:00",
               "ff:ff:ff:ff:ff:ff",
               "not-a-mac"
             ]) == MapSet.new()
    end

    test "accepts a bare string, a list holding nil, and nil" do
      assert SourceCorroboration.hardware_macs("00:00:5e:00:53:01") ==
               MapSet.new(["00005E005301"])

      assert SourceCorroboration.hardware_macs([nil, "00:00:5e:00:53:01"]) ==
               MapSet.new(["00005E005301"])

      assert SourceCorroboration.hardware_macs(nil) == MapSet.new()
    end
  end

  describe "normalize_hostname/1" do
    test "lower-cases and trims, and drops a trailing dot" do
      assert SourceCorroboration.normalize_hostname(" Host01.Example.COM. ") ==
               "host01.example.com"
    end

    test "a blank hostname, or no hostname, is nil" do
      for blank <- ["", "   ", "."],
          do: assert(SourceCorroboration.normalize_hostname(blank) == nil)

      assert SourceCorroboration.normalize_hostname(nil) == nil
      assert SourceCorroboration.normalize_hostname(42) == nil
    end
  end

  describe "parse_time/1" do
    test "reads a DateTime, a NaiveDateTime and ISO 8601 strings at whole seconds, in UTC" do
      expected = ~U[2026-01-02 03:04:05Z]

      assert SourceCorroboration.parse_time(~U[2026-01-02 03:04:05.678901Z]) == expected
      assert SourceCorroboration.parse_time(~N[2026-01-02 03:04:05.678]) == expected
      assert SourceCorroboration.parse_time("2026-01-02T03:04:05.678Z") == expected
      assert SourceCorroboration.parse_time("2026-01-02T05:04:05+02:00") == expected
      assert SourceCorroboration.parse_time("2026-01-02T03:04:05") == expected
    end

    test "anything else is nil" do
      for value <- ["not a time", "", nil, 42, %{}],
          do: assert(SourceCorroboration.parse_time(value) == nil)
    end
  end

  describe "corroboration/2" do
    test "the same first-seen time corroborates alone" do
      earlier = observation("2026-01-01T00:00:00Z", "2026-03-01T00:00:00Z", ["host01"])
      later = observation("2026-01-01T00:00:00Z", nil, ["host02"])

      assert SourceCorroboration.corroboration(earlier, later) == {:ok, :first_seen}
    end

    # The source reports whole seconds, so a stored time with sub-second digits still agrees.
    test "first-seen times agree at the source's precision" do
      earlier = %{first_seen: ~U[2026-01-01 00:00:00.250000Z]}
      later = %{first_seen: "2026-01-01T00:00:00Z"}

      assert SourceCorroboration.corroboration(earlier, later) == {:ok, :first_seen}
    end

    test "two missing first-seen times do not agree" do
      assert SourceCorroboration.corroboration(%{}, %{}) == :error
      assert SourceCorroboration.corroboration(%{first_seen: nil}, %{first_seen: nil}) == :error
    end

    test "a shared hostname corroborates when the later one was first seen after the earlier one was last seen" do
      earlier = observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["host01"])
      later = observation("2026-02-02T00:00:00Z", nil, ["host01"])

      assert SourceCorroboration.corroboration(earlier, later) == {:ok, :hostname}
    end

    test "a later first-seen time equal to the earlier last-seen time passes the guard" do
      earlier = observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["host01"])
      later = observation("2026-02-01T00:00:00Z", nil, ["host01"])

      assert SourceCorroboration.corroboration(earlier, later) == {:ok, :hostname}
    end

    # Cloned machines share a hostname while both are in the source.
    test "a shared hostname first seen while the earlier one was still seen does not corroborate" do
      earlier = observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["host01"])
      later = observation("2026-01-31T23:59:59Z", nil, ["host01"])

      assert SourceCorroboration.corroboration(earlier, later) == :error
    end

    test "a missing time fails the guard" do
      earlier = observation("2026-01-01T00:00:00Z", nil, ["host01"])
      later = observation("2026-02-02T00:00:00Z", nil, ["host01"])
      assert SourceCorroboration.corroboration(earlier, later) == :error

      earlier = observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["host01"])
      later = observation(nil, nil, ["host01"])
      assert SourceCorroboration.corroboration(earlier, later) == :error
    end

    test "hostnames are compared normalized, and any shared one counts" do
      earlier =
        observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["Host01.Example.com."])

      later = observation("2026-02-02T00:00:00Z", nil, [nil, "host02", "host01.example.com"])

      assert SourceCorroboration.corroboration(earlier, later) == {:ok, :hostname}
    end

    test "blank hostnames are not shared, and different ones do not corroborate" do
      earlier = observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["", nil])
      later = observation("2026-02-02T00:00:00Z", nil, ["  ", nil])
      assert SourceCorroboration.corroboration(earlier, later) == :error

      earlier = observation("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", ["host01"])
      later = observation("2026-02-02T00:00:00Z", nil, ["host02"])
      assert SourceCorroboration.corroboration(earlier, later) == :error
    end
  end

  defp observation(first_seen, last_seen, hostnames),
    do: %{first_seen: first_seen, last_seen: last_seen, hostnames: hostnames}
end
