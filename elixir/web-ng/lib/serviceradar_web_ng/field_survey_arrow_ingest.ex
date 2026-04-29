defmodule ServiceRadarWebNG.FieldSurveyArrowIngest do
  @moduledoc """
  Direct Apache Arrow IPC ingest for FieldSurvey streams.

  The WebSocket route authenticates and chooses the session. A dedicated ADBC
  connection carries that session as a PostgreSQL setting, and table triggers
  stamp trusted/derived columns while ADBC appends the Arrow stream directly.
  """

  require Logger

  @database ServiceRadarWebNG.FieldSurveyAdbcDatabase
  @session_setting "serviceradar.field_survey_session_id"

  @type stream_type :: :rf_observations | :pose_samples | :spectrum_observations

  @spec connect(String.t()) :: {:ok, pid()} | {:error, term()}
  def connect(session_id) when is_binary(session_id) do
    with {:ok, conn} <- Adbc.Connection.start_link(database: @database),
         :ok <- set_session_id(conn, session_id) do
      {:ok, conn}
    else
      {:error, reason} = error ->
        Logger.error("Failed to open FieldSurvey ADBC connection: #{inspect(reason)}")
        error
    end
  end

  @spec disconnect(pid() | nil) :: :ok
  def disconnect(nil), do: :ok

  def disconnect(conn) when is_pid(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec ingest(pid(), stream_type(), String.t(), binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def ingest(conn, stream_type, _session_id, payload) when is_pid(conn) and is_binary(payload) do
    with {:ok, stream} <- Adbc.StreamResult.from_ipc_stream(payload),
         {:ok, row_count} <- bulk_insert(conn, stream_type, stream) do
      {:ok, row_count || 0}
    end
  rescue
    error -> {:error, error}
  end

  defp set_session_id(conn, session_id) do
    case Adbc.Connection.query(
           conn,
           "SELECT set_config($1, $2, false)",
           [@session_setting, session_id],
           []
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bulk_insert(conn, :rf_observations, stream) do
    Adbc.Connection.bulk_insert(conn, stream,
      table: "survey_rf_observations",
      schema: "platform",
      mode: :append
    )
  end

  defp bulk_insert(conn, :pose_samples, stream) do
    Adbc.Connection.bulk_insert(conn, stream,
      table: "survey_pose_samples",
      schema: "platform",
      mode: :append
    )
  end

  defp bulk_insert(conn, :spectrum_observations, stream) do
    Adbc.Connection.bulk_insert(conn, stream,
      table: "survey_spectrum_observations",
      schema: "platform",
      mode: :append
    )
  end

  defp bulk_insert(_conn, stream_type, _stream), do: {:error, {:unsupported_stream_type, stream_type}}
end
