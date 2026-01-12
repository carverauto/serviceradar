defmodule ServiceRadar.SweepJobs.TargetCriteriaTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.TargetCriteria

  describe "tag operators" do
    test "has_any matches tag keys and key=value entries" do
      device = %{tags: %{"env" => "prod", "critical" => ""}}

      assert TargetCriteria.matches?(device, %{"tags" => %{"has_any" => ["critical"]}})
      assert TargetCriteria.matches?(device, %{"tags" => %{"has_any" => ["env=prod"]}})
      refute TargetCriteria.matches?(device, %{"tags" => %{"has_any" => ["env=dev"]}})
    end

    test "has_all requires all tag entries" do
      device = %{tags: %{"env" => "prod", "tier" => "edge"}}

      assert TargetCriteria.matches?(device, %{
               "tags" => %{"has_all" => ["env=prod", "tier=edge"]}
             })

      refute TargetCriteria.matches?(device, %{"tags" => %{"has_all" => ["env=prod", "critical"]}})
    end

    test "tag field selector matches tag value" do
      device = %{tags: %{"env" => "prod"}}
      criteria = %{"tags.env" => %{"eq" => "prod"}}

      assert TargetCriteria.matches?(device, criteria)
      refute TargetCriteria.matches?(device, %{"tags.env" => %{"eq" => "dev"}})
    end
  end

  describe "range and numeric operators" do
    test "in_range matches IPv4 range" do
      device = %{ip: "10.0.1.10"}

      assert TargetCriteria.matches?(device, %{"ip" => %{"in_range" => "10.0.1.1-10.0.1.20"}})
      refute TargetCriteria.matches?(device, %{"ip" => %{"in_range" => "10.0.2.1-10.0.2.20"}})
    end

    test "numeric comparisons respect thresholds" do
      device = %{type_id: 42}

      assert TargetCriteria.matches?(device, %{"type_id" => %{"gt" => 10}})
      assert TargetCriteria.matches?(device, %{"type_id" => %{"gte" => 42}})
      refute TargetCriteria.matches?(device, %{"type_id" => %{"lt" => 10}})
      refute TargetCriteria.matches?(device, %{"type_id" => %{"lte" => 41}})
    end
  end

  describe "null checks" do
    test "is_null and is_not_null evaluate nil values" do
      device = %{hostname: nil}

      assert TargetCriteria.matches?(device, %{"hostname" => %{"is_null" => true}})
      refute TargetCriteria.matches?(device, %{"hostname" => %{"is_null" => false}})
      refute TargetCriteria.matches?(device, %{"hostname" => %{"is_not_null" => true}})
    end
  end

  describe "criteria validation" do
    test "tag operator validation rejects non-tag fields" do
      criteria = %{"hostname" => %{"has_any" => ["critical"]}}

      assert {:error, message} = TargetCriteria.validate(criteria)
      assert String.contains?(message, "does not support")
    end

    test "in_range validates range syntax" do
      assert {:error, message} = TargetCriteria.validate(%{"ip" => %{"in_range" => "10.0.0.1"}})
      assert String.contains?(message, "in_range")
    end
  end

  describe "Ash filter conversion" do
    test "to_ash_filter returns simple predicates" do
      criteria = %{"type_id" => %{"gte" => 10}, "hostname" => %{"eq" => "router"}}

      filters = TargetCriteria.to_ash_filter(criteria)

      assert {:type_id, [gte: 10]} in filters
      assert {:hostname, "router"} in filters
    end

    test "to_ash_filter supports not_in" do
      criteria = %{"type_id" => %{"not_in" => [1, 2]}}

      assert {:not, [{:type_id, [in: [1, 2]]}]} in TargetCriteria.to_ash_filter(criteria)
    end
  end
end
