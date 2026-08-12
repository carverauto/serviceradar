defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveFormattingTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Changes.InvalidChanges
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting

  @moduletag :db_free

  test "mapper run validation messages are bounded" do
    unbounded_message = String.duplicate("mapper unavailable ", 30)

    error =
      [fields: [:agent_id], message: unbounded_message]
      |> InvalidChanges.exception()
      |> Ash.Error.to_error_class()

    message = Formatting.format_mapper_run_error(error)

    assert String.length(message) == 240
    assert String.ends_with?(message, "…")
  end

  test "expected mapper availability errors stay actionable" do
    assert Formatting.format_mapper_run_error(:agent_offline) =~
             "No online mapper-capable agent"

    assert Formatting.format_mapper_run_error({:agent_offline, "agent-1"}) =~
             "assigned mapper agent is offline"
  end
end
