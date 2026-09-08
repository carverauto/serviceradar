Code.require_file("support_fixtures.exs", __DIR__)

defmodule ServiceradarConfig.Manager.IdentityTest do
  use ExUnit.Case, async: true

  alias ServiceradarConfig.Manager.{Identity, SelectorError}

  test "an unset variable is an error with no default" do
    assert {:error, :absent} = Identity.parse(nil)
  end

  # A shell exporting SERVICERADAR_ENV= has selected nothing, and this repository's build tooling
  # pins several variables to "" deliberately. Empty must not become a kind.
  test "an empty value is unset, not a choice" do
    assert {:error, :absent} = Identity.parse("")
    assert {:error, :absent} = Identity.parse("   ")
  end

  test "single-instance kinds accept no instance" do
    for kind <- ~w(localhost ci saas demo) do
      assert {:ok, %Identity{kind: ^kind, instance: nil}} = Identity.parse(kind)
      assert {:error, {:instance_not_accepted, ^kind}} = Identity.parse("#{kind}:x")
    end
  end

  test "onprem requires an instance" do
    assert {:error, {:instance_required, "onprem"}} = Identity.parse("onprem")
    assert {:error, {:instance_required, "onprem"}} = Identity.parse("onprem:")
    assert {:ok, %Identity{kind: "onprem", instance: "untd"}} = Identity.parse("onprem:untd")
  end

  test "an unrecognised kind is rejected and quoted back" do
    assert {:error, {:unknown_kind, "CI-staging"} = err} = Identity.parse("CI-staging")
    assert SelectorError.message(err) =~ "CI-staging"
  end

  test "surrounding whitespace is tolerated" do
    assert {:ok, %Identity{kind: "saas"}} = Identity.parse("  saas  ")
  end

  # to_string is the spelling SERVICERADAR_ENV accepts, so an error can quote back something a
  # reader can paste into a manifest.
  test "to_string round-trips through parse" do
    for value <- ~w(localhost ci saas demo onprem:untd) do
      {:ok, identity} = Identity.parse(value)
      assert Identity.to_string(identity) == value
      assert {:ok, ^identity} = Identity.parse(Identity.to_string(identity))
    end
  end
end
