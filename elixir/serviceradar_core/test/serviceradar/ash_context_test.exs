defmodule ServiceRadar.AshContextTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AshContext

  test "extracts actor from an Ash changeset private context" do
    actor = %{id: "actor-1"}
    changeset = %Ash.Changeset{context: %{private: %{actor: actor}}}

    assert AshContext.actor(changeset) == actor
  end

  test "extracts actor from a plain context map" do
    actor = %{id: "actor-1"}

    assert AshContext.actor(%{actor: actor}) == actor
  end

  test "returns nil when no actor exists" do
    assert AshContext.actor(%{}) == nil
  end
end
