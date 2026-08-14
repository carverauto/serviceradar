defmodule ServiceRadar.CompositeChecks.SRQLValidationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.SRQLValidation

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Known Check #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  describe "referenced_slugs/1" do
    test "finds a verdict field" do
      assert SRQLValidation.referenced_slugs("in:devices composite.pci-isolation:not_isolated") ==
               ["pci-isolation"]
    end

    test "finds a status field without the suffix" do
      assert SRQLValidation.referenced_slugs("in:devices composite.pci-isolation.status:degraded") ==
               ["pci-isolation"]
    end

    test "finds every distinct slug, in order" do
      query = "in:devices composite.alpha:x composite.beta.status:y composite.alpha:z"
      assert SRQLValidation.referenced_slugs(query) == ["alpha", "beta"]
    end

    test "lowercases to match translator field normalization" do
      assert SRQLValidation.referenced_slugs("in:devices composite.PCI-Isolation:x") ==
               ["pci-isolation"]
    end

    test "finds nothing in a query with no composite reference" do
      assert SRQLValidation.referenced_slugs("in:devices tag:managed") == []
    end

    test "tolerates non-binary input" do
      assert SRQLValidation.referenced_slugs(nil) == []
    end
  end

  describe "validate_composite_slugs/2" do
    test "accepts a query with no composite reference" do
      assert :ok =
               SRQLValidation.validate_composite_slugs("in:devices tag:managed", actor: actor())
    end

    test "accepts a known slug", %{check: check} do
      assert :ok =
               SRQLValidation.validate_composite_slugs(
                 "in:devices composite.#{check.slug}:isolated_verified",
                 actor: actor()
               )
    end

    test "accepts the status suffix on a known slug", %{check: check} do
      assert :ok =
               SRQLValidation.validate_composite_slugs(
                 "in:devices composite.#{check.slug}.status:degraded",
                 actor: actor()
               )
    end

    test "rejects an unknown slug and names it" do
      assert {:error, {:unknown_composite_check, "no-such-check"}} =
               SRQLValidation.validate_composite_slugs(
                 "in:devices composite.no-such-check:x",
                 actor: actor()
               )
    end

    test "checks every referenced slug, not just the first", %{check: check} do
      assert {:error, {:unknown_composite_check, "missing"}} =
               SRQLValidation.validate_composite_slugs(
                 "in:devices composite.#{check.slug}:a composite.missing:b",
                 actor: actor()
               )
    end

    test "a draft check still validates", %{check: check} do
      # Validation answers "does this check exist", not "is it enabled". A draft
      # check's slug is a real reference that simply has no results yet, and
      # rejecting it would make the builder unusable while authoring.
      assert check.state == :draft

      assert :ok =
               SRQLValidation.validate_composite_slugs(
                 "in:devices composite.#{check.slug}:x",
                 actor: actor()
               )
    end
  end
end
