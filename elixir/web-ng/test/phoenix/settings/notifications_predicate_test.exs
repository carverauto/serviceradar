defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.PredicateTest do
  @moduledoc """
  The route predicate builder.

  The property that matters most is negative: a field outside the allow-list must
  be refused at save time, because a route naming an unresolvable path saves
  cleanly and then matches nothing, forever, silently.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Notifications.MatchExpression.Evaluator
  alias ServiceRadar.Notifications.MatchExpression.Fields
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Predicate

  @moduletag :db_free

  defp row(field, operator, value) do
    %{"field" => field, "operator" => operator, "value" => value}
  end

  describe "field and operator whitelists" do
    test "the offered fields are exactly the engine's route field set" do
      assert Predicate.field_options() == Fields.route_fields()
      assert Predicate.field_prefixes() == Fields.route_field_prefixes()
    end

    test "the offered operators are exactly the grammar's operators" do
      assert Predicate.operators() == MatchExpression.operators()
    end

    test "a crafted field outside the allow-list is refused" do
      crafted = "alert.definitely_not_a_field"

      assert {:error, {:unknown_field, ^crafted}} =
               Predicate.to_document("all", [row(crafted, "equals", "x")])
    end

    test "a crafted operator outside the grammar is refused" do
      assert {:error, {:unknown_operator, "eval"}} =
               Predicate.to_document("all", [row("alert.severity", "eval", "x")])
    end

    test "a crafted combinator is refused" do
      assert {:error, :invalid_combinator} =
               Predicate.to_document("exec", [row("alert.severity", "equals", "critical")])
    end

    test "refusing a crafted field creates no atom" do
      crafted = "alert.field_#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_field, ^crafted}} =
               Predicate.to_document("all", [row(crafted, "equals", "x")])

      assert_raise ArgumentError, fn -> String.to_existing_atom(crafted) end
    end
  end

  describe "to_document/2" do
    test "an empty builder matches every alert" do
      assert {:ok, %{}} = Predicate.to_document("all", [])
      assert {:ok, %{}} = Predicate.to_document("all", [row("", "equals", "")])
    end

    test "builds a conjunction the grammar accepts" do
      {:ok, document} =
        Predicate.to_document("all", [
          row("alert.severity", "equals", "critical"),
          row("alert.device_uid", "exists", "true")
        ])

      assert %{"all" => [first, second]} = document
      assert first == %{"field" => "alert.severity", "equals" => "critical"}
      assert second == %{"field" => "alert.device_uid", "exists" => true}

      # The document the builder emits must survive the engine's own validator.
      assert :ok = validate(document)
    end

    test "builds a disjunction" do
      {:ok, document} =
        Predicate.to_document("any", [
          row("alert.severity", "equals", "critical"),
          row("alert.severity", "equals", "high")
        ])

      assert %{"any" => [_, _]} = document
      assert :ok = validate(document)
    end

    test "an `in` operand becomes a non-empty list with blanks dropped" do
      {:ok, %{"all" => [predicate]}} =
        Predicate.to_document("all", [row("alert.severity", "in", "critical, , high")])

      assert predicate == %{"field" => "alert.severity", "in" => ["critical", "high"]}
      assert :ok = validate(%{"all" => [predicate]})
    end

    test "numeric and boolean literals are cast so a numeric attribute can match" do
      {:ok, %{"all" => [numeric]}} =
        Predicate.to_document("all", [row("alert.metric_value", "equals", "5")])

      assert numeric == %{"field" => "alert.metric_value", "equals" => 5}

      {:ok, %{"all" => [absent]}} =
        Predicate.to_document("all", [row("alert.device_uid", "exists", "false")])

      assert absent == %{"field" => "alert.device_uid", "exists" => false}
    end

    test "the emitted document is resolvable by the dispatch-time evaluator" do
      {:ok, document} =
        Predicate.to_document("all", [row("alert.severity", "equals", "critical")])

      subject = %{"alert" => %{"severity" => "critical"}}
      assert {:ok, true} = Evaluator.evaluate(document, subject)

      assert {:ok, false} =
               Evaluator.evaluate(document, %{"alert" => %{"severity" => "info"}})
    end

    test "a metadata prefix path is matchable" do
      {:ok, document} =
        Predicate.to_document("all", [row("alert.metadata.incident_id", "equals", "abc")])

      assert :ok = validate(document)
      assert {:ok, true} = Evaluator.evaluate(document, %{"alert" => %{"metadata" => %{"incident_id" => "abc"}}})
    end
  end

  describe "from_document/1" do
    test "round-trips a conjunction" do
      rows = [row("alert.severity", "equals", "critical"), row("alert.status", "equals", "pending")]
      {:ok, document} = Predicate.to_document("all", rows)

      assert {:ok, {"all", ^rows}} = Predicate.from_document(document)
    end

    test "round-trips an `in` list back to comma-separated text" do
      {:ok, document} = Predicate.to_document("any", [row("alert.severity", "in", "critical, high")])

      assert {:ok, {"any", [%{"operator" => "in", "value" => "critical, high"}]}} =
               Predicate.from_document(document)
    end

    test "an empty document is an empty builder" do
      assert {:ok, {"all", []}} = Predicate.from_document(%{})
    end

    test "shorthand form is read back as equals rows" do
      assert {:ok, {"all", [%{"field" => "alert.severity", "operator" => "equals", "value" => "critical"}]}} =
               Predicate.from_document(%{"alert.severity" => "critical"})
    end

    test "a nested document the rows cannot express is reported, not flattened" do
      nested = %{"all" => [%{"any" => [%{"field" => "alert.severity", "equals" => "critical"}]}]}

      assert :unsupported = Predicate.from_document(nested)
      assert :unsupported = Predicate.from_document(%{"not" => %{"field" => "alert.severity", "equals" => "x"}})
    end
  end

  describe "summarize/1" do
    test "an empty document says so" do
      assert Predicate.summarize(%{}) == "matches every alert"
    end

    test "joins rows with the combinator" do
      {:ok, conjunction} =
        Predicate.to_document("all", [
          row("alert.severity", "equals", "critical"),
          row("alert.status", "equals", "pending")
        ])

      assert Predicate.summarize(conjunction) =~ " AND "

      {:ok, disjunction} =
        Predicate.to_document("any", [
          row("alert.severity", "equals", "critical"),
          row("alert.severity", "equals", "high")
        ])

      assert Predicate.summarize(disjunction) =~ " OR "
    end

    test "an unrepresentable document degrades to a label rather than raising" do
      assert Predicate.summarize(%{"not" => %{"field" => "alert.severity", "equals" => "x"}}) ==
               "custom expression"
    end
  end

  # The engine's validator, driven the way the resource drives it.
  defp validate(document) do
    changeset =
      ServiceRadar.Notifications.NotificationRoute
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attribute(:match_expression, document)

    MatchExpression.validate(changeset, [attribute: :match_expression], %{})
  end
end
