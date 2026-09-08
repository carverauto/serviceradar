defmodule ServiceRadar.CompositeChecks.EvaluatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.Evaluator

  defp rule(position, match, verdict, status, opts \\ []) do
    %CompositeCheckRule{
      id: "rule-#{position}",
      position: position,
      match: match,
      verdict: verdict,
      status: status,
      catch_all: Keyword.get(opts, :catch_all, false)
    }
  end

  # The isolation table from the design mock, verbatim.
  defp isolation_rules do
    [
      rule(
        0,
        %{"a" => "available", "b" => "blocked", "nac" => true},
        "isolated_verified",
        :healthy
      ),
      rule(
        1,
        %{"a" => "available", "b" => "blocked", "nac" => false},
        "isolated_unenforced",
        :degraded
      ),
      rule(2, %{"a" => "available", "b" => "available"}, "not_isolated", :down),
      rule(3, %{"a" => "blocked", "b" => "blocked"}, "device_unreachable", :degraded),
      rule(4, %{"a" => "blocked", "b" => "available"}, "inverted_reachability", :down),
      rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
    ]
  end

  describe "the isolation decision table" do
    test "isolation observed and config enforced" do
      assert {:ok, %{verdict: "isolated_verified", status: :healthy, matched_rule_id: "rule-0"}} =
               Evaluator.verdict(
                 %{"a" => :available, "b" => :blocked, "nac" => true},
                 isolation_rules()
               )
    end

    test "isolation observed but config not applied" do
      assert {:ok, %{verdict: "isolated_unenforced", status: :degraded}} =
               Evaluator.verdict(
                 %{"a" => :available, "b" => :blocked, "nac" => false},
                 isolation_rules()
               )
    end

    test "reachable from the network that should be fenced off" do
      assert {:ok, %{verdict: "not_isolated", status: :down}} =
               Evaluator.verdict(
                 %{"a" => :available, "b" => :available, "nac" => true},
                 isolation_rules()
               )
    end

    test "nobody can see it, so isolation cannot be proven" do
      assert {:ok, %{verdict: "device_unreachable", status: :degraded}} =
               Evaluator.verdict(
                 %{"a" => :blocked, "b" => :blocked, "nac" => true},
                 isolation_rules()
               )
    end

    test "the wrong network has access and the right one does not" do
      assert {:ok, %{verdict: "inverted_reachability", status: :down}} =
               Evaluator.verdict(
                 %{"a" => :blocked, "b" => :available, "nac" => false},
                 isolation_rules()
               )
    end

    test "an unknown vantage point falls through to the catch-all" do
      assert {:ok, %{verdict: "inconclusive", status: :unknown, matched_rule_id: "rule-1000000"}} =
               Evaluator.verdict(
                 %{"a" => :unknown, "b" => :blocked, "nac" => true},
                 isolation_rules()
               )
    end

    test "a stale nac fact still isolates but cannot confirm enforcement" do
      assert {:ok, %{verdict: "inconclusive"}} =
               Evaluator.verdict(
                 %{"a" => :available, "b" => :blocked, "nac" => :unknown},
                 isolation_rules()
               )
    end

    test "a powered-off device is degraded, never healthy" do
      # The whole point of the liveness witness: unreachable from everywhere
      # must not be counted as compliant.
      {:ok, decision} =
        Evaluator.verdict(%{"a" => :blocked, "b" => :blocked, "nac" => true}, isolation_rules())

      refute decision.status == :healthy
    end
  end

  describe "matching semantics" do
    test "first match wins even when a later rule also matches" do
      rules = [
        rule(0, %{"a" => "available"}, "first", :healthy),
        rule(1, %{"a" => "available"}, "second", :down),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "first"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "an input key absent from the match map is a wildcard" do
      rules = [
        rule(0, %{"a" => "available"}, "matched", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "matched"}} =
               Evaluator.verdict(%{"a" => :available, "b" => :blocked}, rules)
    end

    test "an explicit wildcard string matches any value" do
      rules = [
        rule(0, %{"a" => "*", "b" => "blocked"}, "matched", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "matched"}} =
               Evaluator.verdict(%{"a" => :unknown, "b" => :blocked}, rules)
    end

    test "a list matcher matches any member" do
      rules = [
        rule(0, %{"a" => ["blocked", "unknown"]}, "not_reachable", :degraded),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "not_reachable"}} = Evaluator.verdict(%{"a" => :unknown}, rules)
      assert {:ok, %{verdict: "not_reachable"}} = Evaluator.verdict(%{"a" => :blocked}, rules)
      assert {:ok, %{verdict: "inconclusive"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "booleans match booleans and their string forms" do
      rules = [
        rule(0, %{"nac" => true}, "enforced", :healthy),
        rule(1, %{"nac" => "false"}, "unenforced", :degraded),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "enforced"}} = Evaluator.verdict(%{"nac" => true}, rules)
      assert {:ok, %{verdict: "unenforced"}} = Evaluator.verdict(%{"nac" => false}, rules)
    end

    test "a match on an input that was not resolved does not match" do
      rules = [
        rule(0, %{"missing" => "available"}, "matched", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "inconclusive"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "rules are evaluated in position order regardless of list order" do
      rules = [
        rule(5, %{"a" => "available"}, "later", :down),
        rule(0, %{"a" => "available"}, "earlier", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "earlier"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "errors when no rule matches and there is no catch-all" do
      assert {:error, :no_matching_rule} =
               Evaluator.verdict(%{"a" => :available}, [rule(0, %{"a" => "blocked"}, "x", :down)])
    end

    test "an empty rule list errors rather than inventing a verdict" do
      assert {:error, :no_matching_rule} = Evaluator.verdict(%{"a" => :available}, [])
    end
  end

  describe "totality" do
    test "every combination of input values matches exactly one rule" do
      values = [:available, :blocked, :unknown]
      nac_values = [true, false, :unknown]

      for a <- values, b <- values, nac <- nac_values do
        inputs = %{"a" => a, "b" => b, "nac" => nac}

        assert {:ok, decision} = Evaluator.verdict(inputs, isolation_rules()),
               "no rule matched #{inspect(inputs)}"

        assert is_binary(decision.verdict)
        assert decision.status in [:healthy, :degraded, :down, :unknown]
      end
    end

    test "removing the catch-all makes the table non-total" do
      # Guards the totality claim itself: if this passed with the catch-all
      # removed, the property above would be proving nothing.
      partial = Enum.reject(isolation_rules(), & &1.catch_all)

      assert {:error, :no_matching_rule} =
               Evaluator.verdict(%{"a" => :unknown, "b" => :unknown, "nac" => :unknown}, partial)
    end
  end
end
