defmodule ServiceRadarWebNG.FieldSurveyArtifactStore do
  @moduledoc """
  NATS Object Store backend for FieldSurvey scan artifacts.
  """

  alias Jetstream.API.Object

  require Logger

  @default_bucket "serviceradar_fieldsurvey"
  @default_max_upload_bytes 104_857_600

  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes do
    Keyword.get(config(), :max_upload_bytes, @default_max_upload_bytes)
  end

  @spec put_blob(String.t(), binary()) :: :ok | {:error, term()}
  def put_blob(object_key, payload) when is_binary(object_key) and is_binary(payload) do
    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, io} <- StringIO.open(payload),
           {:ok, _meta} <- Object.put(conn, bucket_name(), object_key, io) do
        :ok
      end
    end)
  end

  def put_blob(_object_key, _payload), do: {:error, :invalid_blob}

  @spec fetch_blob(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_blob(object_key) when is_binary(object_key) do
    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, io} <- StringIO.open(""),
           :ok <-
             Object.get(conn, bucket_name(), object_key, fn chunk ->
               IO.binwrite(io, chunk)
             end) do
        {_input, output} = StringIO.contents(io)
        {:ok, output}
      else
        {:error, %{"code" => 404}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def fetch_blob(_object_key), do: {:error, :invalid_key}

  @spec sha256(binary()) :: String.t()
  def sha256(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp config do
    Application.get_env(:serviceradar_web_ng, :field_survey_artifact_store, [])
  end

  defp bucket_name do
    Keyword.get(config(), :jetstream_bucket, @default_bucket)
  end

  defp bucket_opts do
    ttl_seconds = Keyword.get(config(), :jetstream_ttl_seconds, 0)
    ttl_ns = if ttl_seconds > 0, do: ttl_seconds * 1_000_000_000, else: 0

    Enum.reject(
      [
        description: Keyword.get(config(), :jetstream_description, "FieldSurvey room scan artifacts"),
        max_bucket_size: Keyword.get(config(), :jetstream_max_bucket_size),
        max_chunk_size: Keyword.get(config(), :jetstream_max_chunk_size),
        replicas: Keyword.get(config(), :jetstream_replicas, 1),
        storage: Keyword.get(config(), :jetstream_storage, :file),
        ttl: ttl_ns
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp with_jetstream(fun) when is_function(fun, 1) do
    case ServiceRadar.NATS.Connection.get() do
      {:ok, conn} -> fun.(conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_bucket(conn) do
    stream_name = "OBJ_#{bucket_name()}"

    case Jetstream.API.Stream.info(conn, stream_name) do
      {:ok, _} ->
        {:ok, :exists}

      {:error, %{"code" => 404}} ->
        Object.create_bucket(conn, bucket_name(), bucket_opts())

      {:error, reason} ->
        {:error, reason}
    end
  end
end
