defmodule ServiceRadarWebNG.FieldSurveySessionOwnershipTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.FieldSurveySessionOwnership

  @moduletag :db_free

  test "a new session is refused once the owner is at the session budget" do
    cap = FieldSurveySessionOwnership.max_sessions_per_user()

    assert {:error, :too_many_sessions} =
             FieldSurveySessionOwnership.claim_or_verify("survey-1", "user-1",
               query: scripted([{:ok, %{rows: [[cap, false]]}}])
             )

    assert_receive {:query, ["user-1", "survey-1"]}
    refute_receive {:query, _}
  end

  test "reclaiming an owned session stays inside the budget" do
    cap = FieldSurveySessionOwnership.max_sessions_per_user()

    assert {:ok, "survey-1"} =
             FieldSurveySessionOwnership.claim_or_verify("survey-1", "user-1",
               query:
                 scripted([
                   {:ok, %{rows: [[cap, true]]}},
                   {:ok, %{rows: [["user-1"]]}}
                 ])
             )

    assert_receive {:query, ["user-1", "survey-1"]}
    assert_receive {:query, ["survey-1", "user-1"]}
  end

  test "a session owned by someone else stays forbidden under the budget" do
    assert {:error, :forbidden} =
             FieldSurveySessionOwnership.claim_or_verify("survey-1", "user-1",
               query:
                 scripted([
                   {:ok, %{rows: [[1, false]]}},
                   {:ok, %{rows: []}}
                 ])
             )
  end

  test "an invalid session id is rejected before any query" do
    assert {:error, :invalid_session_id} =
             FieldSurveySessionOwnership.claim_or_verify("bad id", "user-1",
               query: fn _sql, _params ->
                 send(self(), :queried)
                 {:ok, %{rows: []}}
               end
             )

    refute_receive :queried
  end

  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _sql, params ->
      send(self(), {:query, params})
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end
  end
end
