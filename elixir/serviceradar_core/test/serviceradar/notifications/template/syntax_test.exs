defmodule ServiceRadar.Notifications.Template.SyntaxTest do
  @moduledoc """
  The Ash validation half of the restricted-substitution validator.

  `validate_template/1` is exercised throughout the renderer and template-seeder
  suites. What is asserted here is the part that only shows up once a template is
  written to a row: `atomic/3`, the callback an action with `require_atomic? true`
  runs instead of `validate/3`.

  It is worth its own file because getting it wrong is invisible in exactly the
  wrong direction. Reading `changeset.atomics` and refusing anything found there
  made every literal template edit look like an expression-valued one, which
  turned `NotificationTemplate`'s `:update` and `:reconcile_managed` into actions
  that could never succeed - an operator could not edit a template and the seeder
  could not reconcile one - while every database-free test still passed, because
  nothing pure ever writes a row.

  No database: `Ash.Changeset.fully_atomic_changeset/4` is the same function
  `Ash.Actions.Update.run/4` calls, and it needs no connection.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.NotificationTemplate

  require Ash.Expr

  @valid "Device {{ device.name | default: \"unknown\" }} needs attention."
  @unknown_path "Device {{ device.telepathy }} needs attention."

  defp record(overrides \\ %{}) do
    struct(
      %NotificationTemplate{
        id: "0198f0aa-1111-7000-8000-000000000001",
        name: "Default alert (plain text)",
        alert_class: "default",
        payload_format: :plain,
        provider_key: nil,
        subject_template: "{{ alert.title }}",
        body_template: "{{ alert.message }}",
        managed: true,
        template_version: "1",
        template_fingerprint: "abc"
      },
      overrides
    )
  end

  # Exactly what `Ash.Actions.Update.run/4` does for an action with
  # `require_atomic? true`: rebuild the changeset atomically from its parameters.
  defp atomic_changeset(action, params) do
    data = record()
    changeset = Ash.Changeset.for_update(data, action, params)

    Ash.Changeset.fully_atomic_changeset(NotificationTemplate, action, changeset.params,
      data: data,
      assume_casted?: true,
      atomics: Keyword.merge(changeset.atomic_changes, Keyword.new(changeset.attribute_changes))
    )
  end

  describe "atomic/3 on a literal update" do
    test "a valid body is accepted, so the action stays atomic" do
      assert %Ash.Changeset{valid?: true} =
               atomic_changeset(:reconcile_managed, %{body_template: @valid})
    end

    test "a valid subject is accepted" do
      assert %Ash.Changeset{valid?: true} =
               atomic_changeset(:reconcile_managed, %{subject_template: @valid})
    end

    test "the operator edit action is atomic too" do
      assert %Ash.Changeset{valid?: true} = atomic_changeset(:update, %{body_template: @valid})
    end

    test "an unknown variable path is still refused" do
      # The whole point of validating at save time. A path outside the catalog
      # renders as an empty string, and the first time anyone finds out is during
      # an incident.
      assert %Ash.Changeset{valid?: false} =
               changeset = atomic_changeset(:update, %{body_template: @unknown_path})

      assert Enum.any?(changeset.errors, &(Map.get(&1, :field) == :body_template))
    end

    test "an unknown filter is still refused" do
      assert %Ash.Changeset{valid?: false} =
               atomic_changeset(:update, %{body_template: "{{ alert.title | shout }}"})
    end

    test "a code construct is still refused" do
      assert %Ash.Changeset{valid?: false} =
               atomic_changeset(:update, %{body_template: "<%= alert.title %>"})
    end

    test "an update that does not touch a template attribute passes" do
      assert %Ash.Changeset{valid?: true} =
               atomic_changeset(:reconcile_managed, %{template_version: "2"})
    end

    test "string parameter keys are handled, because that is what a form submits" do
      assert %Ash.Changeset{valid?: true} =
               atomic_changeset(:update, %{"body_template" => @valid})

      assert %Ash.Changeset{valid?: false} =
               atomic_changeset(:update, %{"body_template" => @unknown_path})
    end
  end

  describe "atomic/3 on a computed update" do
    test "an expression-valued template attribute is refused rather than let through" do
      # A body computed in SQL is not something a pure validator can inspect, and
      # failing loudly beats persisting an unvalidated template.
      data = record()

      changeset =
        data
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.atomic_update(:body_template, Ash.Expr.expr(subject_template))

      assert {:not_atomic, reason} =
               Ash.Changeset.fully_atomic_changeset(NotificationTemplate, :update, %{},
                 data: data,
                 assume_casted?: true,
                 atomics: changeset.atomics
               )

      assert reason =~ "body_template"
      assert reason =~ "literal value"
    end
  end

  describe "validate/3" do
    test "checks the changed value" do
      changeset = Ash.Changeset.for_update(record(), :update, %{body_template: @unknown_path})

      refute changeset.valid?
    end

    test "accepts a valid value" do
      changeset = Ash.Changeset.for_update(record(), :update, %{body_template: @valid})

      assert changeset.valid?
    end
  end
end
