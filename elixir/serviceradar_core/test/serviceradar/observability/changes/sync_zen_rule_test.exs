defmodule ServiceRadar.Observability.Changes.SyncZenRuleTest do
  @moduledoc """
  An atomic update does not call `change/3`. Ash applies what `atomic/3`
  returns, so the sync hook reaches an atomic update only if `atomic/3` hands
  back a changeset that carries it.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.Changes.SyncZenRule
  alias ServiceRadar.Observability.ZenRule

  defp update_changeset(context) do
    %ZenRule{}
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(context)
    |> Map.put(:action_type, :update)
  end

  test "an atomic update still registers the sync hook" do
    assert {:ok, %Ash.Changeset{after_action: [hook]}} =
             SyncZenRule.atomic(update_changeset(%{}), [], %{})

    assert is_function(hook, 2)
  end

  test "an atomic update asked to skip the sync registers no hook" do
    assert {:ok, %Ash.Changeset{after_action: []}} =
             SyncZenRule.atomic(update_changeset(%{skip_zen_sync: true}), [], %{})
  end
end
