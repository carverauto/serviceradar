defmodule ServiceRadar.EventWriter.LogSeverityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.LogSeverity

  describe "from_level/1" do
    test "maps numeric syslog levels to OTEL severity text and number" do
      assert LogSeverity.from_level(0) == {"FATAL", 21}
      assert LogSeverity.from_level(1) == {"FATAL", 21}
      assert LogSeverity.from_level(2) == {"FATAL", 21}
      assert LogSeverity.from_level(3) == {"ERROR", 19}
      assert LogSeverity.from_level(4) == {"WARN", 15}
      assert LogSeverity.from_level(5) == {"INFO", 9}
      assert LogSeverity.from_level(6) == {"INFO", 9}
      assert LogSeverity.from_level(7) == {"DEBUG", 5}
    end

    test "coerces stringified numeric levels" do
      assert LogSeverity.from_level("4") == {"WARN", 15}
      assert LogSeverity.from_level("7") == {"DEBUG", 5}
    end

    test "defaults out-of-range numeric levels to INFO" do
      assert LogSeverity.from_level(8) == {"INFO", 9}
    end

    test "falls back to text aliasing for non-numeric levels" do
      assert LogSeverity.from_level("warning") == {"WARN", 15}
      assert LogSeverity.from_level("debug") == {"DEBUG", 7}
      assert LogSeverity.from_level("critical") == {"FATAL", 23}
      assert LogSeverity.from_level("verbose") == {"INFO", 11}
    end
  end
end
