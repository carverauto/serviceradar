defmodule ServiceRadarWebNG.FieldSurveySessionOwnership do
  @moduledoc """
  Claims and verifies ownership for FieldSurvey ingest session IDs.
  """

  alias ServiceRadar.Repo

  @session_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/

  @spec claim_or_verify(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_session_id | :forbidden | term()}
  def claim_or_verify(session_id, user_id) when is_binary(session_id) and is_binary(user_id) do
    with :ok <- validate_session_id(session_id),
         {:ok, %{rows: [[^user_id]]}} <- upsert_owner(session_id, user_id) do
      {:ok, session_id}
    else
      {:ok, %{rows: []}} -> {:error, :forbidden}
      {:error, :invalid_session_id} -> {:error, :invalid_session_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def claim_or_verify(_session_id, _user_id), do: {:error, :invalid_session_id}

  defp validate_session_id(session_id) do
    if Regex.match?(@session_id_pattern, session_id) do
      :ok
    else
      {:error, :invalid_session_id}
    end
  end

  defp upsert_owner(session_id, user_id) do
    Repo.query(
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
