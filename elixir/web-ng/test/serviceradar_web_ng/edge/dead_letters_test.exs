defmodule ServiceRadarWebNG.Edge.DeadLettersTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Edge.DeadLetters

  @moduletag :db_free

  test "a summary counts only what was replayed or purged as done, and keeps every failure reason" do
    entries = [
      %{dlq_sequence: 1, result: :replayed},
      %{dlq_sequence: 2, result: :replayed_kept},
      %{dlq_sequence: 3, result: {:error, :source_duplicate}},
      %{dlq_sequence: 4, result: {:error, :timeout}},
      %{dlq_sequence: 5, result: {:error, :timeout}}
    ]

    assert %{
             action: :replay,
             done: 1,
             kept: 1,
             failed: 3,
             errors: [":source_duplicate", ":timeout"],
             complete: false
           } = DeadLetters.summarize(:replay, entries, false)

    assert %{done: 2, failed: 0, complete: true} =
             DeadLetters.summarize(:purge, [%{result: :purged}, %{result: :purged}], true)
  end
end
