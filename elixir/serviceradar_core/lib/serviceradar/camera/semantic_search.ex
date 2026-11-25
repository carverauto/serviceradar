defmodule ServiceRadar.Camera.SemanticSearch do
  @moduledoc """
  Authorized natural-language semantic clip search over two-stage keyframe &
  subject-crop visual embeddings (`Stage 3.2` & `3.3`, `design.md` `3.4`, `5.1`, `5.2`).

  Enforces:
  - `devices.view` and `devices.cameras.recordings.view` RBAC permissions before
    any text-embedder RPC or database vector query runs.
  - Pre-filtered `ServiceRadar.Camera.Source` scope resolution so `pgvector` HNSW
    cosine k-NN executes strictly over `e.camera_source_id = ANY($authorized_camera_ids)`
    and playable non-quarantined `RecordingCatalogEntry` blocks.
  - Bounded in-memory ETS query embedding cache (`TTL = 60s`, max `1,024` entries)
    with a `250ms` fail-closed text-embedder NATS RPC budget (`{:error, :search_embedder_unavailable}`).
  - Temporal coalescing of adjacent keyframe hits into seekable clip intervals with
    explicit `time_basis` (`"received"` or `"camera_reported"`), capture-time camera
    labels, normalized `[x1, y1, x2, y2]` bounding boxes, and per-frame overlay
    detections.
  - Append-only `RecordingAccessAudit` (`event_kind: :semantic_search`) per search.
  """

  alias Ash.Error.Forbidden
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.NATS.Connection, as: NATSConnection
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @system_actor SystemActor.system(:camera_semantic_search)

  @required_permissions ["devices.view", "devices.cameras.recordings.view"]
  @allowed_object_classes ~w(person vehicle bicycle animal package)
  @color_pattern ~r/\A[a-z]{1,32}\z/

  @max_query_chars 256
  @default_window_us 86_400_000_000
  @max_window_us 31 * 86_400 * 1_000_000
  @default_limit 20
  @max_limit 50
  # SigLIP cosine similarity on true-positive surveillance matches sits around 0.04-0.15
  # (lower than OpenAI CLIP's 0.20+ scale); callers may still override `min_score` in 0.0..1.0.
  @default_min_score 0.04
  @default_coalesce_gap_us 6_000_000
  @default_clip_pad_us 2_000_000
  @rrf_k 60
  @rrf_weight_visual 1.0
  @rrf_weight_caption_fts 1.5
  @rrf_weight_caption_vector 1.0
  @rrf_max_score (@rrf_weight_visual + @rrf_weight_caption_fts + @rrf_weight_caption_vector) /
                   (@rrf_k + 1)

  @cache_table :camera_semantic_search_query_cache
  @cache_ttl_ms 60_000
  @cache_max_entries 1_024
  @default_embedder_timeout_ms 250
  @text_embed_schema "media.rpc.visual_text_embed.v1"

  @conversational_prefix_regex ~r/\A(?:(?:can\s+you\s+(?:please\s+)?|could\s+you\s+(?:please\s+)?|please\s+)?(?:show(?:\s+me)?|find(?:\s+me)?|search(?:\s+for)?|look\s+for|get(?:\s+me)?|give(?:\s+me)?)(?:\s+|\z)(?:(?:all|any|some)(?:\s+|\z))?(?:(?:of)(?:\s+|\z))?(?:(?:the)(?:\s+|\z))?(?:(?:videos?|clips?|footage|recordings?|events?)(?:\s+|\z))?(?:(?:that\s+(?:have|has|show|shows|feature|features|contain|contains)|of|with|where(?:\s+there\s+(?:is|are))?|showing|featuring|containing|involving|about)(?:\s+|\z))?|(?:(?:any|all|some|the)\s+)?(?:videos?|clips?|footage|recordings?|events?)\s+(?:that\s+(?:have|has|show|shows|feature|features|contain|contains)|of|with|where(?:\s+there\s+(?:is|are))?|showing|featuring|containing|involving|about)(?:\s+|\z))(?:(?:a|an|the)\s+)?/iu

  @fts_stopwords MapSet.new(~w(
    a an and are as at be been being by can could did do does doing
    for from get give had has have having he her hers him his how
    i if in into is it its just look me my no nor not of on or our
    please see she show showing some that the their them there these
    they this those to too up us very was we were what when where
    which who whom why will with would you your
    video videos clip clips footage recording recordings event events
    find search all any
  ))

  @visual_synonym_expansions %{
    "boy" => ~w(person child kid),
    "girl" => ~w(person child kid),
    "kid" => ~w(person child),
    "child" => ~w(person kid),
    "man" => ~w(person),
    "woman" => ~w(person),
    "guy" => ~w(person),
    "lady" => ~w(person),
    "someone" => ~w(person),
    "somebody" => ~w(person),
    "people" => ~w(person),
    "human" => ~w(person),
    "pedestrian" => ~w(person walking),
    "driver" => ~w(person),
    "puppy" => ~w(dog animal),
    "dog" => ~w(dog animal),
    "dogs" => ~w(dog animal),
    "pet" => ~w(animal dog cat),
    "cat" => ~w(cat animal),
    "cats" => ~w(cat animal),
    "kitten" => ~w(cat animal),
    "car" => ~w(vehicle car),
    "cars" => ~w(vehicle car),
    "suv" => ~w(vehicle car truck),
    "truck" => ~w(vehicle car truck),
    "trucks" => ~w(vehicle truck),
    "van" => ~w(vehicle car truck),
    "pickup" => ~w(vehicle truck),
    "sedan" => ~w(vehicle car),
    "vehicle" => ~w(vehicle car truck),
    "delivery" => ~w(package carrying),
    "box" => ~w(package carrying),
    "parcel" => ~w(package carrying),
    "package" => ~w(package box parcel carrying),
    "packages" => ~w(package box parcel carrying),
    "bike" => ~w(bicycle cyclist),
    "bicycle" => ~w(bicycle bike cyclist),
    "cyclist" => ~w(person bicycle bike)
  }

  @max_or_tsquery_terms 24

  @doc """
  Executes an authorized semantic clip search across recorded camera footage (`3.2`, `3.3`).
  """
  @spec search(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def search(params, opts \\ []) when (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, auth_ctx} <- authorize_caller(opts),
         {:ok, parsed} <- validate_search_params(attrs, now),
         {:ok, target_sources} <- resolve_target_camera_sources(auth_ctx, parsed, opts) do
      run_authorized_search(auth_ctx, parsed, target_sources, opts)
    end
  end

  @doc """
  Loads normalized subject-crop overlay detections for a specific `visual_frame_id`
  on an authorized `camera_source_id` (`Stage 4.3` deep-link highlight support).

  Verifies RBAC (`devices.view` + `devices.cameras.recordings.view`), camera `Source`
  scope, and playable non-quarantined `RecordingCatalogEntry` state before returning
  detections.
  """
  @spec get_frame_overlay(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def get_frame_overlay(camera_source_id, visual_frame_id, opts \\ [])
      when is_binary(camera_source_id) and is_binary(visual_frame_id) and is_list(opts) do
    with {:ok, auth_ctx} <- authorize_caller(opts),
         {:ok, cam_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         {:ok, frame_uuid} <- cast_uuid(visual_frame_id, :invalid_visual_frame_id),
         {:ok, sources_by_id} <- load_authorized_sources_map(auth_ctx, opts),
         :ok <- ensure_camera_authorized(cam_uuid, sources_by_id) do
      query_frame_overlay_detections(cam_uuid, frame_uuid, opts)
    end
  end

  @doc """
  Embeds a text string using the active SigLIP text-embedder RPC and returns the
  L2-normalized `Ash.Vector` along with active model metadata.

  Used by `ServiceRadar.Camera.VisualCaptionWorker` to embed generated clip captions
  into the same vector space as interactive search queries.
  """
  @spec embed_text(String.t(), keyword()) ::
          {:ok,
           %{
             vector: Ash.Vector.t(),
             model_id: String.t(),
             model_version: String.t(),
             embedding_dim: pos_integer()
           }}
          | {:error, term()}
  def embed_text(text, opts \\ []) when is_binary(text) and is_list(opts) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, :invalid_query}
    else
      model_cfg = VisualIndexDispatcher.active_model_config(opts)
      query_sha256 = sha256_hex(normalize_query_for_cache(trimmed))

      with {:ok, vec} <- resolve_query_embedding(trimmed, query_sha256, model_cfg, opts) do
        {:ok,
         %{
           vector: vec,
           model_id: model_cfg.embedder_model_id,
           model_version: model_cfg.embedder_model_version,
           embedding_dim: model_cfg.embedding_dim
         }}
      end
    end
  end

  @doc """
  Clears the in-memory ETS query text embedding cache (primarily for tests).
  """
  @spec clear_query_cache() :: :ok
  def clear_query_cache do
    case :ets.whereis(@cache_table) do
      :undefined -> :ok
      tid -> :ets.delete_all_objects(tid)
    end

    :ok
  end

  @doc """
  Strips leading conversational search preambles (e.g. `"show me videos with a ..."`,
  `"find clips of a ..."`, `"can you please show me ..."`) so both SigLIP text
  embeddings and PostgreSQL caption FTS focus on the visual subject.

  Falls back to the original trimmed query if stripping empties it.
  """
  @spec clean_search_query(String.t()) :: String.t()
  def clean_search_query(query) when is_binary(query) do
    trimmed =
      query
      |> String.trim()
      |> String.replace(~r/\s+/u, " ")

    if trimmed == "" do
      ""
    else
      stripped =
        trimmed
        |> String.replace(@conversational_prefix_regex, "")
        |> String.trim()
        |> String.trim_trailing("?")
        |> String.trim()

      if stripped == "", do: trimmed, else: stripped
    end
  end

  def clean_search_query(_), do: ""

  @doc """
  Frames a cleaned visual query using SigLIP's canonical `"a photo of <subject>."`
  template unless the query already starts with a visual framing prefix.
  """
  @spec format_siglip_prompt(String.t()) :: String.t()
  def format_siglip_prompt(cleaned) when is_binary(cleaned) do
    trimmed = String.trim(cleaned)
    downcased = String.downcase(trimmed)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(downcased, "a photo of") or
        String.starts_with?(downcased, "an image of") or
          String.starts_with?(downcased, "a picture of") ->
        trimmed

      true ->
        body = String.trim_trailing(trimmed, ".")
        if body == "", do: trimmed, else: "a photo of #{body}."
    end
  end

  def format_siglip_prompt(_), do: ""

  @doc """
  Builds a strictly sanitized PostgreSQL `to_tsquery('english', ...)` disjunction
  (`"term1 | term2 | ..."`) from a natural-language search query.

  Strips conversational prefixes, keeps only lowercase `[a-z0-9]+` tokens, filters
  English stopwords and search filler words, and expands common visual-domain synonyms
  (e.g. `boy` -> `person`, `dog` -> `animal`, `truck` -> `vehicle`) so partial and
  IR/nighttime caption matches rank cleanly instead of returning zero hits.

  Returns `""` when no alphanumeric tokens remain.
  """
  @spec build_or_tsquery_input(String.t()) :: String.t()
  def build_or_tsquery_input(query) when is_binary(query) do
    cleaned = clean_search_query(query)

    raw_tokens =
      ~r/[a-z0-9]+/
      |> Regex.scan(String.downcase(cleaned))
      |> List.flatten()

    content_tokens =
      Enum.filter(raw_tokens, fn tok ->
        String.length(tok) >= 2 and not MapSet.member?(@fts_stopwords, tok)
      end)

    seed_tokens = if content_tokens == [], do: raw_tokens, else: content_tokens

    seed_tokens
    |> Enum.flat_map(fn tok ->
      [tok | Map.get(@visual_synonym_expansions, tok, [])]
    end)
    |> Enum.uniq()
    |> Enum.take(@max_or_tsquery_terms)
    |> Enum.join(" | ")
  end

  def build_or_tsquery_input(_), do: ""

  # ---------------------------------------------------------------------------
  # Search execution pipeline
  # ---------------------------------------------------------------------------

  defp run_authorized_search(auth_ctx, parsed, target_sources, opts) do
    model_cfg = VisualIndexDispatcher.active_model_config(opts)
    effective_ids = target_sources |> Map.keys() |> Enum.sort()
    cleaned_query = clean_search_query(parsed.query)
    embed_prompt = format_siglip_prompt(cleaned_query)
    parsed = Map.put(parsed, :cleaned_query, cleaned_query)
    query_sha256 = sha256_hex(normalize_query_for_cache(cleaned_query))

    if effective_ids == [] do
      with :ok <-
             append_search_audit(
               auth_ctx,
               parsed,
               model_cfg,
               query_sha256,
               auth_ctx_total_count(target_sources),
               0,
               [],
               opts
             ) do
        {:ok, build_search_response(parsed.query, model_cfg, [])}
      end
    else
      with {:ok, query_vec} <-
             resolve_query_embedding(embed_prompt, query_sha256, model_cfg, opts),
           {:ok, raw_candidates} <-
             execute_vector_candidates_query(
               query_vec,
               model_cfg,
               effective_ids,
               parsed,
               target_sources,
               opts
             ),
           {:ok, caption_candidates} <-
             execute_caption_candidates_query(
               query_vec,
               model_cfg,
               effective_ids,
               parsed,
               target_sources,
               opts
             ) do
        coalesce_gap_us =
          clamp_int(
            Keyword.get(opts, :coalesce_gap_us, @default_coalesce_gap_us),
            0,
            60_000_000
          )

        visual_clips =
          coalesce_candidates_into_clips(raw_candidates, target_sources, coalesce_gap_us)

        clips =
          visual_clips
          |> fuse_hybrid_rrf(caption_candidates, target_sources, parsed)
          |> Enum.take(parsed.limit)

        with :ok <-
               append_search_audit(
                 auth_ctx,
                 parsed,
                 model_cfg,
                 query_sha256,
                 Map.get(auth_ctx, :authorized_total, map_size(target_sources)),
                 length(effective_ids),
                 clips,
                 opts
               ) do
          {:ok, build_search_response(parsed.query, model_cfg, clips)}
        end
      end
    end
  end

  defp auth_ctx_total_count(target_sources), do: map_size(target_sources)

  defp build_search_response(query, model_cfg, results) do
    basis =
      Enum.find_value(results, & &1.time_basis) ||
        "received"

    uncertainty =
      Enum.find_value(results, & &1.time_uncertainty) ||
        "unmeasured"

    %{
      query: query,
      model_id: model_cfg.embedder_model_id,
      model_version: model_cfg.embedder_model_version,
      embedding_dim: model_cfg.embedding_dim,
      time_basis: basis,
      time_uncertainty: uncertainty,
      results: results
    }
  end

  # ---------------------------------------------------------------------------
  # Step 1: RBAC & Camera.Source scope enforcement
  # ---------------------------------------------------------------------------

  defp authorize_caller(opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || actor_from_scope(scope)

    cond do
      is_nil(actor) ->
        {:error, Forbidden.exception([])}

      system_actor?(actor) ->
        {:ok,
         %{
           actor: actor,
           scope: scope,
           actor_id: resolve_actor_id(actor),
           system?: true
         }}

      true ->
        permissions = resolve_permissions(scope, actor)

        if holds_search_permissions?(permissions) do
          enriched_actor = enrich_actor_map(actor, permissions)

          enriched_scope =
            if is_map(scope) and not is_struct(scope) do
              Map.put(scope, :permissions, permissions)
            else
              scope
            end

          {:ok,
           %{
             actor: enriched_actor,
             scope: enriched_scope,
             actor_id: resolve_actor_id(enriched_actor),
             system?: false
           }}
        else
          {:error, Forbidden.exception([])}
        end
    end
  end

  defp holds_search_permissions?(%MapSet{} = permissions) do
    Enum.all?(@required_permissions, &RBAC.Catalog.holds?(permissions, &1))
  end

  defp holds_search_permissions?(_), do: false

  defp resolve_permissions(%{permissions: %MapSet{} = perms}, _actor), do: perms
  defp resolve_permissions(_scope, %{permissions: %MapSet{} = perms}), do: perms

  defp resolve_permissions(%{user: user}, _actor) when is_map(user) do
    RBAC.permissions_for_user(user)
  end

  defp resolve_permissions(_scope, actor) when is_map(actor) do
    RBAC.permissions_for_user(actor)
  end

  defp resolve_permissions(_, _), do: MapSet.new()

  defp resolve_target_camera_sources(auth_ctx, parsed, opts) do
    with {:ok, authorized_by_id} <- load_authorized_sources_map(auth_ctx, opts) do
      auth_ctx = Map.put(auth_ctx, :authorized_total, map_size(authorized_by_id))

      case parsed.requested_camera_ids do
        nil ->
          _ = auth_ctx
          {:ok, authorized_by_id}

        requested_ids when is_list(requested_ids) ->
          if Enum.all?(requested_ids, &Map.has_key?(authorized_by_id, &1)) do
            {:ok, Map.take(authorized_by_id, requested_ids)}
          else
            {:error, Forbidden.exception([])}
          end
      end
    end
  end

  defp load_authorized_sources_map(auth_ctx, opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    source_reader = Keyword.get(opts, :source_reader) || Map.get(loaders, :sources_loader)

    raw_result =
      cond do
        is_function(source_reader, 1) ->
          source_reader.(auth_ctx.scope || auth_ctx.actor)

        is_function(source_reader, 0) ->
          source_reader.()

        map_size(loaders) > 0 and Map.has_key?(loaders, :sources) ->
          {:ok, List.wrap(loaders.sources)}

        auth_ctx.system? ->
          Ash.read(Source, actor: @system_actor)

        true ->
          Ash.read(Source, actor: auth_ctx.actor)
      end

    with {:ok, rows} <- raw_result do
      explicit_allow = extract_explicit_allowed_camera_ids(auth_ctx, opts)

      by_id =
        Enum.reduce(rows, %{}, fn row, acc ->
          case cast_uuid(fetch_val(row, :id), :invalid_camera_source_id) do
            {:ok, uuid} ->
              if allowed_by_explicit_set?(uuid, explicit_allow) do
                Map.put(acc, uuid, %{
                  id: uuid,
                  display_name: fetch_val(row, :display_name),
                  device_uid: fetch_val(row, :device_uid)
                })
              else
                acc
              end

            _ ->
              acc
          end
        end)

      {:ok, by_id}
    end
  end

  defp extract_explicit_allowed_camera_ids(auth_ctx, opts) do
    candidates = [
      Keyword.get(opts, :authorized_camera_source_ids),
      is_map(auth_ctx.scope) && Map.get(auth_ctx.scope, :authorized_camera_source_ids),
      is_map(auth_ctx.actor) && Map.get(auth_ctx.actor, :authorized_camera_source_ids)
    ]

    case Enum.find(candidates, &(is_list(&1) or match?(%MapSet{}, &1))) do
      nil ->
        nil

      list_or_set ->
        Enum.reduce(list_or_set, MapSet.new(), fn item, acc ->
          case Ecto.UUID.cast(to_string(item)) do
            {:ok, uuid} -> MapSet.put(acc, uuid)
            :error -> acc
          end
        end)
    end
  end

  defp allowed_by_explicit_set?(_uuid, nil), do: true
  defp allowed_by_explicit_set?(uuid, %MapSet{} = set), do: MapSet.member?(set, uuid)

  defp ensure_camera_authorized(cam_uuid, sources_by_id) do
    if Map.has_key?(sources_by_id, cam_uuid) do
      :ok
    else
      {:error, Forbidden.exception([])}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Input validation
  # ---------------------------------------------------------------------------

  defp validate_search_params(attrs, now) do
    raw_query = fetch_val(attrs, :query) || fetch_val(attrs, :q)

    with {:ok, query} <- validate_query_text(raw_query),
         {:ok, requested_camera_ids, single_camera_id} <- parse_requested_cameras(attrs),
         {:ok, stream_profile_id} <-
           cast_optional_uuid(fetch_val(attrs, :stream_profile_id), :invalid_stream_profile_id),
         {:ok, from_us, to_us} <- parse_search_window(attrs, now),
         {:ok, object_class} <- parse_object_class(fetch_val(attrs, :object_class)),
         {:ok, dominant_color} <-
           parse_dominant_color(fetch_val(attrs, :dominant_color) || fetch_val(attrs, :color)),
         {:ok, min_score} <- parse_min_score(fetch_val(attrs, :min_score)),
         {:ok, limit} <- parse_limit(fetch_val(attrs, :limit)) do
      {:ok,
       %{
         query: query,
         requested_camera_ids: requested_camera_ids,
         single_camera_id: single_camera_id,
         stream_profile_id: stream_profile_id,
         from_us: from_us,
         to_us: to_us,
         object_class: object_class,
         dominant_color: dominant_color,
         min_score: min_score,
         limit: limit
       }}
    end
  end

  defp validate_query_text(raw) when is_binary(raw) do
    trimmed = String.trim(raw)
    len = String.length(trimmed)

    if String.valid?(trimmed) and len >= 1 and len <= @max_query_chars do
      {:ok, trimmed}
    else
      {:error, :invalid_query}
    end
  end

  defp validate_query_text(_), do: {:error, :invalid_query}

  defp parse_requested_cameras(attrs) do
    single = fetch_val(attrs, :camera_source_id)
    many = fetch_val(attrs, :camera_source_ids)

    cond do
      is_binary(single) and String.trim(single) != "" ->
        with {:ok, uuid} <- cast_uuid(single, :invalid_camera_source_id) do
          {:ok, [uuid], uuid}
        end

      is_list(many) and many != [] ->
        parse_camera_uuid_list(many)

      not is_nil(single) and single != "" ->
        {:error, :invalid_camera_source_id}

      true ->
        {:ok, nil, nil}
    end
  end

  defp parse_camera_uuid_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case cast_uuid(raw, :invalid_camera_source_id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} ->
        uniq = rev |> Enum.reverse() |> Enum.uniq()
        single = if match?([_], uniq), do: hd(uniq)
        {:ok, uniq, single}

      err ->
        err
    end
  end

  defp parse_search_window(attrs, now) do
    raw_from = fetch_val(attrs, :from_us) || fetch_val(attrs, :from)
    raw_to = fetch_val(attrs, :to_us) || fetch_val(attrs, :to)
    now_us = DateTime.to_unix(now, :microsecond)

    with {:ok, parsed_to} <- parse_optional_ts_us(raw_to),
         {:ok, parsed_from} <- parse_optional_ts_us(raw_from) do
      to_us = parsed_to || now_us
      from_us = parsed_from || to_us - @default_window_us

      cond do
        from_us < 0 or to_us <= 0 or from_us >= to_us ->
          {:error, :invalid_time_window}

        to_us - from_us > @max_window_us ->
          {:error, :window_too_large}

        true ->
          {:ok, from_us, to_us}
      end
    end
  end

  defp parse_optional_ts_us(nil), do: {:ok, nil}
  defp parse_optional_ts_us(""), do: {:ok, nil}
  defp parse_optional_ts_us(v) when is_integer(v), do: {:ok, v}

  defp parse_optional_ts_us(v) when is_binary(v) do
    trimmed = String.trim(v)

    case Integer.parse(trimmed) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _offset} -> {:ok, DateTime.to_unix(dt, :microsecond)}
          _ -> {:error, :invalid_time_window}
        end
    end
  end

  defp parse_optional_ts_us(_), do: {:error, :invalid_time_window}

  defp parse_object_class(nil), do: {:ok, nil}
  defp parse_object_class(""), do: {:ok, nil}

  defp parse_object_class(val) when is_binary(val) do
    normalized = val |> String.trim() |> String.downcase()

    if normalized in @allowed_object_classes do
      {:ok, normalized}
    else
      {:error, :invalid_object_class}
    end
  end

  defp parse_object_class(val) when is_atom(val), do: parse_object_class(Atom.to_string(val))
  defp parse_object_class(_), do: {:error, :invalid_object_class}

  defp parse_dominant_color(nil), do: {:ok, nil}
  defp parse_dominant_color(""), do: {:ok, nil}

  defp parse_dominant_color(val) when is_binary(val) do
    normalized = val |> String.trim() |> String.downcase()

    if Regex.match?(@color_pattern, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_color}
    end
  end

  defp parse_dominant_color(val) when is_atom(val), do: parse_dominant_color(Atom.to_string(val))
  defp parse_dominant_color(_), do: {:error, :invalid_color}

  defp parse_min_score(nil), do: {:ok, @default_min_score}
  defp parse_min_score(""), do: {:ok, @default_min_score}

  defp parse_min_score(val) when is_number(val) and val >= 0.0 and val <= 1.0,
    do: {:ok, val * 1.0}

  defp parse_min_score(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {num, ""} when num >= 0.0 and num <= 1.0 -> {:ok, num}
      _ -> {:error, :invalid_min_score}
    end
  end

  defp parse_min_score(_), do: {:error, :invalid_min_score}

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(""), do: {:ok, @default_limit}

  defp parse_limit(val) when is_integer(val) and val >= 1 and val <= @max_limit, do: {:ok, val}

  defp parse_limit(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {num, ""} when num >= 1 and num <= @max_limit -> {:ok, num}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_), do: {:error, :invalid_limit}

  # ---------------------------------------------------------------------------
  # Step 3: ETS query embedding cache + 250ms text-embedder RPC
  # ---------------------------------------------------------------------------

  defp resolve_query_embedding(query, query_sha256, model_cfg, opts) do
    cache_key = {
      model_cfg.embedder_model_id,
      model_cfg.embedder_model_version,
      model_cfg.embedding_dim,
      query_sha256
    }

    bypass_cache? = Keyword.get(opts, :bypass_cache, false) == true

    case if(bypass_cache?, do: :miss, else: cache_lookup(cache_key)) do
      {:ok, cached_floats} ->
        Ash.Vector.new(cached_floats)

      :miss ->
        with {:ok, raw_vec} <- invoke_text_embedder(query, model_cfg, opts),
             {:ok, normalized_floats} <- normalize_query_vector(raw_vec, model_cfg.embedding_dim),
             {:ok, vec} <- Ash.Vector.new(normalized_floats) do
          if not bypass_cache?, do: cache_insert(cache_key, normalized_floats)
          {:ok, vec}
        else
          _ -> {:error, :search_embedder_unavailable}
        end
    end
  end

  defp invoke_text_embedder(query, model_cfg, opts) do
    timeout_ms =
      clamp_int(
        Keyword.get(opts, :embedder_timeout_ms, @default_embedder_timeout_ms),
        10,
        2_000
      )

    embed_ctx = %{
      model_id: model_cfg.embedder_model_id,
      model_version: model_cfg.embedder_model_version,
      embedding_dim: model_cfg.embedding_dim,
      timeout_ms: timeout_ms
    }

    embedder =
      Keyword.get(opts, :text_embedder) ||
        Application.get_env(:serviceradar_core, :camera_semantic_text_embedder)

    cond do
      is_function(embedder, 2) ->
        run_with_deadline(fn -> embedder.(query, embed_ctx) end, timeout_ms)

      is_function(embedder, 1) ->
        run_with_deadline(fn -> embedder.(query) end, timeout_ms)

      match?({mod, fun} when is_atom(mod) and is_atom(fun), embedder) ->
        {mod, fun} = embedder
        run_with_deadline(fn -> apply(mod, fun, [query, embed_ctx]) end, timeout_ms)

      is_atom(embedder) and not is_nil(embedder) ->
        run_with_deadline(fn -> embedder.embed_text(query, embed_ctx) end, timeout_ms)

      true ->
        request_nats_text_embedding(query, embed_ctx)
    end
  end

  defp run_with_deadline(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, vec}} -> {:ok, vec}
      {:ok, vec} when is_list(vec) or is_struct(vec, Ash.Vector) -> {:ok, vec}
      _ -> {:error, :search_embedder_unavailable}
    end
  end

  defp request_nats_text_embedding(query, embed_ctx) do
    subject =
      "#{@text_embed_schema}.#{embed_ctx.model_id}.#{embed_ctx.model_version}"

    payload =
      Jason.encode!(%{
        schema: @text_embed_schema,
        query: query,
        model_id: embed_ctx.model_id,
        model_version: embed_ctx.model_version,
        expected_dim: embed_ctx.embedding_dim,
        deadline_ms: embed_ctx.timeout_ms
      })

    with {:ok, conn} <- NATSConnection.get(),
         {:ok, %{body: body}} <-
           Gnat.request(conn, subject, payload, receive_timeout: embed_ctx.timeout_ms),
         {:ok, decoded} <- Jason.decode(body),
         vec when is_list(vec) <- Map.get(decoded, "embedding") || Map.get(decoded, "vector") do
      {:ok, vec}
    else
      _ -> {:error, :search_embedder_unavailable}
    end
  rescue
    _ -> {:error, :search_embedder_unavailable}
  catch
    :exit, _ -> {:error, :search_embedder_unavailable}
  end

  defp normalize_query_vector(%Ash.Vector{} = vec, expected_dim) do
    vec |> Ash.Vector.to_list() |> normalize_query_vector(expected_dim)
  end

  defp normalize_query_vector(values, expected_dim) when is_list(values) do
    if length(values) == expected_dim do
      normalize_float_list(values)
    else
      {:error, :embedding_dim_mismatch}
    end
  end

  defp normalize_query_vector(_, _), do: {:error, :invalid_embedding}

  defp normalize_float_list(values) do
    floats =
      Enum.reduce_while(values, [], fn
        v, acc when is_float(v) -> {:cont, [v | acc]}
        v, acc when is_integer(v) -> {:cont, [v * 1.0 | acc]}
        _, _acc -> {:halt, :invalid}
      end)

    case floats do
      :invalid ->
        {:error, :invalid_embedding}

      rev ->
        ordered = Enum.reverse(rev)
        sum_sq = Enum.reduce(ordered, 0.0, fn x, acc -> acc + x * x end)
        norm = :math.sqrt(sum_sq)

        if norm > 1.0e-6 do
          {:ok, Enum.map(ordered, &(&1 / norm))}
        else
          {:error, :zero_norm_embedding}
        end
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @cache_table
        end

      tid ->
        tid
    end
  end

  defp cache_lookup(key) do
    tid = ensure_cache_table()
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(tid, key) do
      [{^key, vec, expires_ms, _inserted_ms}] when expires_ms > now_ms ->
        {:ok, vec}

      [{^key, _vec, _expired_ms, _inserted_ms}] ->
        :ets.delete(tid, key)
        :miss

      [] ->
        :miss
    end
  end

  defp cache_insert(key, vec) do
    tid = ensure_cache_table()
    now_ms = System.monotonic_time(:millisecond)
    maybe_evict_cache(tid, now_ms)
    :ets.insert(tid, {key, vec, now_ms + @cache_ttl_ms, now_ms})
    :ok
  end

  defp maybe_evict_cache(tid, now_ms) do
    size = :ets.info(tid, :size)

    if is_integer(size) and size >= @cache_max_entries do
      entries = :ets.tab2list(tid)

      {expired, live} =
        Enum.split_with(entries, fn {_k, _v, exp_ms, _ins_ms} -> exp_ms <= now_ms end)

      Enum.each(expired, fn {k, _, _, _} -> :ets.delete(tid, k) end)

      remaining = length(live)

      if remaining >= @cache_max_entries do
        drop_count = remaining - @cache_max_entries + 64

        live
        |> Enum.sort_by(fn {_k, _v, _exp, ins_ms} -> ins_ms end)
        |> Enum.take(max(drop_count, 1))
        |> Enum.each(fn {k, _, _, _} -> :ets.delete(tid, k) end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4: Pre-filtered pgvector HNSW k-NN execution
  # ---------------------------------------------------------------------------

  defp execute_vector_candidates_query(
         %Ash.Vector{} = query_vec,
         model_cfg,
         effective_ids,
         parsed,
         _target_sources,
         opts
       ) do
    loaders = Keyword.get(opts, :loaders, %{})

    if is_function(Map.get(loaders, :embeddings_loader), 2) do
      loaders.embeddings_loader.(Ash.Vector.to_list(query_vec), %{
        model_id: model_cfg.embedder_model_id,
        model_version: model_cfg.embedder_model_version,
        embedding_dim: model_cfg.embedding_dim,
        camera_source_ids: effective_ids,
        parsed: parsed
      })
    else
      query_postgres_candidates(query_vec, model_cfg, effective_ids, parsed)
    end
  end

  defp query_postgres_candidates(query_vec, model_cfg, effective_ids, parsed) do
    dim = if model_cfg.embedding_dim == 512, do: 512, else: 768
    candidate_limit = clamp_int(parsed.limit * 8, 64, 400)
    cam_bins = Enum.map(effective_ids, &Ecto.UUID.dump!/1)

    {extra_sql, extra_params, next_idx} =
      build_optional_sql_predicates(parsed, 7)

    limit_idx = next_idx

    sql = """
    SELECT
      e.id,
      e.visual_frame_id,
      e.catalog_entry_id,
      e.camera_source_id,
      e.stream_profile_id,
      e.timeline_ts_us,
      e.region_kind,
      e.region_index,
      e.object_class,
      e.confidence,
      e.bbox,
      e.dominant_colors,
      f.time_basis,
      f.detections,
      c.timeline_start_us,
      c.timeline_end_us,
      c.time_uncertainty_us,
      (f.thumbnail_jpeg IS NOT NULL) AS has_frame_thumbnail,
      (c.thumbnail_jpeg IS NOT NULL) AS has_block_thumbnail,
      1.0 - ((e.embedding::vector(#{dim})) <=> ($1::vector(#{dim}))) AS similarity
    FROM platform.camera_visual_embeddings e
    JOIN platform.camera_visual_frames f
      ON f.id = e.visual_frame_id
    JOIN platform.camera_recording_catalog c
      ON c.id = e.catalog_entry_id
    WHERE e.embedding_dim = #{dim}
      AND e.model_id = $2
      AND e.model_version = $3
      AND e.camera_source_id = ANY($4::uuid[])
      AND e.timeline_ts_us >= $5
      AND e.timeline_ts_us < $6
      AND f.scene_suppressed = false
      AND c.recording_block_id IS NOT NULL
      AND c.local_state <> 'quarantined'
      AND c.quarantine_reason IS NULL
      AND (c.local_state = 'present' OR c.archive_state = 'verified')
      #{extra_sql}
    ORDER BY (e.embedding::vector(#{dim})) <=> ($1::vector(#{dim})) ASC,
             e.timeline_ts_us DESC,
             e.id ASC
    LIMIT $#{limit_idx}
    """

    params =
      [
        query_vec,
        model_cfg.embedder_model_id,
        model_cfg.embedder_model_version,
        cam_bins,
        parsed.from_us,
        parsed.to_us
      ] ++ extra_params ++ [candidate_limit]

    Repo.transaction(fn ->
      apply_hnsw_session_settings()

      case SQL.query(Repo, sql, params) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.map(&decode_candidate_row/1)
          |> Enum.filter(&(&1.score >= parsed.min_score))

        {:error, err} ->
          Repo.rollback(err)
      end
    end)
  end

  defp apply_hnsw_session_settings do
    set_local_guarded("SET LOCAL hnsw.ef_search = 80")
    set_local_guarded("SET LOCAL hnsw.iterative_scan = 'relaxed_order'")
    set_local_guarded("SET LOCAL hnsw.max_scan_tuples = 20000")
  end

  defp set_local_guarded(statement) do
    _ = SQL.query(Repo, "SAVEPOINT sr_visual_hnsw_guc", [])

    case SQL.query(Repo, statement, []) do
      {:ok, _} ->
        _ = SQL.query(Repo, "RELEASE SAVEPOINT sr_visual_hnsw_guc", [])
        :ok

      {:error, _} ->
        _ = SQL.query(Repo, "ROLLBACK TO SAVEPOINT sr_visual_hnsw_guc", [])
        _ = SQL.query(Repo, "RELEASE SAVEPOINT sr_visual_hnsw_guc", [])
        :ok
    end
  end

  defp build_optional_sql_predicates(parsed, start_idx) do
    {clauses, args, idx} =
      {[], [], start_idx}
      |> maybe_append_uuid_predicate("e.stream_profile_id", parsed.stream_profile_id)
      |> maybe_append_text_predicate("e.object_class", parsed.object_class)
      |> maybe_append_color_predicate(parsed.dominant_color)

    sql_fragment =
      case Enum.reverse(clauses) do
        [] -> ""
        list -> "AND " <> Enum.join(list, "\n      AND ")
      end

    {sql_fragment, Enum.reverse(args), idx}
  end

  defp maybe_append_uuid_predicate(acc, _col, nil), do: acc

  defp maybe_append_uuid_predicate({clauses, args, idx}, col, uuid) do
    {["#{col} = $#{idx}::uuid" | clauses], [Ecto.UUID.dump!(uuid) | args], idx + 1}
  end

  defp maybe_append_text_predicate(acc, _col, nil), do: acc

  defp maybe_append_text_predicate({clauses, args, idx}, col, val) do
    {["#{col} = $#{idx}" | clauses], [val | args], idx + 1}
  end

  defp maybe_append_color_predicate(acc, nil), do: acc

  defp maybe_append_color_predicate({clauses, args, idx}, color) do
    {["$#{idx} = ANY(e.dominant_colors)" | clauses], [color | args], idx + 1}
  end

  defp decode_candidate_row([
         emb_id,
         frame_id,
         catalog_id,
         cam_id,
         profile_id,
         timeline_ts_us,
         region_kind,
         region_index,
         object_class,
         confidence,
         bbox,
         dominant_colors,
         time_basis,
         detections,
         catalog_start_us,
         catalog_end_us,
         time_uncertainty_us,
         has_frame_thumbnail,
         has_block_thumbnail,
         similarity
       ]) do
    %{
      embedding_id: decode_uuid(emb_id),
      visual_frame_id: decode_uuid(frame_id),
      catalog_entry_id: decode_uuid(catalog_id),
      camera_source_id: decode_uuid(cam_id),
      stream_profile_id: decode_uuid(profile_id),
      timeline_ts_us: timeline_ts_us,
      region_kind: to_string(region_kind || "scene"),
      region_index: region_index || 0,
      object_class: object_class,
      confidence: confidence,
      bbox: format_bbox_list(bbox),
      dominant_colors: List.wrap(dominant_colors),
      time_basis: to_string(time_basis || "received"),
      detections: List.wrap(detections),
      catalog_start_us: catalog_start_us,
      catalog_end_us: catalog_end_us,
      time_uncertainty_us: time_uncertainty_us,
      has_frame_thumbnail: has_frame_thumbnail == true,
      has_block_thumbnail: has_block_thumbnail == true,
      score: clamp_score(similarity)
    }
  end

  # ---------------------------------------------------------------------------
  # Step 4b: Pre-filtered VLM caption FTS + caption_embedding k-NN candidates
  # ---------------------------------------------------------------------------

  defp execute_caption_candidates_query(
         %Ash.Vector{} = query_vec,
         model_cfg,
         effective_ids,
         parsed,
         _target_sources,
         opts
       ) do
    loaders = Keyword.get(opts, :loaders, %{})

    cond do
      is_function(Map.get(loaders, :captions_loader), 2) ->
        loaders.captions_loader.(Ash.Vector.to_list(query_vec), %{
          query: parsed.query,
          cleaned_query: Map.get(parsed, :cleaned_query, parsed.query),
          model_id: model_cfg.embedder_model_id,
          model_version: model_cfg.embedder_model_version,
          embedding_dim: model_cfg.embedding_dim,
          camera_source_ids: effective_ids,
          parsed: parsed
        })

      is_function(Map.get(loaders, :embeddings_loader), 2) ->
        # DB-free test injected embeddings_loader without captions_loader.
        {:ok, []}

      true ->
        query_postgres_caption_candidates(query_vec, model_cfg, effective_ids, parsed)
    end
  end

  defp query_postgres_caption_candidates(query_vec, model_cfg, effective_ids, parsed) do
    dim = if model_cfg.embedding_dim == 512, do: 512, else: 768
    candidate_limit = clamp_int(parsed.limit * 4, 32, 200)
    cam_bins = Enum.map(effective_ids, &Ecto.UUID.dump!/1)
    cleaned_query = Map.get(parsed, :cleaned_query) || clean_search_query(parsed.query)
    or_tsquery_input = build_or_tsquery_input(cleaned_query)

    {profile_sql, profile_params, limit_idx} =
      if parsed.stream_profile_id do
        {"AND cap.stream_profile_id = $7::uuid", [Ecto.UUID.dump!(parsed.stream_profile_id)], 8}
      else
        {"", [], 7}
      end

    fts_rank_expr = """
    (
      (CASE
         WHEN q.and_tsq IS NOT NULL AND cap.caption_tsv @@ q.and_tsq
           THEN 2.5 * ts_rank_cd(cap.caption_tsv, q.and_tsq)
         ELSE 0.0
       END)
      +
      (CASE
         WHEN q.or_tsq IS NOT NULL AND cap.caption_tsv @@ q.or_tsq
           THEN ts_rank_cd(cap.caption_tsv, q.or_tsq)
         ELSE 0.0
       END)
    )::double precision
    """

    sql = """
    WITH q AS (
      SELECT
        websearch_to_tsquery('english', $1) AS and_tsq,
        to_tsquery('english', NULLIF($2, '')) AS or_tsq
    ),
    fts_hits AS (
      SELECT
        cap.id,
        cap.catalog_entry_id,
        cap.visual_frame_id,
        cap.camera_source_id,
        cap.stream_profile_id,
        cap.start_us,
        cap.end_us,
        cap.time_basis,
        cap.caption_text,
        cap.action_tags,
        c.timeline_start_us,
        c.timeline_end_us,
        c.time_uncertainty_us,
        (f.thumbnail_jpeg IS NOT NULL) AS has_frame_thumbnail,
        (c.thumbnail_jpeg IS NOT NULL) AS has_block_thumbnail,
        #{fts_rank_expr} AS fts_rank,
        CASE
          WHEN cap.caption_embedding IS NOT NULL AND cap.embedding_dim = #{dim}
            THEN (1.0 - ((cap.caption_embedding::vector(#{dim})) <=> ($3::vector(#{dim}))))::double precision
          ELSE NULL
        END AS caption_similarity
      FROM platform.camera_visual_clip_captions cap
      CROSS JOIN q
      JOIN platform.camera_recording_catalog c
        ON c.id = cap.catalog_entry_id
      LEFT JOIN platform.camera_visual_frames f
        ON f.id = cap.visual_frame_id
      WHERE cap.camera_source_id = ANY($4::uuid[])
        AND cap.start_us < $6
        AND cap.end_us >= $5
        AND c.recording_block_id IS NOT NULL
        AND c.local_state <> 'quarantined'
        AND c.quarantine_reason IS NULL
        AND (c.local_state = 'present' OR c.archive_state = 'verified')
        AND (
          (q.or_tsq IS NOT NULL AND cap.caption_tsv @@ q.or_tsq)
          OR (q.and_tsq IS NOT NULL AND cap.caption_tsv @@ q.and_tsq)
        )
        #{profile_sql}
      ORDER BY fts_rank DESC, cap.start_us DESC
      LIMIT $#{limit_idx}
    ),
    vec_hits AS (
      SELECT
        cap.id,
        cap.catalog_entry_id,
        cap.visual_frame_id,
        cap.camera_source_id,
        cap.stream_profile_id,
        cap.start_us,
        cap.end_us,
        cap.time_basis,
        cap.caption_text,
        cap.action_tags,
        c.timeline_start_us,
        c.timeline_end_us,
        c.time_uncertainty_us,
        (f.thumbnail_jpeg IS NOT NULL) AS has_frame_thumbnail,
        (c.thumbnail_jpeg IS NOT NULL) AS has_block_thumbnail,
        #{fts_rank_expr} AS fts_rank,
        (1.0 - ((cap.caption_embedding::vector(#{dim})) <=> ($3::vector(#{dim}))))::double precision AS caption_similarity
      FROM platform.camera_visual_clip_captions cap
      CROSS JOIN q
      JOIN platform.camera_recording_catalog c
        ON c.id = cap.catalog_entry_id
      LEFT JOIN platform.camera_visual_frames f
        ON f.id = cap.visual_frame_id
      WHERE cap.camera_source_id = ANY($4::uuid[])
        AND cap.start_us < $6
        AND cap.end_us >= $5
        AND cap.caption_embedding IS NOT NULL
        AND cap.embedding_dim = #{dim}
        AND c.recording_block_id IS NOT NULL
        AND c.local_state <> 'quarantined'
        AND c.quarantine_reason IS NULL
        AND (c.local_state = 'present' OR c.archive_state = 'verified')
        #{profile_sql}
      ORDER BY (cap.caption_embedding::vector(#{dim})) <=> ($3::vector(#{dim})) ASC,
               cap.start_us DESC
      LIMIT $#{limit_idx}
    ),
    combined AS (
      SELECT * FROM fts_hits
      UNION ALL
      SELECT * FROM vec_hits
    )
    SELECT DISTINCT ON (id)
      id,
      catalog_entry_id,
      visual_frame_id,
      camera_source_id,
      stream_profile_id,
      start_us,
      end_us,
      time_basis,
      caption_text,
      action_tags,
      timeline_start_us,
      timeline_end_us,
      time_uncertainty_us,
      has_frame_thumbnail,
      has_block_thumbnail,
      fts_rank,
      caption_similarity
    FROM combined
    ORDER BY id, fts_rank DESC NULLS LAST, caption_similarity DESC NULLS LAST
    """

    params =
      [cleaned_query, or_tsquery_input, query_vec, cam_bins, parsed.from_us, parsed.to_us] ++
        profile_params ++ [candidate_limit]

    case SQL.query(Repo, sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &decode_caption_candidate_row/1)}

      {:error, reason} ->
        Logger.warning("Camera caption hybrid query skipped due to database error",
          reason: inspect(reason)
        )

        {:ok, []}
    end
  end

  defp decode_caption_candidate_row([
         id,
         catalog_id,
         frame_id,
         cam_id,
         profile_id,
         start_us,
         end_us,
         time_basis,
         caption_text,
         action_tags,
         catalog_start_us,
         catalog_end_us,
         time_uncertainty_us,
         has_frame_thumbnail,
         has_block_thumbnail,
         fts_rank,
         caption_similarity
       ]) do
    %{
      id: decode_uuid(id),
      catalog_entry_id: decode_uuid(catalog_id),
      visual_frame_id: if(frame_id, do: decode_uuid(frame_id), else: ""),
      camera_source_id: decode_uuid(cam_id),
      stream_profile_id: decode_uuid(profile_id),
      start_us: start_us,
      end_us: end_us,
      time_basis: to_string(time_basis || "received"),
      caption_text: caption_text,
      action_tags: List.wrap(action_tags),
      catalog_start_us: catalog_start_us,
      catalog_end_us: catalog_end_us,
      time_uncertainty_us: time_uncertainty_us,
      has_frame_thumbnail: has_frame_thumbnail == true,
      has_block_thumbnail: has_block_thumbnail == true,
      fts_rank: if(is_number(fts_rank), do: fts_rank * 1.0, else: 0.0),
      caption_similarity: if(is_number(caption_similarity), do: clamp_score(caption_similarity))
    }
  end

  # ---------------------------------------------------------------------------
  # Step 4c: Hybrid Reciprocal Rank Fusion (RRF) across visual + caption legs
  # ---------------------------------------------------------------------------

  defp fuse_hybrid_rrf(visual_clips, [], _sources_by_id, _parsed), do: visual_clips

  defp fuse_hybrid_rrf(visual_clips, caption_candidates, sources_by_id, parsed) do
    normalized_captions = Enum.map(caption_candidates, &normalize_caption_candidate/1)

    fts_ranked =
      normalized_captions
      |> Enum.filter(&(&1.fts_rank > 0.0))
      |> Enum.sort_by(fn c -> {-c.fts_rank, -c.start_us, c.catalog_entry_id} end)
      |> Enum.with_index(1)
      |> Map.new(fn {cap, rank} -> {caption_fusion_key(cap), {rank, cap}} end)

    cap_vec_ranked =
      normalized_captions
      |> Enum.filter(
        &(is_number(&1.caption_similarity) and &1.caption_similarity >= parsed.min_score)
      )
      |> Enum.sort_by(fn c -> {-c.caption_similarity, -c.start_us, c.catalog_entry_id} end)
      |> Enum.with_index(1)
      |> Map.new(fn {cap, rank} -> {caption_fusion_key(cap), {rank, cap}} end)

    if map_size(fts_ranked) == 0 and map_size(cap_vec_ranked) == 0 do
      attach_captions_to_visual_clips(visual_clips, normalized_captions)
    else
      visual_by_key =
        visual_clips
        |> Enum.with_index(1)
        |> Enum.reduce(%{}, fn {clip, rank}, acc ->
          key = clip_fusion_key(clip)
          Map.put_new(acc, key, {rank, clip})
        end)

      all_keys =
        Enum.uniq(Map.keys(visual_by_key) ++ Map.keys(fts_ranked) ++ Map.keys(cap_vec_ranked))

      all_keys
      |> Enum.map(fn key ->
        vis_entry = Map.get(visual_by_key, key)
        fts_entry = Map.get(fts_ranked, key)
        cap_vec_entry = Map.get(cap_vec_ranked, key)

        {rrf_raw, sources} =
          {0.0, []}
          |> add_rrf_leg(vis_entry, @rrf_weight_visual, "visual_vector")
          |> add_rrf_leg(fts_entry, @rrf_weight_caption_fts, "caption_fts")
          |> add_rrf_leg(cap_vec_entry, @rrf_weight_caption_vector, "caption_vector")

        fused_score = min(1.0, Float.round(rrf_raw / @rrf_max_score, 4))
        caption = pick_caption(fts_entry, cap_vec_entry)

        base_clip =
          case vis_entry do
            {_rank, clip} -> clip
            nil -> build_clip_from_caption(caption, sources_by_id, parsed)
          end

        base_clip
        |> Map.put(:score, fused_score)
        |> Map.put(:caption_text, caption && caption.caption_text)
        |> Map.put(:action_tags, if(caption, do: caption.action_tags, else: []))
        |> Map.put(:match_sources, Enum.reverse(sources))
      end)
      |> Enum.sort_by(fn clip ->
        {-clip.score, -clip.best_timeline_ts_us, to_string(clip.visual_frame_id)}
      end)
    end
  end

  defp attach_captions_to_visual_clips(visual_clips, normalized_captions) do
    captions_by_key =
      Map.new(normalized_captions, fn cap -> {caption_fusion_key(cap), cap} end)

    Enum.map(visual_clips, fn clip ->
      case Map.get(captions_by_key, clip_fusion_key(clip)) do
        nil ->
          clip

        cap ->
          clip
          |> Map.put(:caption_text, cap.caption_text)
          |> Map.put(:action_tags, cap.action_tags)
      end
    end)
  end

  defp add_rrf_leg(acc, nil, _weight, _label), do: acc

  defp add_rrf_leg({score, sources}, {rank, _item}, weight, label) do
    {score + weight / (@rrf_k + rank), [label | sources]}
  end

  defp pick_caption({_rank, cap}, _), do: cap
  defp pick_caption(nil, {_rank, cap}), do: cap
  defp pick_caption(nil, nil), do: nil

  defp clip_fusion_key(%{catalog_entry_id: cid}) when is_binary(cid) and cid != "", do: cid
  defp clip_fusion_key(clip), do: "#{clip.camera_source_id}:#{clip.best_timeline_ts_us}"

  defp caption_fusion_key(%{catalog_entry_id: cid}) when is_binary(cid) and cid != "", do: cid
  defp caption_fusion_key(cap), do: "#{cap.camera_source_id}:#{cap.start_us}"

  defp normalize_caption_candidate(item) do
    raw_fts = fetch_val(item, :fts_rank)
    raw_sim = fetch_val(item, :caption_similarity)

    %{
      id: to_string(fetch_val(item, :id) || ""),
      catalog_entry_id: to_string(fetch_val(item, :catalog_entry_id) || ""),
      visual_frame_id: to_string(fetch_val(item, :visual_frame_id) || ""),
      camera_source_id: to_string(fetch_val(item, :camera_source_id) || ""),
      stream_profile_id: to_string(fetch_val(item, :stream_profile_id) || ""),
      start_us: fetch_val(item, :start_us) || 0,
      end_us: fetch_val(item, :end_us) || fetch_val(item, :start_us) || 0,
      time_basis: to_string(fetch_val(item, :time_basis) || "received"),
      caption_text: fetch_val(item, :caption_text),
      action_tags: item |> fetch_val(:action_tags) |> List.wrap() |> Enum.map(&to_string/1),
      catalog_start_us: fetch_val(item, :catalog_start_us),
      catalog_end_us: fetch_val(item, :catalog_end_us),
      time_uncertainty_us: fetch_val(item, :time_uncertainty_us),
      has_frame_thumbnail: fetch_val(item, :has_frame_thumbnail),
      has_block_thumbnail: fetch_val(item, :has_block_thumbnail),
      fts_rank: if(is_number(raw_fts), do: raw_fts * 1.0, else: 0.0),
      caption_similarity: if(is_number(raw_sim), do: clamp_score(raw_sim))
    }
  end

  defp build_clip_from_caption(cap, sources_by_id, parsed) do
    mid_ts = div(cap.start_us + cap.end_us, 2)

    {clip_start_us, clip_end_us} =
      compute_clip_bounds(
        cap.start_us,
        cap.end_us,
        mid_ts,
        cap.catalog_start_us,
        cap.catalog_end_us
      )

    source_meta = Map.get(sources_by_id, cap.camera_source_id, %{})
    label = format_camera_label(Map.get(source_meta, :display_name))
    uncertainty = format_time_uncertainty(cap.time_basis, cap.time_uncertainty_us)

    %{
      catalog_entry_id: cap.catalog_entry_id,
      visual_frame_id: cap.visual_frame_id,
      camera_source_id: cap.camera_source_id,
      camera_display_name: label,
      device_uid: Map.get(source_meta, :device_uid),
      stream_profile_id: cap.stream_profile_id,
      clip_start_us: clip_start_us,
      clip_end_us: clip_end_us,
      best_timeline_ts_us: mid_ts,
      time_basis: cap.time_basis,
      time_uncertainty: uncertainty,
      score: 0.0,
      region_kind: "caption",
      object_class: parsed.object_class,
      dominant_colors: [],
      bbox: nil,
      frame_detections: [],
      has_frame_thumbnail: cap.has_frame_thumbnail,
      has_block_thumbnail: cap.has_block_thumbnail,
      caption_text: cap.caption_text,
      action_tags: cap.action_tags
    }
  end

  # ---------------------------------------------------------------------------
  # Step 5: Temporal clip coalescing & overlay projection
  # ---------------------------------------------------------------------------

  defp coalesce_candidates_into_clips(candidates, sources_by_id, coalesce_gap_us) do
    candidates
    |> Enum.map(&normalize_candidate_item/1)
    |> Enum.group_by(fn c -> {c.camera_source_id, c.stream_profile_id} end)
    |> Enum.flat_map(fn {_group_key, group} ->
      group
      |> Enum.sort_by(&{&1.timeline_ts_us, &1.visual_frame_id, &1.region_index})
      |> cluster_by_gap(coalesce_gap_us)
      |> Enum.map(&build_clip_from_cluster(&1, sources_by_id))
    end)
    |> Enum.sort_by(fn clip ->
      {-clip.score, -clip.best_timeline_ts_us, to_string(clip.visual_frame_id)}
    end)
  end

  defp normalize_candidate_item(item) do
    %{
      embedding_id: to_string(fetch_val(item, :embedding_id) || fetch_val(item, :id) || ""),
      visual_frame_id: to_string(fetch_val(item, :visual_frame_id) || ""),
      catalog_entry_id: to_string(fetch_val(item, :catalog_entry_id) || ""),
      camera_source_id: to_string(fetch_val(item, :camera_source_id) || ""),
      stream_profile_id: to_string(fetch_val(item, :stream_profile_id) || ""),
      timeline_ts_us: fetch_val(item, :timeline_ts_us) || 0,
      region_kind: to_string(fetch_val(item, :region_kind) || "scene"),
      region_index: fetch_val(item, :region_index) || 0,
      object_class: fetch_val(item, :object_class),
      confidence: fetch_val(item, :confidence),
      bbox: format_bbox_list(fetch_val(item, :bbox)),
      dominant_colors:
        item |> fetch_val(:dominant_colors) |> List.wrap() |> Enum.map(&to_string/1),
      time_basis: to_string(fetch_val(item, :time_basis) || "received"),
      detections: item |> fetch_val(:detections) |> List.wrap(),
      catalog_start_us: fetch_val(item, :catalog_start_us),
      catalog_end_us: fetch_val(item, :catalog_end_us),
      time_uncertainty_us: fetch_val(item, :time_uncertainty_us),
      has_frame_thumbnail: fetch_val(item, :has_frame_thumbnail),
      has_block_thumbnail: fetch_val(item, :has_block_thumbnail),
      score: clamp_score(fetch_val(item, :score) || fetch_val(item, :similarity) || 0.0)
    }
  end

  defp cluster_by_gap([], _gap_us), do: []

  defp cluster_by_gap([first | rest], gap_us) do
    {clusters, current, _last_ts} =
      Enum.reduce(rest, {[], [first], first.timeline_ts_us}, fn item, {acc, cur, prev_ts} ->
        if item.timeline_ts_us - prev_ts <= gap_us do
          {acc, [item | cur], max(prev_ts, item.timeline_ts_us)}
        else
          {[Enum.reverse(cur) | acc], [item], item.timeline_ts_us}
        end
      end)

    Enum.reverse([Enum.reverse(current) | clusters])
  end

  defp build_clip_from_cluster(cluster, sources_by_id) do
    best =
      Enum.max_by(cluster, fn item ->
        crop_bonus = if item.region_kind == "crop", do: 1, else: 0
        {Float.round(item.score, 6), crop_bonus, -item.timeline_ts_us}
      end)

    min_ts = cluster |> Enum.map(& &1.timeline_ts_us) |> Enum.min()
    max_ts = cluster |> Enum.map(& &1.timeline_ts_us) |> Enum.max()

    {clip_start_us, clip_end_us} =
      compute_clip_bounds(
        min_ts,
        max_ts,
        best.timeline_ts_us,
        best.catalog_start_us,
        best.catalog_end_us
      )

    source_meta = Map.get(sources_by_id, best.camera_source_id, %{})
    label = format_camera_label(Map.get(source_meta, :display_name))
    uncertainty = format_time_uncertainty(best.time_basis, best.time_uncertainty_us)
    frame_detections = build_cluster_frame_detections(cluster)

    %{
      catalog_entry_id: best.catalog_entry_id,
      visual_frame_id: best.visual_frame_id,
      camera_source_id: best.camera_source_id,
      camera_display_name: label,
      device_uid: Map.get(source_meta, :device_uid),
      stream_profile_id: best.stream_profile_id,
      clip_start_us: clip_start_us,
      clip_end_us: clip_end_us,
      best_timeline_ts_us: best.timeline_ts_us,
      time_basis: best.time_basis,
      time_uncertainty: uncertainty,
      score: Float.round(best.score, 4),
      region_kind: best.region_kind,
      object_class: best.object_class,
      dominant_colors: best.dominant_colors,
      bbox: best.bbox,
      frame_detections: frame_detections,
      has_frame_thumbnail: best.has_frame_thumbnail,
      has_block_thumbnail: best.has_block_thumbnail
    }
  end

  defp compute_clip_bounds(min_ts, max_ts, best_ts, catalog_start_us, catalog_end_us) do
    raw_start = max(min_ts - @default_clip_pad_us, 0)
    raw_end = max(max_ts + @default_clip_pad_us, best_ts + 1_000_000)

    clamped_start =
      if is_integer(catalog_start_us) and catalog_start_us <= best_ts do
        max(raw_start, catalog_start_us)
      else
        min(raw_start, best_ts)
      end

    clamped_end =
      if is_integer(catalog_end_us) and catalog_end_us > best_ts do
        min(raw_end, catalog_end_us)
      else
        max(raw_end, best_ts + 1)
      end

    final_end = if clamped_end > clamped_start, do: clamped_end, else: best_ts + 1_000_000
    {min(clamped_start, best_ts), max(final_end, best_ts + 1)}
  end

  defp build_cluster_frame_detections(cluster) do
    direct_crops =
      for item <- cluster,
          item.region_kind == "crop",
          is_list(item.bbox) do
        %{
          visual_frame_id: item.visual_frame_id,
          timeline_ts_us: item.timeline_ts_us,
          start_us: max(item.timeline_ts_us - 1_500_000, 0),
          end_us: item.timeline_ts_us + 1_500_000,
          bbox: item.bbox,
          object_class: item.object_class || "subject",
          score: Float.round(item.score, 4),
          dominant_colors: item.dominant_colors,
          time_basis: item.time_basis
        }
      end

    frame_level =
      for item <- cluster,
          det <- item.detections,
          is_map(det),
          bbox = format_bbox_list(fetch_val(det, :bbox)),
          is_list(bbox) do
        conf = fetch_val(det, :confidence)

        %{
          visual_frame_id: item.visual_frame_id,
          timeline_ts_us: item.timeline_ts_us,
          start_us: max(item.timeline_ts_us - 1_500_000, 0),
          end_us: item.timeline_ts_us + 1_500_000,
          bbox: bbox,
          object_class: to_string(fetch_val(det, :object_class) || "subject"),
          score:
            if(is_number(conf), do: Float.round(conf * 1.0, 4), else: Float.round(item.score, 4)),
          dominant_colors:
            det |> fetch_val(:dominant_colors) |> List.wrap() |> Enum.map(&to_string/1),
          time_basis: item.time_basis
        }
      end

    (direct_crops ++ frame_level)
    |> Enum.uniq_by(fn d -> {d.visual_frame_id, d.bbox, d.object_class} end)
    |> Enum.take(16)
  end

  # ---------------------------------------------------------------------------
  # Deep-link single-frame overlay lookup
  # ---------------------------------------------------------------------------

  defp query_frame_overlay_detections(cam_uuid, frame_uuid, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    if is_function(Map.get(loaders, :frame_overlay_loader), 2) do
      loaders.frame_overlay_loader.(cam_uuid, frame_uuid)
    else
      sql = """
      SELECT
        f.id,
        f.timeline_ts_us,
        f.time_basis,
        f.detections,
        e.object_class,
        e.confidence,
        e.bbox,
        e.dominant_colors
      FROM platform.camera_visual_frames f
      JOIN platform.camera_recording_catalog c
        ON c.id = f.catalog_entry_id
      LEFT JOIN platform.camera_visual_embeddings e
        ON e.visual_frame_id = f.id
       AND e.region_kind = 'crop'
      WHERE f.id = $1::uuid
        AND f.camera_source_id = $2::uuid
        AND c.recording_block_id IS NOT NULL
        AND c.local_state <> 'quarantined'
        AND c.quarantine_reason IS NULL
        AND (c.local_state = 'present' OR c.archive_state = 'verified')
      ORDER BY e.region_index ASC NULLS LAST
      LIMIT 16
      """

      case SQL.query(Repo, sql, [Ecto.UUID.dump!(frame_uuid), Ecto.UUID.dump!(cam_uuid)]) do
        {:ok, %{rows: []}} ->
          _ = VisualFrame
          {:ok, []}

        {:ok, %{rows: rows}} ->
          {:ok, build_overlay_rows(rows)}

        {:error, _} = err ->
          err
      end
    end
  end

  defp build_overlay_rows(rows) do
    crop_boxes =
      for [frame_id, ts_us, basis, _dets, obj_class, conf, bbox, colors] <- rows,
          box_list = format_bbox_list(bbox),
          is_list(box_list) do
        %{
          visual_frame_id: decode_uuid(frame_id),
          timeline_ts_us: ts_us,
          start_us: max(ts_us - 1_500_000, 0),
          end_us: ts_us + 1_500_000,
          bbox: box_list,
          object_class: to_string(obj_class || "subject"),
          score: if(is_number(conf), do: Float.round(conf * 1.0, 4), else: 0.0),
          dominant_colors: colors |> List.wrap() |> Enum.map(&to_string/1),
          time_basis: to_string(basis || "received")
        }
      end

    if crop_boxes == [] do
      extract_fallback_frame_detections(hd(rows))
    else
      Enum.uniq_by(crop_boxes, &{&1.visual_frame_id, &1.bbox, &1.object_class})
    end
  end

  defp extract_fallback_frame_detections([frame_id, ts_us, basis, dets | _rest]) do
    fid = decode_uuid(frame_id)

    for det <- List.wrap(dets),
        is_map(det),
        box_list = format_bbox_list(fetch_val(det, :bbox)),
        is_list(box_list) do
      conf = fetch_val(det, :confidence)

      %{
        visual_frame_id: fid,
        timeline_ts_us: ts_us,
        start_us: max(ts_us - 1_500_000, 0),
        end_us: ts_us + 1_500_000,
        bbox: box_list,
        object_class: to_string(fetch_val(det, :object_class) || "subject"),
        score: if(is_number(conf), do: Float.round(conf * 1.0, 4), else: 0.0),
        dominant_colors:
          det |> fetch_val(:dominant_colors) |> List.wrap() |> Enum.map(&to_string/1),
        time_basis: to_string(basis || "received")
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Step 6: Append-only RecordingAccessAudit (:semantic_search)
  # ---------------------------------------------------------------------------

  defp append_search_audit(
         auth_ctx,
         parsed,
         model_cfg,
         query_sha256,
         authorized_count,
         filtered_count,
         results,
         opts
       ) do
    loaders = Keyword.get(opts, :loaders, %{})

    audit_attrs = %{
      event_kind: :semantic_search,
      actor_id: auth_ctx.actor_id,
      camera_source_id: parsed.single_camera_id,
      stream_profile_id: parsed.stream_profile_id,
      window_start_us: parsed.from_us,
      window_end_us: parsed.to_us,
      details: %{
        "query_text" => parsed.query,
        "query_sha256" => query_sha256,
        "model_id" => model_cfg.embedder_model_id,
        "model_version" => model_cfg.embedder_model_version,
        "authorized_camera_count" => authorized_count,
        "filtered_camera_count" => filtered_count,
        "object_class_filter" => parsed.object_class,
        "dominant_color_filter" => parsed.dominant_color,
        "result_count" => length(results)
      }
    }

    cond do
      is_function(Map.get(loaders, :audit_writer), 1) ->
        case loaders.audit_writer.(audit_attrs) do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, _} = err -> err
        end

      map_size(loaders) > 0 and Map.get(loaders, :skip_db_audit, false) == true ->
        :ok

      true ->
        case RecordingAccessAudit.record(audit_attrs) do
          {:ok, _audit} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting & utility helpers
  # ---------------------------------------------------------------------------

  defp format_bbox_list([x1, y1, x2, y2])
       when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
    [
      Float.round(x1 * 1.0, 4),
      Float.round(y1 * 1.0, 4),
      Float.round(x2 * 1.0, 4),
      Float.round(y2 * 1.0, 4)
    ]
  end

  defp format_bbox_list(%{} = map) do
    x1 = fetch_val(map, :x1)
    y1 = fetch_val(map, :y1)
    x2 = fetch_val(map, :x2)
    y2 = fetch_val(map, :y2)

    if is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
      format_bbox_list([x1, y1, x2, y2])
    end
  end

  defp format_bbox_list(_), do: nil

  defp format_camera_label(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if trimmed == "" do
      "Unknown camera (historical revision unavailable)"
    else
      trimmed
    end
  end

  defp format_camera_label(_), do: "Unknown camera (historical revision unavailable)"

  defp format_time_uncertainty("camera_reported", uncertainty_us)
       when is_integer(uncertainty_us) and uncertainty_us >= 0 do
    "uncertainty_us=#{uncertainty_us}"
  end

  defp format_time_uncertainty(_basis, _uncertainty_us), do: "unmeasured"

  defp normalize_query_for_cache(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.join(" ")
  end

  defp sha256_hex(text) when is_binary(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = perms}) when is_map(user) do
    enrich_actor_map(user, perms)
  end

  defp actor_from_scope(%{actor: actor, permissions: %MapSet{} = perms}) when is_map(actor) do
    enrich_actor_map(actor, perms)
  end

  defp actor_from_scope(%{user: user}) when is_map(user), do: user
  defp actor_from_scope(%{actor: actor}) when is_map(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp enrich_actor_map(actor, %MapSet{} = perms) when is_struct(actor) do
    actor
    |> Map.from_struct()
    |> Map.take([:id, :email, :role, :role_profile_id, :partition_id])
    |> Map.put(:permissions, perms)
  end

  defp enrich_actor_map(actor, %MapSet{} = perms) when is_map(actor) do
    Map.put(actor, :permissions, perms)
  end

  defp system_actor?(%{role: :system}), do: true
  defp system_actor?(%{role: "system"}), do: true
  defp system_actor?(_), do: false

  defp resolve_actor_id(actor) when is_map(actor) do
    candidate = Map.get(actor, :id) || Map.get(actor, :email) || "system"
    trimmed = String.trim(to_string(candidate))
    if trimmed == "", do: "system", else: trimmed
  end

  defp decode_uuid(<<_::128>> = bin) do
    case Ecto.UUID.load(bin) do
      {:ok, str} -> str
      :error -> bin
    end
  end

  defp decode_uuid(str) when is_binary(str), do: str
  defp decode_uuid(other), do: to_string(other)

  defp cast_uuid(val, err_tag) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, err_tag}
    end
  end

  defp cast_uuid(_, err_tag), do: {:error, err_tag}

  defp cast_optional_uuid(nil, _err_tag), do: {:ok, nil}
  defp cast_optional_uuid("", _err_tag), do: {:ok, nil}
  defp cast_optional_uuid(val, err_tag), do: cast_uuid(val, err_tag)

  defp clamp_score(v) when is_number(v), do: v |> max(-1.0) |> min(1.0) |> Kernel.*(1.0)
  defp clamp_score(_), do: 0.0

  defp clamp_int(v, min_v, max_v) when is_integer(v), do: v |> max(min_v) |> min(max_v)
  defp clamp_int(_, min_v, _max_v), do: min_v

  defp to_map(params) when is_map(params), do: params
  defp to_map(params) when is_list(params), do: Map.new(params)

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
