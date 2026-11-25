defmodule ServiceRadar.Camera.VisualCaptionWorker do
  @moduledoc """
  Asynchronous Oban worker that generates multi-frame VLM action captions for
  recorded Smart camera clips (`person`, `animal`, `vehicle`, `package`).

  Reads up to 6 keyframe JPEGs already persisted in `platform.camera_visual_frames.thumbnail_jpeg`
  (zero extra S3/NVR round-trips), invokes `ServiceRadar.Camera.VisualCaptionClient`,
  embeds the resulting caption text using `ServiceRadar.Camera.SemanticSearch.embed_text/2`
  (gracefully falling back to `nil` if the text embedder is busy), and idempotently
  upserts `ServiceRadar.Camera.VisualClipCaption`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:catalog_entry_id, :visual_frame_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.SemanticSearch
  alias ServiceRadar.Camera.VisualCaptionClient
  alias ServiceRadar.Camera.VisualClipCaption
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @system_actor SystemActor.system(:camera_visual_caption_worker)
  @smart_object_classes MapSet.new(~w(person animal vehicle package))
  @max_caption_frames 6

  @doc "Returns the set of Smart object classes that trigger VLM captioning."
  @spec smart_object_classes() :: MapSet.t(String.t())
  def smart_object_classes, do: @smart_object_classes

  @doc """
  Returns `true` when `detections` contains at least one Smart category
  (`person`, `animal`, `vehicle`, `package`).
  """
  @spec has_smart_detection?(list() | nil) :: boolean()
  def has_smart_detection?(detections) when is_list(detections) do
    Enum.any?(detections, fn det ->
      cls =
        case det do
          %{object_class: c} when is_binary(c) -> c
          %{"object_class" => c} when is_binary(c) -> c
          _ -> nil
        end

      is_binary(cls) and MapSet.member?(@smart_object_classes, String.downcase(String.trim(cls)))
    end)
  end

  def has_smart_detection?(_), do: false

  @doc """
  Enqueues an idempotent caption job for `catalog_entry_id` (and optional anchor
  `visual_frame_id`) when VLM captioning is enabled.
  """
  @spec enqueue_for_entry(String.t(), String.t() | nil, keyword()) ::
          {:ok, Oban.Job.t()} | :noop | {:error, term()}
  def enqueue_for_entry(catalog_entry_id, visual_frame_id \\ nil, opts \\ [])
      when is_binary(catalog_entry_id) and is_list(opts) do
    enabled_fn = Keyword.get(opts, :enabled_fn, &VisualCaptionClient.enabled?/0)
    insert_fn = Keyword.get(opts, :insert_fn, &default_insert/1)

    if enabled_fn.() do
      args = %{
        "catalog_entry_id" => catalog_entry_id,
        "visual_frame_id" => visual_frame_id
      }

      insert_fn.(new(args))
    else
      :noop
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"catalog_entry_id" => catalog_entry_id} = args}) do
    if VisualCaptionClient.enabled?() do
      caption_entry(catalog_entry_id, Map.get(args, "visual_frame_id"), [])
    else
      :ok
    end
  end

  def perform(_job), do: :ok

  @doc """
  Executes the captioning workflow for a single `catalog_entry_id`.
  Accepts injectable loaders/clients via `opts` for deterministic unit testing.
  """
  @spec caption_entry(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def caption_entry(catalog_entry_id, anchor_frame_id \\ nil, opts \\ [])
      when is_binary(catalog_entry_id) and is_list(opts) do
    with {:ok, entry} <- load_playable_entry(catalog_entry_id, opts),
         {:ok, frames} <- load_caption_frames(catalog_entry_id, opts) do
      do_caption_frames(entry, frames, anchor_frame_id, opts)
    else
      :skip -> :ok
      {:error, _} = err -> err
    end
  end

  defp do_caption_frames(_entry, [], _anchor_frame_id, _opts), do: :ok

  defp do_caption_frames(entry, frames, anchor_frame_id, opts) do
    selected_frames = select_frames_for_caption(frames)
    jpegs = Enum.map(selected_frames, & &1.thumbnail_jpeg)
    caption_fn = Keyword.get(opts, :caption_fn, &VisualCaptionClient.caption_frames/2)
    embed_fn = Keyword.get(opts, :embed_fn, &maybe_embed_caption/2)
    upsert_fn = Keyword.get(opts, :upsert_fn, &upsert_caption_record/1)

    with {:ok, caption_result} <- caption_fn.(jpegs, opts) do
      {start_us, end_us} = compute_span_bounds(entry, selected_frames)
      resolved_frame_id = resolve_anchor_frame_id(anchor_frame_id, selected_frames)
      embed_info = embed_fn.(caption_result.caption_text, opts)

      attrs = %{
        camera_source_id: entry.camera_source_id,
        stream_profile_id: entry.stream_profile_id,
        catalog_entry_id: entry.id,
        visual_frame_id: resolved_frame_id,
        start_us: start_us,
        end_us: end_us,
        time_basis: entry.time_basis || :received,
        caption_text: caption_result.caption_text,
        action_tags: caption_result.action_tags,
        caption_embedding: embed_info.embedding,
        embedding_dim: embed_info.embedding_dim,
        vlm_model_id: caption_result.vlm_model_id,
        prompt_version: caption_result.prompt_version,
        embedder_model_id: embed_info.embedder_model_id,
        embedder_model_version: embed_info.embedder_model_version,
        generated_at: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      }

      case upsert_fn.(attrs) do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp select_frames_for_caption(frames) do
    smart_frames = Enum.filter(frames, &has_smart_detection?(&1.detections))
    pool = if smart_frames == [], do: frames, else: smart_frames
    VisualCaptionClient.uniform_sample(pool, @max_caption_frames)
  end

  defp compute_span_bounds(entry, selected_frames) do
    timestamps = Enum.map(selected_frames, & &1.timeline_ts_us)
    min_ts = Enum.min(timestamps, fn -> entry.timeline_start_us end)
    max_ts = Enum.max(timestamps, fn -> entry.timeline_end_us end)
    start_us = min(min_ts, max_ts)
    end_us = max(min_ts, max_ts)
    {start_us, end_us}
  end

  defp resolve_anchor_frame_id(anchor_frame_id, _frames)
       when is_binary(anchor_frame_id) and anchor_frame_id != "" do
    anchor_frame_id
  end

  defp resolve_anchor_frame_id(_, frames) do
    mid = Enum.at(frames, div(length(frames), 2))
    mid && mid.id
  end

  defp maybe_embed_caption(caption_text, opts) do
    case SemanticSearch.embed_text(
           caption_text,
           Keyword.put_new(opts, :embedder_timeout_ms, 1_500)
         ) do
      {:ok, %{vector: vec, model_id: model_id, model_version: model_version, embedding_dim: dim}} ->
        %{
          embedding: vec,
          embedding_dim: dim,
          embedder_model_id: model_id,
          embedder_model_version: model_version
        }

      {:error, reason} ->
        Logger.warning("Camera caption text embedding skipped (embedder unavailable)",
          reason: inspect(reason)
        )

        %{
          embedding: nil,
          embedding_dim: nil,
          embedder_model_id: nil,
          embedder_model_version: nil
        }
    end
  end

  defp load_playable_entry(catalog_entry_id, opts) do
    case Keyword.get(opts, :entry_loader) do
      fun when is_function(fun, 1) ->
        case fun.(catalog_entry_id) do
          {:ok, %{} = entry} ->
            if playable_entry?(entry), do: {:ok, entry}, else: :skip

          {:ok, nil} ->
            :skip

          {:error, _} = err ->
            err
        end

      _ ->
        case RecordingCatalogEntry
             |> Ash.Query.filter(id == ^catalog_entry_id)
             |> Ash.read_one(actor: @system_actor) do
          {:ok, %RecordingCatalogEntry{} = entry} ->
            if RecordingCatalogEntry.playable?(entry), do: {:ok, entry}, else: :skip

          {:ok, nil} ->
            :skip

          {:error, _} = err ->
            err
        end
    end
  end

  defp playable_entry?(%RecordingCatalogEntry{} = entry),
    do: RecordingCatalogEntry.playable?(entry)

  defp playable_entry?(%{} = entry) do
    not is_nil(Map.get(entry, :recording_block_id)) and
      Map.get(entry, :local_state) != :quarantined and
      is_nil(Map.get(entry, :quarantine_reason)) and
      (Map.get(entry, :local_state) == :present or Map.get(entry, :archive_state) == :verified)
  end

  defp load_caption_frames(catalog_entry_id, opts) do
    case Keyword.get(opts, :frames_loader) do
      fun when is_function(fun, 1) ->
        fun.(catalog_entry_id)

      _ ->
        sql = """
        SELECT id, timeline_ts_us, detections, thumbnail_jpeg
        FROM platform.camera_visual_frames
        WHERE catalog_entry_id = $1::uuid
          AND thumbnail_jpeg IS NOT NULL
        ORDER BY timeline_ts_us ASC, fragment_sequence ASC
        LIMIT 64
        """

        case SQL.query(Repo, sql, [Ecto.UUID.dump!(catalog_entry_id)]) do
          {:ok, %{rows: rows}} ->
            frames =
              Enum.map(rows, fn [id, ts_us, detections, jpeg] ->
                %{
                  id: decode_uuid(id),
                  timeline_ts_us: ts_us,
                  detections: List.wrap(detections),
                  thumbnail_jpeg: jpeg
                }
              end)

            {:ok, frames}

          {:error, _} = err ->
            err
        end
    end
  end

  defp upsert_caption_record(attrs) do
    VisualClipCaption
    |> Ash.Changeset.for_create(:upsert_caption, attrs, actor: @system_actor)
    |> Ash.create(actor: @system_actor)
  end

  defp default_insert(changeset) do
    case Oban.Registry.whereis(Oban) do
      nil -> :noop
      _pid -> Oban.insert(changeset)
    end
  end

  defp decode_uuid(<<_::128>> = bin) do
    case Ecto.UUID.load(bin) do
      {:ok, str} -> str
      :error -> bin
    end
  end

  defp decode_uuid(str) when is_binary(str), do: str
  defp decode_uuid(other), do: to_string(other)
end
