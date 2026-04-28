defmodule ServiceRadarWebNG.FieldSurveySessionMetadata do
  @moduledoc """
  Stores site/building/floor attribution for FieldSurvey sessions.
  """

  alias ServiceRadar.Repo

  @session_fields ~w(site_id site_name building_id building_name floor_id floor_name floor_index tags metadata)a

  @spec upsert(String.t(), String.t(), map()) :: {:ok, map() | nil} | {:error, :forbidden | term()}
  def upsert(session_id, user_id, attrs) when is_binary(session_id) and is_binary(user_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs)

    if empty_attrs?(attrs) do
      {:ok, nil}
    else
      do_upsert(session_id, user_id, attrs)
    end
  end

  def upsert(_session_id, _user_id, _attrs), do: {:ok, nil}

  @spec get(any(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(scope, session_id) when is_binary(session_id) do
    case for_sessions(scope, [session_id]) do
      {:ok, metadata_by_session} -> {:ok, Map.get(metadata_by_session, session_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec for_sessions(any(), [String.t()]) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def for_sessions(scope, session_ids) when is_list(session_ids) do
    session_ids =
      session_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with user_id when is_binary(user_id) <- scope_user_id(scope),
         false <- session_ids == [] do
      """
      SELECT
        session_id,
        site_id,
        site_name,
        building_id,
        building_name,
        floor_id,
        floor_name,
        floor_index,
        tags,
        metadata
      FROM platform.survey_session_metadata
      WHERE user_id = $1
        AND session_id = ANY($2::text[])
      """
      |> Repo.query([user_id, session_ids])
      |> case do
        {:ok, %{rows: rows}} -> {:ok, Map.new(rows, &row_to_metadata/1)}
        {:error, %{postgres: %{code: :undefined_table}}} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    else
      true -> {:ok, %{}}
      _ -> {:ok, %{}}
    end
  end

  def for_sessions(_scope, _session_ids), do: {:ok, %{}}

  defp do_upsert(session_id, user_id, attrs) do
    metadata_json = Jason.encode!(Map.get(attrs, :metadata, %{}))

    """
    INSERT INTO platform.survey_session_metadata (
      session_id,
      user_id,
      site_id,
      site_name,
      building_id,
      building_name,
      floor_id,
      floor_name,
      floor_index,
      tags,
      metadata,
      inserted_at,
      updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::text[], $11::jsonb, now(), now())
    ON CONFLICT (session_id) DO UPDATE
    SET
      site_id = COALESCE(EXCLUDED.site_id, survey_session_metadata.site_id),
      site_name = COALESCE(EXCLUDED.site_name, survey_session_metadata.site_name),
      building_id = COALESCE(EXCLUDED.building_id, survey_session_metadata.building_id),
      building_name = COALESCE(EXCLUDED.building_name, survey_session_metadata.building_name),
      floor_id = COALESCE(EXCLUDED.floor_id, survey_session_metadata.floor_id),
      floor_name = COALESCE(EXCLUDED.floor_name, survey_session_metadata.floor_name),
      floor_index = COALESCE(EXCLUDED.floor_index, survey_session_metadata.floor_index),
      tags = CASE WHEN array_length(EXCLUDED.tags, 1) IS NULL THEN survey_session_metadata.tags ELSE EXCLUDED.tags END,
      metadata = survey_session_metadata.metadata || EXCLUDED.metadata,
      updated_at = now()
    WHERE survey_session_metadata.user_id = EXCLUDED.user_id
    RETURNING session_id, site_id, site_name, building_id, building_name, floor_id, floor_name, floor_index, tags, metadata
    """
    |> Repo.query([
      session_id,
      user_id,
      Map.get(attrs, :site_id),
      Map.get(attrs, :site_name),
      Map.get(attrs, :building_id),
      Map.get(attrs, :building_name),
      Map.get(attrs, :floor_id),
      Map.get(attrs, :floor_name),
      Map.get(attrs, :floor_index),
      Map.get(attrs, :tags, []),
      metadata_json
    ])
    |> case do
      {:ok, %{rows: [row | _]}} -> {:ok, elem(row_to_metadata(row), 1)}
      {:ok, %{rows: []}} -> {:error, :forbidden}
      {:error, %{postgres: %{code: :undefined_table}}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attrs(attrs) do
    Enum.reduce(@session_fields, %{}, fn field, acc ->
      case normalize_field(field, Map.get(attrs, field) || Map.get(attrs, to_string(field))) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp normalize_field(:floor_index, value) when is_integer(value), do: value

  defp normalize_field(:floor_index, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_field(:tags, value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(32)
  end

  defp normalize_field(:tags, value) when is_binary(value) do
    value
    |> String.split([",", ";"], trim: true)
    |> normalize_field(:tags)
  end

  defp normalize_field(:metadata, value) when is_map(value), do: value

  defp normalize_field(:metadata, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp normalize_field(_field, value), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> String.slice(string, 0, 160)
    end
  end

  defp normalize_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_string()
  defp normalize_string(value) when is_number(value), do: value |> to_string() |> normalize_string()
  defp normalize_string(_value), do: nil

  defp empty_attrs?(attrs) do
    attrs
    |> Map.delete(:tags)
    |> Map.delete(:metadata)
    |> map_size()
    |> Kernel.==(0) and Map.get(attrs, :tags, []) == [] and Map.get(attrs, :metadata, %{}) == %{}
  end

  defp row_to_metadata([
         session_id,
         site_id,
         site_name,
         building_id,
         building_name,
         floor_id,
         floor_name,
         floor_index,
         tags,
         metadata
       ]) do
    {session_id,
     %{
       session_id: session_id,
       site_id: site_id,
       site_name: site_name,
       building_id: building_id,
       building_name: building_name,
       floor_id: floor_id,
       floor_name: floor_name,
       floor_index: floor_index,
       tags: tags || [],
       metadata: metadata || %{},
       label: metadata_label(site_name, building_name, floor_name, floor_index)
     }}
  end

  defp metadata_label(site_name, building_name, floor_name, floor_index) do
    [site_name, building_name, floor_name || floor_index_label(floor_index)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp floor_index_label(nil), do: nil
  defp floor_index_label(index), do: "Floor #{index}"

  defp scope_user_id(%{user: %{id: user_id}}), do: to_string(user_id)
  defp scope_user_id(_scope), do: nil
end
