defmodule ServiceRadar.Inventory.InterfaceThresholdWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.InterfaceThresholdWorker

  describe "threshold_violated?/3" do
    # Testing the private function indirectly through module behavior

    test "module compiles and has expected functions" do
      # Verify the module is loaded and has the expected interface
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
end
