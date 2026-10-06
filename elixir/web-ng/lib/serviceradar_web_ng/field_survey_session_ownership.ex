defmodule ServiceRadarWebNG.FieldSurveySessionOwnership do
  @moduledoc """
  Claims and verifies ownership for FieldSurvey ingest session IDs.
  """

  alias ServiceRadar.Repo

  @session_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  # One row per survey. High enough for years of daily walks, finite so a
  # token cannot mint session ids without limit.
  @max_sessions_per_user 10_000

  @spec max_sessions_per_user() :: pos_integer()
  def max_sessions_per_user, do: @max_sessions_per_user

  @spec claim_or_verify(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :invalid_session_id | :forbidden | :too_many_sessions | term()}
  def claim_or_verify(session_id, user_id, opts \\ [])

  def claim_or_verify(session_id, user_id, opts) when is_binary(session_id) and is_binary(user_id) and is_list(opts) do
    query = Keyword.get(opts, :query, &Repo.query/2)

    with :ok <- validate_session_id(session_id),
         :ok <- ensure_session_budget(session_id, user_id, query),
         {:ok, %{rows: [[^user_id]]}} <- upsert_owner(session_id, user_id, query) do
      {:ok, session_id}
    else
      {:ok, %{rows: []}} -> {:error, :forbidden}
      {:error, :invalid_session_id} -> {:error, :invalid_session_id}
      {:error, :too_many_sessions} -> {:error, :too_many_sessions}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def claim_or_verify(_session_id, _user_id, _opts), do: {:error, :invalid_session_id}

  defp validate_session_id(session_id) do
    if Regex.match?(@session_id_pattern, session_id) do
      :ok
    else
      {:error, :invalid_session_id}
    end
  end

  defp ensure_session_budget(session_id, user_id, query) do
    case query.(
           """
           SELECT COUNT(*)::int,
                  COALESCE(BOOL_OR(session_id = $2), false)
           FROM platform.survey_session_owners
           WHERE user_id = $1
           """,
           [user_id, session_id]
         ) do
      {:ok, %{rows: [[count, already]]}}
      when is_integer(count) and (already == true or count < @max_sessions_per_user) ->
        :ok

      {:ok, %{rows: [[count, _already]]}} when is_integer(count) ->
        {:error, :too_many_sessions}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp upsert_owner(session_id, user_id, query) do
    query.(
      """
      INSERT INTO platform.survey_session_owners (session_id, user_id, claimed_at, last_seen_at)
      VALUES ($1, $2, now(), now())
      ON CONFLICT (session_id) DO UPDATE
      SET last_seen_at = EXCLUDED.last_seen_at
      WHERE survey_session_owners.user_id = EXCLUDED.user_id
      RETURNING user_id
      """,
      [session_id, user_id]
    )
  end
end
