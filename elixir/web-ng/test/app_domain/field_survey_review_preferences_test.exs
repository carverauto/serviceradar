defmodule ServiceRadarWebNG.FieldSurveyReviewPreferencesTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.FieldSurveyReviewPreferences

  setup do
    scope =
      Scope.for_user(%{
        id: "11111111-1111-1111-1111-111111111111",
        email: "fieldsurvey-review@example.test",
        role: :admin
      })

    {:ok, scope: scope}
  end

  test "toggles favorites for a FieldSurvey session", %{scope: scope} do
    session_id = unique_session_id("favorite")

    assert {:ok, %{session_id: ^session_id, favorite: true, default_view: false}} =
             FieldSurveyReviewPreferences.toggle_favorite(scope, session_id)

    assert {:ok, preferences} = FieldSurveyReviewPreferences.for_sessions(scope, [session_id])
    assert preferences[session_id].favorite
    refute preferences[session_id].default_view

    assert {:ok, %{session_id: ^session_id, favorite: false, default_view: false}} =
             FieldSurveyReviewPreferences.toggle_favorite(scope, session_id)
  end

  test "set_default keeps one default and marks it as favorite", %{scope: scope} do
    first_session_id = unique_session_id("default-a")
    second_session_id = unique_session_id("default-b")

    assert {:ok, %{session_id: ^first_session_id, favorite: true, default_view: true}} =
             FieldSurveyReviewPreferences.set_default(scope, first_session_id)

    assert {:ok, ^first_session_id} = FieldSurveyReviewPreferences.default_session_id(scope)

    assert {:ok, %{session_id: ^second_session_id, favorite: true, default_view: true}} =
             FieldSurveyReviewPreferences.set_default(scope, second_session_id)

    assert {:ok, ^second_session_id} = FieldSurveyReviewPreferences.default_session_id(scope)

    assert {:ok, preferences} =
             FieldSurveyReviewPreferences.for_sessions(scope, [first_session_id, second_session_id])

    refute preferences[first_session_id].default_view
    assert preferences[second_session_id].default_view
    assert preferences[second_session_id].favorite
  end

  defp unique_session_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
