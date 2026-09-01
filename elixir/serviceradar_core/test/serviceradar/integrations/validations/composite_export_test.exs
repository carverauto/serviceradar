defmodule ServiceRadar.Integrations.Validations.CompositeExportTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Integrations.Validations.CompositeExport

  # No :requires_app tag on purpose. check/1 is the rule; testing it over plain
  # maps keeps it in the genuine unit tier that runs with no database, rather
  # than in the tier that needs the shared fixture. validate/3 is two lines of
  # changeset plumbing over this.
  defp validate(settings), do: CompositeExport.check(settings)

  defp complete(overrides) do
    %{
      "composite" =>
        Map.merge(
          %{
            "check_slug" => "ot-isolation",
            "value_form" => "verdict",
            "custom_field" => "sr_isolation"
          },
          overrides
        )
    }
  end

  describe "a complete selection" do
    test "accepts verdict and status, the only two forms the runner maps" do
      assert :ok = validate(complete(%{"value_form" => "verdict"}))
      assert :ok = validate(complete(%{"value_form" => "status"}))
    end

    test "trims before judging completeness" do
      assert :ok =
               validate(
                 complete(%{
                   "check_slug" => "  ot-isolation  ",
                   "value_form" => " verdict ",
                   "custom_field" => " sr_isolation "
                 })
               )
    end
  end

  describe "no selection" do
    test "accepts settings with no composite key at all" do
      assert :ok = validate(%{})
      assert :ok = validate(%{"other" => "setting"})
    end

    test "accepts a composite of all-blank values" do
      # Turning the export off. The form deletes the key outright, but a direct
      # API write may blank the fields instead, and that is not an error.
      assert :ok =
               validate(%{
                 "composite" => %{"check_slug" => "", "value_form" => "", "custom_field" => ""}
               })
    end
  end

  describe "half-configured selections are rejected" do
    # Without these the runner reads the export as "not configured" and
    # publishes nothing, with no error and nothing on the page saying why.
    test "a slug with no custom field" do
      assert {:error, field: :settings, message: message} =
               validate(%{
                 "composite" => %{"check_slug" => "ot-isolation", "value_form" => "verdict"}
               })

      assert message =~ "custom_field"
    end

    test "a custom field with no slug" do
      assert {:error, field: :settings, message: message} =
               validate(%{
                 "composite" => %{"custom_field" => "sr_isolation", "value_form" => "verdict"}
               })

      assert message =~ "check_slug"
    end

    test "a slug and field with no value form" do
      assert {:error, field: :settings, message: message} =
               validate(%{
                 "composite" => %{
                   "check_slug" => "ot-isolation",
                   "custom_field" => "sr_isolation"
                 }
               })

      assert message =~ "value_form"
    end
  end

  describe "value_form vocabulary" do
    test "rejects anything the runner would not map" do
      # value_form/1 maps ONLY "verdict"/"status"; anything else disables the
      # export there, so storing it would persist a silent no-op.
      for bad <- ["Verdict", "VERDICT", "label", "true", "state"] do
        assert {:error, field: :settings, message: message} =
                 validate(complete(%{"value_form" => bad})),
               "expected #{inspect(bad)} to be rejected"

        assert message =~ "value_form"
      end
    end
  end

  describe "shape" do
    test "rejects a non-map composite" do
      assert {:error, field: :settings, message: message} = validate(%{"composite" => "verdict"})
      assert message =~ "must be a map"
    end
  end

  describe "non-map settings" do
    test "ignores anything that is not a map" do
      # The attribute defaults to %{} and is typed :map, so these are defensive.
      assert :ok = validate(nil)
      assert :ok = validate("not a map")
    end
  end

  describe "atomic/3" do
    test "is implemented so Ash cannot skip the rule on an atomic update" do
      assert {:module, CompositeExport} = Code.ensure_loaded(CompositeExport)
      assert function_exported?(CompositeExport, :atomic, 3)
    end
  end
end
