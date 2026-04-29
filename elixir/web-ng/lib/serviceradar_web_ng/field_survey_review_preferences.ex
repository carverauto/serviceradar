defmodule ServiceRadarWebNG.FieldSurveyReviewPreferences do
  @moduledoc """
  Per-user FieldSurvey review favorites and default session helpers.
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Repo
  alias ServiceRadar.Spatial.FieldSurveyReviewPreference

  @type preference :: %{
          session_id: String.t(),
          favorite: boolean(),
          default_view: boolean()
        }

  @spec for_sessions(any(), [String.t()]) ::
          {:ok, %{String.t() => preference()}} | {:error, term()}
  def for_sessions(scope, session_ids) when is_list(session_ids) do
    session_ids =
      session_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with user_id when is_binary(user_id) <- scope_user_id(scope),
         false <- session_ids == [] do
      user_id
      |> FieldSurveyReviewPreference.for_user_sessions(session_ids, scope: scope)
      |> Page.unwrap()
      |> case do
        {:ok, preferences} -> {:ok, Map.new(preferences, &preference_pair/1)}
        {:error, %{postgres: %{code: :undefined_table}}} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    else
      true -> {:ok, %{}}
      _ -> {:ok, %{}}
    end
  end

  def for_sessions(_scope, _session_ids), do: {:ok, %{}}

  @spec default_session_id(any()) :: {:ok, String.t() | nil} | {:error, term()}
  def default_session_id(scope) do
    case scope_user_id(scope) do
      user_id when is_binary(user_id) ->
        user_id
        |> FieldSurveyReviewPreference.default_for_user(scope: scope)
        |> Page.unwrap()
        |> case do
          {:ok, [%FieldSurveyReviewPreference{session_id: session_id} | _]} -> {:ok, session_id}
          {:ok, _} -> {:ok, nil}
          {:error, %{postgres: %{code: :undefined_table}}} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, nil}
    end
  end

  @spec toggle_favorite(any(), String.t()) :: {:ok, preference()} | {:error, term()}
  def toggle_favorite(scope, session_id) when is_binary(session_id) do
    with user_id when is_binary(user_id) <- scope_user_id(scope),
         {:ok, preferences} <- for_sessions(scope, [session_id]) do
      current = Map.get(preferences, session_id, %{})

      upsert(scope, user_id, session_id, %{
        favorite: !Map.get(current, :favorite, false),
        default_view: Map.get(current, :default_view, false)
      })
    else
      _ -> {:error, :missing_user}
    end
  end

  def toggle_favorite(_scope, _session_id), do: {:error, :invalid_session}

  @spec set_default(any(), String.t()) :: {:ok, preference()} | {:error, term()}
  def set_default(scope, session_id) when is_binary(session_id) do
    case scope_user_id(scope) do
      user_id when is_binary(user_id) ->
        fn ->
          with {:ok, _cleared} <- clear_default_views(user_id),
               {:ok, %{rows: [[^session_id, favorite, default_view] | _]}} <-
                 upsert_default_view(user_id, session_id) do
            %{session_id: session_id, favorite: favorite, default_view: default_view}
          else
            {:error, reason} -> Repo.rollback(reason)
            _ -> Repo.rollback(:default_not_saved)
          end
        end
        |> Repo.transaction()
        |> case do
          {:ok, preference} -> {:ok, preference}
          {:error, %{postgres: %{code: :undefined_table}}} -> {:error, :preferences_unavailable}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_user}
    end
  end

  def set_default(_scope, _session_id), do: {:error, :invalid_session}

  defp upsert(scope, user_id, session_id, attrs) do
    attrs =
      %{
        user_id: user_id,
        session_id: session_id,
        favorite: Map.get(attrs, :favorite, false),
        default_view: Map.get(attrs, :default_view, false),
        metadata: Map.get(attrs, :metadata, %{})
      }

    attrs
    |> FieldSurveyReviewPreference.upsert(scope: scope)
    |> case do
      {:ok, preference} -> {:ok, preference_map(preference)}
      {:error, %{postgres: %{code: :undefined_table}}} -> {:error, :preferences_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_default_views(user_id) do
    Repo.query(
      """
      UPDATE platform.fieldsurvey_review_preferences
      SET default_view = false, updated_at = now()
      WHERE user_id = $1 AND default_view = true
      """,
      [user_id]
    )
  end

  defp upsert_default_view(user_id, session_id) do
    Repo.query(
      """
      INSERT INTO platform.fieldsurvey_review_preferences (
        id,
        user_id,
        session_id,
        favorite,
        default_view,
        metadata,
        inserted_at,
        updated_at
      )
      VALUES (gen_random_uuid(), $1, $2, true, true, '{}'::jsonb, now(), now())
      ON CONFLICT (user_id, session_id) DO UPDATE
      SET favorite = true,
          default_view = true,
          updated_at = now()
      RETURNING session_id, favorite, default_view
      """,
      [user_id, session_id]
    )
  end

  defp preference_pair(%FieldSurveyReviewPreference{} = preference) do
    {preference.session_id, preference_map(preference)}
  end

  defp preference_map(%FieldSurveyReviewPreference{} = preference) do
    %{
      session_id: preference.session_id,
      favorite: preference.favorite,
      default_view: preference.default_view
    }
  end

  defp scope_user_id(%{user: %{id: user_id}}), do: to_string(user_id)
  defp scope_user_id(_scope), do: nil
end
