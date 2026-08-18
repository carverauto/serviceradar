defmodule ServiceRadarWebNG.Plugins.AddonRolloutsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.AddonRollouts

  @moduletag :db_free

  test "format_error explains retryable rollout states" do
    assert AddonRollouts.format_error(:rollout_not_retryable) ==
             "This rollout can only be retried after it has failed or rolled back."

    assert AddonRollouts.format_error({:error, :rollout_not_paused}) ==
             "This rollout is not paused."
  end

  test "format_error rewrites the one-active-target unique index" do
    dump =
      "#Ash.Changeset<action: :create, errors: [addon_rollout_targets_one_active_target_index]>"

    assert AddonRollouts.format_error(dump) ==
             "An earlier canary for this add-on is still holding one of the agents. Cancel that rollout or retry after it finishes."

    assert AddonRollouts.format_error(%{
             constraint: "addon_rollout_targets_one_active_target_index"
           }) ==
             "An earlier canary for this add-on is still holding one of the agents. Cancel that rollout or retry after it finishes."
  end

  test "format_error rewrites the one-active-source unique index" do
    assert AddonRollouts.format_error(%RuntimeError{
             message: "duplicate key value violates unique constraint \"addon_rollouts_one_active_source_index\""
           }) == "This profile or assignment already has an active rollout."
  end

  test "format_error keeps the first line of an unknown error and truncates" do
    assert AddonRollouts.format_error("first line\nsecond line") == "first line"

    long = String.duplicate("x", 300)
    formatted = AddonRollouts.format_error(long)
    assert String.ends_with?(formatted, "…")
    assert String.length(formatted) == 281
  end
end
