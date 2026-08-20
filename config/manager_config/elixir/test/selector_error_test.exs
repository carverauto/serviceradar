defmodule ServiceradarConfig.Manager.SelectorErrorTest do
  @moduledoc """
  The message a reader meets in a crash loop with no other output.

  Asserted rather than merely written: the one thing worse than this failure is this failure
  explained badly, and a docstring cannot be checked.
  """

  use ExUnit.Case, async: true

  alias ServiceradarConfig.Manager.SelectorError

  defp unset, do: SelectorError.message(:absent)

  test "names the variable and says nothing can start" do
    assert unset() =~ "SERVICERADAR_ENV"
    assert unset() =~ "CANNOT START"
  end

  test "says there is no default" do
    assert unset() =~ "NO DEFAULT"
  end

  test "lists every accepted value" do
    for kind <- ~w(localhost ci saas demo onprem) do
      assert unset() =~ kind
    end
  end

  # The reader's next action is editing a manifest, not reading source.
  test "shows how to set it on every platform" do
    for platform <- ["Kubernetes", "Docker", "Compose", "CI", "Local dev"] do
      assert unset() =~ platform
    end
  end

  test "every other selector error quotes the offending value" do
    assert SelectorError.message({:unknown_kind, "CI-staging"}) =~ "CI-staging"
    assert SelectorError.message({:instance_required, "onprem"}) =~ "onprem"
    assert SelectorError.message({:instance_not_accepted, "saas"}) =~ "saas"
  end
end
