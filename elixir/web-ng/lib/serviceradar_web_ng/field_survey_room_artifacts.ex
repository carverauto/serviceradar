defmodule ServiceRadarWebNG.FieldSurveyRoomArtifacts do
  @moduledoc """
  Stores FieldSurvey room scan artifacts in NATS Object Store and indexes metadata in Postgres.
  """

  alias ServiceRadar.Spatial.SurveyRoomArtifact
  alias ServiceRadarWebNG.FieldSurveyArtifactStore

  require Ash.Changeset

  @allowed_artifact_types MapSet.new(["roomplan_usdz", "floorplan_geojson", "point_cloud_ply"])
  @default_artifact_type "roomplan_usdz"
  @default_content_type "application/octet-stream"

  @type store_opts :: [
          artifact_type: String.t() | nil,
          content_type: String.t() | nil,
          captured_at: DateTime.t() | nil,
          metadata: map(),
          scope: any()
        ]

  @spec store(String.t(), String.t(), binary(), store_opts()) ::
          {:ok, SurveyRoomArtifact.t()} | {:error, term()}
  def store(session_id, user_id, payload, opts \\ [])

  def store(session_id, user_id, payload, opts)
      when is_binary(session_id) and is_binary(user_id) and is_binary(payload) do
    artifact_type = normalize_artifact_type(Keyword.get(opts, :artifact_type))
    content_type = normalize_content_type(Keyword.get(opts, :content_type))
    object_id = Ecto.UUID.generate()
    object_key = object_key(session_id, artifact_type, object_id)
    byte_size = byte_size(payload)
    sha256 = FieldSurveyArtifactStore.sha256(payload)

    attrs = %{
      session_id: session_id,
      user_id: user_id,
      artifact_type: artifact_type,
      content_type: content_type,
      object_key: object_key,
      byte_size: byte_size,
      sha256: sha256,
      captured_at: Keyword.get(opts, :captured_at),
      metadata: Keyword.get(opts, :metadata, %{}),
      uploaded_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    }

    with :ok <- validate_upload_size(byte_size),
         :ok <- FieldSurveyArtifactStore.put_blob(object_key, payload) do
      create_metadata(attrs, Keyword.get(opts, :scope))
    end
  end

  def store(_session_id, _user_id, _payload, _opts), do: {:error, :invalid_artifact}

  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(object_key), do: FieldSurveyArtifactStore.fetch_blob(object_key)

  defp create_metadata(attrs, scope) do
    SurveyRoomArtifact
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(scope: scope, domain: ServiceRadar.Spatial)
  end

  defp validate_upload_size(size) when is_integer(size) and size > 0 do
    if size <= FieldSurveyArtifactStore.max_upload_bytes() do
      :ok
    else
      {:error, :artifact_too_large}
    end
  end

  defp validate_upload_size(0), do: {:error, :empty_artifact}
  defp validate_upload_size(_size), do: {:error, :artifact_too_large}

  defp object_key(session_id, artifact_type, artifact_id) do
    "field-survey/#{sanitize_segment(session_id)}/#{sanitize_segment(artifact_type)}/#{artifact_id}"
  end

  defp normalize_artifact_type(nil), do: @default_artifact_type

  defp normalize_artifact_type(artifact_type) when is_binary(artifact_type) do
    artifact_type = String.trim(artifact_type)

    if MapSet.member?(@allowed_artifact_types, artifact_type) do
      artifact_type
    else
      @default_artifact_type
    end
  end

  defp normalize_artifact_type(_), do: @default_artifact_type

  defp normalize_content_type(nil), do: @default_content_type

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" -> @default_content_type
      normalized -> normalized
    end
  end

  defp normalize_content_type(_), do: @default_content_type

  defp sanitize_segment(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.slice(0, 128)
    |> case do
      "" -> "unknown"
      safe -> safe
    end
  end

  defp sanitize_segment(_), do: "unknown"
end
