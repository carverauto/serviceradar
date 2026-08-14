defmodule ServiceRadar.Notifications.MatchExpression.EvaluatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Notifications.MatchExpression.Evaluator
  alias ServiceRadar.Notifications.MatchExpression.Fields

  # A fully populated routing subject: every path published by
  # MatchExpression.Fields carries a value, plus operator-owned metadata.
  defp alert(overrides) do
    Map.merge(
      %{
        title: "Interface flapping",
        description: "eth0 flapped 12 times",
        severity: :critical,
        status: :pending,
        source_type: :device,
        source_id: "dev-1",
        service_check_id: "chk-1",
        event_id: "evt-1",
        device_uid: "device-abc",
        agent_uid: "agent-1",
        metric_name: "interface.errors",
        metric_value: 90.0,
        threshold_value: 10.0,
        comparison: :greater_than,
        escalation_level: 2,
        tags: ["prod", "network"],
        metadata: %{
          "incident_rule_id" => "rule-1",
          "incident_group_key" => "device_id=abc|severity=high",
          "incident_occurrence_count" => 4
        }
      },
      overrides
    )
  end

  defp subject(overrides \\ %{}), do: %{"alert" => alert(overrides)}

  defp assert_matches(expression, subject) do
    assert Evaluator.evaluate(expression, subject) == {:ok, true}
  end

  defp refute_matches(expression, subject) do
    assert Evaluator.evaluate(expression, subject) == {:ok, false}
  end

  describe "grammar parity" do
    test "publishes exactly the grammar's combinators and operators" do
      assert Enum.sort(Evaluator.combinators()) == Enum.sort(MatchExpression.combinators())
      assert Enum.sort(Evaluator.operators()) == Enum.sort(MatchExpression.operators())
    end

    test "every route field the validator admits resolves against a populated subject" do
      subject = subject()

      for path <- Fields.route_fields() do
        assert {:ok, _value} = Evaluator.resolve(subject, path),
               "#{path} is on the route allow-list but the evaluator cannot resolve it"
      end
    end

    test "every route field is rooted in a published namespace" do
      roots = Fields.route_namespaces()

      for path <- Fields.route_fields() do
        [root | _rest] = String.split(path, ".")
        assert root in roots, "#{path} is rooted at #{root}, which no subject builder supplies"
      end
    end

    test "an allow-listed prefix resolves any non-empty continuation" do
      assert Evaluator.resolve(subject(), "alert.metadata.incident_rule_id") == {:ok, "rule-1"}
      assert Fields.route_field?("alert.metadata.incident_rule_id")
      refute Fields.route_field?("alert.metadata.")
      refute Fields.route_field?("alert.serverity")
    end
  end

  describe "empty and nil documents" do
    test "an empty document matches everything" do
      assert_matches(%{}, subject())
      assert_matches(%{}, %{})
    end

    test "a nil document matches everything" do
      assert_matches(nil, subject())
    end
  end

  describe "equals" do
    test "compares an atom attribute against its text" do
      assert_matches(%{"field" => "alert.severity", "equals" => "critical"}, subject())
      refute_matches(%{"field" => "alert.severity", "equals" => "warning"}, subject())
    end

    test "compares numbers numerically across integer and float" do
      assert_matches(%{"field" => "alert.metric_value", "equals" => 90}, subject())
      assert_matches(%{"field" => "alert.metric_value", "equals" => 90.0}, subject())
      assert_matches(%{"field" => "alert.escalation_level", "equals" => 2.0}, subject())
      refute_matches(%{"field" => "alert.metric_value", "equals" => 91}, subject())
    end

    test "compares a numeric string value against a numeric operand" do
      subject = subject(%{source_id: "42"})
      assert_matches(%{"field" => "alert.source_id", "equals" => 42}, subject)
      refute_matches(%{"field" => "alert.source_id", "equals" => 43}, subject)
    end

    test "compares booleans strictly and never against their text" do
      subject = %{"alert" => %{"enabled" => true}}
      assert_matches(%{"field" => "alert.enabled", "equals" => true}, subject)
      refute_matches(%{"field" => "alert.enabled", "equals" => "true"}, subject)
      refute_matches(%{"field" => "alert.enabled", "equals" => false}, subject)
    end

    test "a resolved nil equals null, a missing path does not" do
      assert_matches(
        %{"field" => "alert.device_uid", "equals" => nil},
        subject(%{device_uid: nil})
      )

      refute_matches(%{"field" => "alert.nope", "equals" => nil}, subject())
    end

    test "an array attribute matches when any element equals the operand" do
      assert_matches(%{"field" => "alert.tags", "equals" => "prod"}, subject())
      assert_matches(%{"field" => "alert.tags", "equals" => "network"}, subject())
      refute_matches(%{"field" => "alert.tags", "equals" => "staging"}, subject())
      refute_matches(%{"field" => "alert.tags", "equals" => "prod"}, subject(%{tags: []}))
    end

    test "an unmatchable value shape never claims a match" do
      refute_matches(%{"field" => "alert.metadata", "equals" => "anything"}, subject())
    end
  end

  describe "in" do
    test "holds when the value is one of the listed scalars" do
      assert_matches(
        %{"field" => "alert.severity", "in" => ["critical", "emergency"]},
        subject()
      )

      refute_matches(%{"field" => "alert.severity", "in" => ["info", "warning"]}, subject())
    end

    test "is existential over an array attribute" do
      assert_matches(%{"field" => "alert.tags", "in" => ["staging", "prod"]}, subject())
      refute_matches(%{"field" => "alert.tags", "in" => ["staging", "dev"]}, subject())
    end

    test "mixes scalar types in one list" do
      assert_matches(%{"field" => "alert.escalation_level", "in" => ["x", 2]}, subject())
    end

    test "is false for a missing path" do
      refute_matches(%{"field" => "alert.nope", "in" => ["a"]}, subject())
    end
  end

  describe "contains" do
    test "is a substring test over the value's text" do
      assert_matches(%{"field" => "alert.title", "contains" => "flapping"}, subject())
      refute_matches(%{"field" => "alert.title", "contains" => "Flapping"}, subject())
    end

    test "accepts a numeric operand" do
      assert_matches(%{"field" => "alert.description", "contains" => 12}, subject())
    end

    test "is existential over an array attribute" do
      assert_matches(%{"field" => "alert.tags", "contains" => "net"}, subject())
      refute_matches(%{"field" => "alert.tags", "contains" => "zzz"}, subject())
    end

    test "reads an atom attribute as its text" do
      assert_matches(%{"field" => "alert.comparison", "contains" => "greater"}, subject())
    end
  end

  describe "exists" do
    test "true holds only for a present, non-nil value" do
      assert_matches(%{"field" => "alert.device_uid", "exists" => true}, subject())

      refute_matches(
        %{"field" => "alert.device_uid", "exists" => true},
        subject(%{device_uid: nil})
      )

      refute_matches(%{"field" => "alert.nope", "exists" => true}, subject())
    end

    test "false holds for both a missing path and a nil value" do
      assert_matches(%{"field" => "alert.nope", "exists" => false}, subject())

      assert_matches(
        %{"field" => "alert.device_uid", "exists" => false},
        subject(%{device_uid: nil})
      )

      refute_matches(%{"field" => "alert.device_uid", "exists" => false}, subject())
    end

    test "an empty array is still present" do
      assert_matches(%{"field" => "alert.tags", "exists" => true}, subject(%{tags: []}))
    end
  end

  describe "matches" do
    test "applies the pattern to the value's text" do
      assert_matches(%{"field" => "alert.title", "matches" => "^Interface"}, subject())
      refute_matches(%{"field" => "alert.title", "matches" => "^Disk"}, subject())
    end

    test "reads an atom attribute as its text" do
      assert_matches(%{"field" => "alert.severity", "matches" => "crit|emerg"}, subject())
    end

    test "is existential over an array attribute" do
      assert_matches(%{"field" => "alert.tags", "matches" => "^net"}, subject())
      refute_matches(%{"field" => "alert.tags", "matches" => "^db"}, subject())
    end

    test "is false for a missing path rather than an error" do
      refute_matches(%{"field" => "alert.nope", "matches" => ".*"}, subject())
    end
  end

  describe "shorthand" do
    test "is implicit equals and conjunctive" do
      assert_matches(%{"alert.severity" => "critical", "alert.status" => "pending"}, subject())
      refute_matches(%{"alert.severity" => "critical", "alert.status" => "resolved"}, subject())
    end

    test "resolves a nested metadata path" do
      assert_matches(%{"alert.metadata.incident_rule_id" => "rule-1"}, subject())
      refute_matches(%{"alert.metadata.incident_rule_id" => "rule-2"}, subject())
    end
  end

  describe "combinators" do
    test "all requires every branch" do
      expression = %{
        "all" => [
          %{"field" => "alert.severity", "equals" => "critical"},
          %{"field" => "alert.tags", "equals" => "prod"}
        ]
      }

      assert_matches(expression, subject())
      refute_matches(expression, subject(%{tags: ["staging"]}))
    end

    test "any requires one branch" do
      expression = %{
        "any" => [
          %{"field" => "alert.severity", "equals" => "info"},
          %{"field" => "alert.severity", "equals" => "critical"}
        ]
      }

      assert_matches(expression, subject())
      refute_matches(expression, subject(%{severity: :warning}))
    end

    test "not inverts" do
      expression = %{"not" => %{"field" => "alert.severity", "equals" => "info"}}

      assert_matches(expression, subject())
      refute_matches(expression, subject(%{severity: :info}))
    end

    test "nests to arbitrary admitted depth" do
      expression = %{
        "all" => [
          %{"field" => "alert.source_type", "equals" => "device"},
          %{
            "any" => [
              %{"field" => "alert.severity", "equals" => "emergency"},
              %{
                "all" => [
                  %{"field" => "alert.severity", "equals" => "critical"},
                  %{"not" => %{"field" => "alert.tags", "equals" => "staging"}}
                ]
              }
            ]
          }
        ]
      }

      assert_matches(expression, subject())
      refute_matches(expression, subject(%{tags: ["staging"]}))
      refute_matches(expression, subject(%{severity: :warning}))
    end
  end

  describe "atom-keyed documents" do
    test "are normalised the same way the validator normalises them" do
      assert_matches(%{field: "alert.severity", equals: "critical"}, subject())
      assert_matches(%{all: [%{field: "alert.severity", equals: "critical"}]}, subject())
    end
  end

  describe "malformed documents are typed errors, never crashes" do
    test "an unknown operator is reported" do
      assert {:error, message} =
               Evaluator.evaluate(
                 %{"field" => "alert.severity", "equalz" => "critical"},
                 subject()
               )

      assert message =~ "unknown operator"
    end

    test "two operators on one predicate are reported" do
      assert {:error, message} =
               Evaluator.evaluate(
                 %{"field" => "alert.severity", "equals" => "critical", "contains" => "crit"},
                 subject()
               )

      assert message =~ "exactly one operator"
    end

    test "a predicate with no operator is reported rather than treated as a presence test" do
      assert {:error, message} = Evaluator.evaluate(%{"field" => "alert.severity"}, subject())
      assert message =~ "exactly one operator"
    end

    test "a combinator with a sibling key is reported" do
      assert {:error, message} =
               Evaluator.evaluate(
                 %{"all" => [%{}], "field" => "alert.severity"},
                 subject()
               )

      assert message =~ "must be the only key"
    end

    test "an empty combinator branch list is reported" do
      assert {:error, message} = Evaluator.evaluate(%{"any" => []}, subject())
      assert message =~ "at least one expression"
    end

    test "a non-object expression is reported" do
      assert {:error, message} = Evaluator.evaluate("alert.severity == critical", subject())
      assert message =~ "expected an object"
    end

    test "an unparsable pattern is reported" do
      assert {:error, message} =
               Evaluator.evaluate(%{"field" => "alert.title", "matches" => "("}, subject())

      assert message =~ "invalid pattern"
    end

    test "a bad operand type is reported" do
      assert {:error, message} =
               Evaluator.evaluate(%{"field" => "alert.severity", "in" => "critical"}, subject())

      assert message =~ "list of values"
    end

    test "a non-map subject is reported" do
      assert {:error, message} = Evaluator.evaluate(%{}, "not a map")
      assert message =~ "must be a map"
    end
  end

  describe "validate: false" do
    test "evaluates a well-formed document identically" do
      expression = %{"field" => "alert.severity", "equals" => "critical"}

      assert Evaluator.evaluate(expression, subject(), validate: false) ==
               Evaluator.evaluate(expression, subject())
    end

    test "answers false for a malformed document rather than raising" do
      assert Evaluator.evaluate(
               %{"field" => "alert.severity", "equalz" => "critical"},
               subject(),
               validate: false
             ) == {:ok, false}
    end
  end

  describe "resolve/2" do
    test "distinguishes a resolved nil from a missing path" do
      assert Evaluator.resolve(subject(%{device_uid: nil}), "alert.device_uid") == {:ok, nil}
      assert Evaluator.resolve(subject(), "alert.nope") == :missing
      assert Evaluator.resolve(subject(), "nope.nope") == :missing
    end

    test "stops at a non-map leaf instead of raising" do
      assert Evaluator.resolve(subject(), "alert.title.length") == :missing
    end

    test "reads string keys, atom keys, and structs" do
      assert Evaluator.resolve(%{"alert" => %{"severity" => "critical"}}, "alert.severity") ==
               {:ok, "critical"}

      assert Evaluator.resolve(%{alert: %{severity: :critical}}, "alert.severity") ==
               {:ok, :critical}

      assert Evaluator.resolve(%{"at" => ~U[2026-08-09 12:00:00Z]}, "at.year") == {:ok, 2026}
    end

    test "prefers a string key over an atom key of the same name" do
      subject = %{"alert" => %{"severity" => "string-wins", :severity => :atom_loses}}
      assert Evaluator.resolve(subject, "alert.severity") == {:ok, "string-wins"}
    end

    test "returns :missing for a non-binary path" do
      assert Evaluator.resolve(subject(), :"alert.severity") == :missing
    end
  end

  describe "determinism" do
    test "the same inputs always produce the same answer" do
      expression = %{
        "all" => [
          %{"field" => "alert.severity", "in" => ["critical", "emergency"]},
          %{"field" => "alert.tags", "matches" => "^pro"}
        ]
      }

      answers = for _repeat <- 1..25, do: Evaluator.evaluate(expression, subject())
      assert Enum.uniq(answers) == [{:ok, true}]
    end
  end
end
