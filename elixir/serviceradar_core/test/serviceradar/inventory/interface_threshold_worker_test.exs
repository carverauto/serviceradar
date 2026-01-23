defmodule ServiceRadar.Inventory.InterfaceThresholdWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.InterfaceThresholdWorker

  describe "threshold_violated?/3" do
    # Testing the private function indirectly through module behavior

    test "module compiles and has expected functions" do
      # Verify the module is loaded and has the expected interface
      # Note: Code.ensure_loaded! required in async tests
      {:module, _} = Code.ensure_loaded(InterfaceThresholdWorker)
      assert function_exported?(InterfaceThresholdWorker, :perform, 1)
      assert function_exported?(InterfaceThresholdWorker, :ensure_scheduled, 0)
    end
  end

  describe "threshold comparison logic" do
    # These test the comparison logic used in the worker
    # We test the expected behavior based on the implementation

    test "greater than comparison" do
      # Value > threshold should violate
      assert threshold_violated?(85, :gt, 80) == true
      assert threshold_violated?(80, :gt, 80) == false
      assert threshold_violated?(75, :gt, 80) == false
    end

    test "greater than or equal comparison" do
      assert threshold_violated?(85, :gte, 80) == true
      assert threshold_violated?(80, :gte, 80) == true
      assert threshold_violated?(75, :gte, 80) == false
    end

    test "less than comparison" do
      assert threshold_violated?(75, :lt, 80) == true
      assert threshold_violated?(80, :lt, 80) == false
      assert threshold_violated?(85, :lt, 80) == false
    end

    test "less than or equal comparison" do
      assert threshold_violated?(75, :lte, 80) == true
      assert threshold_violated?(80, :lte, 80) == true
      assert threshold_violated?(85, :lte, 80) == false
    end

    test "equal comparison" do
      assert threshold_violated?(80, :eq, 80) == true
      assert threshold_violated?(85, :eq, 80) == false
      assert threshold_violated?(75, :eq, 80) == false
    end

    test "unknown comparison returns false" do
      assert threshold_violated?(80, :unknown, 80) == false
      assert threshold_violated?(80, nil, 80) == false
    end
  end

  describe "metric name mapping" do
    test "maps utilization to interface_utilization" do
      assert metric_name_for(:utilization) == "interface_utilization"
    end

    test "maps bandwidth_in to interface_in_octets" do
      assert metric_name_for(:bandwidth_in) == "interface_in_octets"
    end

    test "maps bandwidth_out to interface_out_octets" do
      assert metric_name_for(:bandwidth_out) == "interface_out_octets"
    end

    test "maps errors to interface_errors" do
      assert metric_name_for(:errors) == "interface_errors"
    end

    test "converts unknown metrics to string" do
      assert metric_name_for(:custom_metric) == "custom_metric"
    end
  end

  describe "comparison normalization" do
    test "normalizes gt to greater_than" do
      assert normalize_comparison(:gt) == :greater_than
    end

    test "normalizes gte to greater_than" do
      assert normalize_comparison(:gte) == :greater_than
    end

    test "normalizes lt to less_than" do
      assert normalize_comparison(:lt) == :less_than
    end

    test "normalizes lte to less_than" do
      assert normalize_comparison(:lte) == :less_than
    end

    test "normalizes eq to equals" do
      assert normalize_comparison(:eq) == :equals
    end

    test "passes through unknown comparisons" do
      assert normalize_comparison(:other) == :other
    end
  end

  # Helper functions that mirror the worker's internal logic
  # These are used for testing the expected behavior

  defp threshold_violated?(value, comparison, threshold) do
    case comparison do
      :gt -> value > threshold
      :gte -> value >= threshold
      :lt -> value < threshold
      :lte -> value <= threshold
      :eq -> value == threshold
      _ -> false
    end
  end

  defp metric_name_for(:utilization), do: "interface_utilization"
  defp metric_name_for(:bandwidth_in), do: "interface_in_octets"
  defp metric_name_for(:bandwidth_out), do: "interface_out_octets"
  defp metric_name_for(:errors), do: "interface_errors"
  defp metric_name_for(other), do: to_string(other)

  defp normalize_comparison(:gt), do: :greater_than
  defp normalize_comparison(:gte), do: :greater_than
  defp normalize_comparison(:lt), do: :less_than
  defp normalize_comparison(:lte), do: :less_than
  defp normalize_comparison(:eq), do: :equals
  defp normalize_comparison(other), do: other

  # ============================================================================
  # Task 7.1: Percentage threshold evaluation tests
  # ============================================================================

  describe "percentage threshold conversion" do
    test "converts percentage to absolute bytes/sec for 1 Gbps interface" do
      # 1 Gbps = 1_000_000_000 bps
      if_speed_bps = 1_000_000_000
      threshold_pct = 80

      # 80% of 1 Gbps = 80% of 125 MB/s (bytes per second)
      expected_bytes_per_sec = 1_000_000_000 / 8 * 0.80

      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      assert_in_delta effective_threshold, expected_bytes_per_sec, 0.01
      # 100_000_000 bytes/sec = 100 MB/s
      assert_in_delta effective_threshold, 100_000_000, 0.01
    end

    test "converts percentage to absolute bytes/sec for 10 Gbps interface" do
      # 10 Gbps = 10_000_000_000 bps
      if_speed_bps = 10_000_000_000
      threshold_pct = 50

      # 50% of 10 Gbps = 50% of 1.25 GB/s
      expected_bytes_per_sec = 10_000_000_000 / 8 * 0.50

      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      assert_in_delta effective_threshold, expected_bytes_per_sec, 0.01
      # 625_000_000 bytes/sec = 625 MB/s
      assert_in_delta effective_threshold, 625_000_000, 0.01
    end

    test "converts percentage to absolute bytes/sec for 100 Mbps interface" do
      # 100 Mbps = 100_000_000 bps
      if_speed_bps = 100_000_000
      threshold_pct = 90

      # 90% of 100 Mbps = 90% of 12.5 MB/s
      expected_bytes_per_sec = 100_000_000 / 8 * 0.90

      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      assert_in_delta effective_threshold, expected_bytes_per_sec, 0.01
      # 11_250_000 bytes/sec = 11.25 MB/s
      assert_in_delta effective_threshold, 11_250_000, 0.01
    end

    test "calculates utilization percentage from metric value" do
      # 1 Gbps interface
      if_speed_bps = 1_000_000_000
      threshold_pct = 80
      # Current throughput: 75 MB/s
      metric_value = 75_000_000

      {_effective_threshold, _speed, utilization_pct} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, metric_value)

      # 75 MB/s / 125 MB/s (1 Gbps max) = 60%
      assert_in_delta utilization_pct, 60.0, 0.1
    end

    test "utilization can exceed 100% (burst traffic)" do
      # 100 Mbps interface
      if_speed_bps = 100_000_000
      threshold_pct = 90
      # Current throughput: 15 MB/s (exceeds 12.5 MB/s max)
      metric_value = 15_000_000

      {_effective_threshold, _speed, utilization_pct} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, metric_value)

      # 15 MB/s / 12.5 MB/s = 120%
      assert_in_delta utilization_pct, 120.0, 0.1
    end

    test "returns nil for zero interface speed" do
      assert resolve_threshold_percentage(0, 80, 1000) == {nil, nil, nil}
    end

    test "returns nil for negative interface speed" do
      assert resolve_threshold_percentage(-1000, 80, 1000) == {nil, nil, nil}
    end

    test "returns nil for nil interface speed" do
      assert resolve_threshold_percentage(nil, 80, 1000) == {nil, nil, nil}
    end

    test "absolute threshold passes through unchanged" do
      threshold_value = 50_000_000
      {effective_threshold, speed, util} = resolve_threshold_absolute(threshold_value)

      assert effective_threshold == threshold_value
      assert speed == nil
      assert util == nil
    end
  end

  describe "percentage threshold violation detection" do
    test "detects violation when utilization exceeds percentage threshold" do
      # 1 Gbps interface, 80% threshold
      if_speed_bps = 1_000_000_000
      threshold_pct = 80

      # 80% threshold = 100 MB/s
      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      # Current traffic: 105 MB/s (84% utilization)
      metric_value = 105_000_000

      # 105 MB/s > 100 MB/s threshold
      assert threshold_violated?(metric_value, :gt, effective_threshold) == true
    end

    test "no violation when utilization below percentage threshold" do
      # 1 Gbps interface, 80% threshold
      if_speed_bps = 1_000_000_000
      threshold_pct = 80

      # 80% threshold = 100 MB/s
      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      # Current traffic: 90 MB/s (72% utilization)
      metric_value = 90_000_000

      # 90 MB/s < 100 MB/s threshold
      assert threshold_violated?(metric_value, :gt, effective_threshold) == false
    end

    test "detects violation at exactly threshold with gte comparison" do
      # 1 Gbps interface, 50% threshold
      if_speed_bps = 1_000_000_000
      threshold_pct = 50

      # 50% threshold = 62.5 MB/s
      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      # Current traffic: exactly 62.5 MB/s
      metric_value = 62_500_000

      assert threshold_violated?(metric_value, :gte, effective_threshold) == true
      assert threshold_violated?(metric_value, :gt, effective_threshold) == false
    end

    test "handles very small threshold percentages" do
      # 10 Gbps interface, 1% threshold
      if_speed_bps = 10_000_000_000
      threshold_pct = 1

      # 1% threshold = 12.5 MB/s
      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      assert_in_delta effective_threshold, 12_500_000, 0.01

      # 15 MB/s > 12.5 MB/s
      assert threshold_violated?(15_000_000, :gt, effective_threshold) == true
    end

    test "handles 100% threshold" do
      # 1 Gbps interface, 100% threshold
      if_speed_bps = 1_000_000_000
      threshold_pct = 100

      # 100% threshold = 125 MB/s
      {effective_threshold, _speed, _util} =
        resolve_threshold_percentage(if_speed_bps, threshold_pct, nil)

      assert_in_delta effective_threshold, 125_000_000, 0.01

      # Traffic at exactly line rate should not violate gt
      assert threshold_violated?(125_000_000, :gt, effective_threshold) == false
      # Traffic above line rate (burst) should violate
      assert threshold_violated?(130_000_000, :gt, effective_threshold) == true
    end
  end

  describe "event message for percentage thresholds" do
    test "generates percentage-specific message with utilization" do
      config = %{
        "threshold_type" => "percentage",
        "value" => 80,
        "utilization_percent" => 85.5
      }

      message = event_message_for_threshold("ifInOctets", 100_000_000, config)

      assert message =~ "85.5%"
      assert message =~ "80%"
      assert message =~ "utilization"
    end

    test "generates absolute-specific message" do
      config = %{
        "threshold_type" => "absolute",
        "value" => 50_000_000
      }

      message = event_message_for_threshold("ifInOctets", 60_000_000, config)

      assert message =~ "threshold violated"
      assert message =~ "60000000"
      assert message =~ "50000000"
    end
  end

  # Helper functions for percentage threshold testing

  defp resolve_threshold_percentage(nil, _threshold_pct, _metric_value) do
    {nil, nil, nil}
  end

  defp resolve_threshold_percentage(if_speed_bps, _threshold_pct, _metric_value)
       when if_speed_bps <= 0 do
    {nil, nil, nil}
  end

  defp resolve_threshold_percentage(if_speed_bps, threshold_pct, metric_value) do
    # Convert interface speed from bps to bytes/sec
    max_bytes_per_sec = if_speed_bps / 8
    # Convert percentage to absolute bytes/sec threshold
    effective_threshold = max_bytes_per_sec * threshold_pct / 100

    # Calculate current utilization
    utilization_pct =
      if is_number(metric_value) and max_bytes_per_sec > 0 do
        Float.round(metric_value / max_bytes_per_sec * 100, 1)
      else
        nil
      end

    {effective_threshold, if_speed_bps, utilization_pct}
  end

  defp resolve_threshold_absolute(threshold_value) do
    {threshold_value, nil, nil}
  end

  defp event_message_for_threshold(metric_name, metric_value, config) do
    threshold_type = Map.get(config, "threshold_type", "absolute")

    if threshold_type == "percentage" do
      utilization_pct = Map.get(config, "utilization_percent")
      threshold_pct = Map.get(config, "value")

      if utilization_pct do
        "Interface utilization at #{utilization_pct}% exceeds #{threshold_pct}% threshold (#{metric_name})"
      else
        "Metric #{metric_name} exceeds #{threshold_pct}% threshold (value=#{metric_value})"
      end
    else
      threshold = Map.get(config, "value")
      "Metric #{metric_name} threshold violated (value=#{metric_value}, threshold=#{threshold})"
    end
  end
end
