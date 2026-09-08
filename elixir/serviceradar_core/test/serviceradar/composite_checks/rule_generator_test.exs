defmodule ServiceRadar.CompositeChecks.RuleGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.Evaluator
  alias ServiceRadar.CompositeChecks.RuleGenerator

  defp vantage(key, expected) do
    %CompositeCheckInput{
      key: key,
      kind: :vantage_point,
      expected: expected,
      config: %{"agent_id" => key}
    }
  end

  defp fact(key) do
    %CompositeCheckInput{
      key: key,
      kind: :device_metadata,
      config: %{"path" => key, "value_type" => "boolean"}
    }
  end

  # Turn generated attrs into rule structs plus the catch-all every check owns,
  # so generated tables can be run through the real evaluator.
  defp as_rules(attrs_list) do
    generated =
      Enum.map(attrs_list, fn attrs ->
        struct(CompositeCheckRule, Map.put(attrs, :id, "rule-#{attrs.position}"))
      end)

    generated ++
      [
        %CompositeCheckRule{
          id: "catch-all",
          position: 1_000_000,
          match: %{},
          verdict: "inconclusive",
          status: :unknown,
          catch_all: true
        }
      ]
  end

  test "generates the five isolation cases for two vantage points and a fact" do
    inputs = [vantage("a", "available"), vantage("b", "blocked"), fact("nac")]

    verdicts = inputs |> RuleGenerator.generate() |> Enum.map(& &1.verdict)

    assert verdicts == [
             "isolated_verified",
             "isolated_unenforced",
             "not_isolated",
             "device_unreachable",
             "inverted_reachability"
           ]
  end

  test "generated rules classify every observed pattern" do
    rules =
      [vantage("a", "available"), vantage("b", "blocked"), fact("nac")]
      |> RuleGenerator.generate()
      |> as_rules()

    assert {:ok, %{verdict: "isolated_verified", status: :healthy}} =
             Evaluator.verdict(%{"a" => :available, "b" => :blocked, "nac" => true}, rules)

    assert {:ok, %{verdict: "isolated_unenforced", status: :degraded}} =
             Evaluator.verdict(%{"a" => :available, "b" => :blocked, "nac" => false}, rules)

    assert {:ok, %{verdict: "not_isolated", status: :down}} =
             Evaluator.verdict(%{"a" => :available, "b" => :available, "nac" => true}, rules)

    assert {:ok, %{verdict: "device_unreachable", status: :degraded}} =
             Evaluator.verdict(%{"a" => :blocked, "b" => :blocked, "nac" => true}, rules)

    assert {:ok, %{verdict: "inverted_reachability", status: :down}} =
             Evaluator.verdict(%{"a" => :blocked, "b" => :available, "nac" => true}, rules)
  end

  test "a generated table plus its catch-all is total" do
    rules =
      [vantage("a", "available"), vantage("b", "blocked"), fact("nac")]
      |> RuleGenerator.generate()
      |> as_rules()

    for a <- [:available, :blocked, :unknown],
        b <- [:available, :blocked, :unknown],
        nac <- [true, false, :unknown] do
      inputs = %{"a" => a, "b" => b, "nac" => nac}
      assert {:ok, _} = Evaluator.verdict(inputs, rules), "no rule matched #{inspect(inputs)}"
    end
  end

  test "a device nobody can reach is never healthy" do
    rules =
      [vantage("a", "available"), vantage("b", "blocked")]
      |> RuleGenerator.generate()
      |> as_rules()

    {:ok, decision} = Evaluator.verdict(%{"a" => :blocked, "b" => :blocked}, rules)

    refute decision.status == :healthy
  end

  test "omits the fact rows when no metadata input is declared" do
    verdicts =
      [vantage("a", "available"), vantage("b", "blocked")]
      |> RuleGenerator.generate()
      |> Enum.map(& &1.verdict)

    assert verdicts == [
             "isolated_verified",
             "not_isolated",
             "device_unreachable",
             "inverted_reachability"
           ]

    refute "isolated_unenforced" in verdicts
  end

  test "generates nothing without both a witness and a probe" do
    assert RuleGenerator.generate([vantage("a", "available")]) == []
    assert RuleGenerator.generate([vantage("a", "blocked")]) == []
    assert RuleGenerator.generate([vantage("a", "available"), vantage("b", "available")]) == []
    assert RuleGenerator.generate([]) == []
  end

  test "ignores vantage points with no recorded expectation" do
    inputs = [vantage("a", "available"), vantage("b", "blocked"), vantage("c", nil)]

    matches = inputs |> RuleGenerator.generate() |> Enum.map(& &1.match)

    refute Enum.any?(matches, &Map.has_key?(&1, "c"))
  end

  test "positions are sequential and leave room before the catch-all" do
    rules = RuleGenerator.generate([vantage("a", "available"), vantage("b", "blocked")])

    assert Enum.map(rules, & &1.position) == [0, 1, 2, 3]
    assert Enum.all?(rules, &(&1.position < 1_000_000))
  end

  test "every generated rule carries a description and a valid status" do
    rules =
      RuleGenerator.generate([vantage("a", "available"), vantage("b", "blocked"), fact("n")])

    for rule <- rules do
      assert is_binary(rule.verdict_description) and rule.verdict_description != ""
      assert is_binary(rule.verdict_label) and rule.verdict_label != ""
      assert rule.status in [:healthy, :degraded, :down, :unknown]
      assert map_size(rule.match) > 0
    end
  end
end
