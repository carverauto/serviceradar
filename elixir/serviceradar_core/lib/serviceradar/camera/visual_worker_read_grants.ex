defmodule ServiceRadar.Camera.VisualWorkerReadGrants do
  @moduledoc """
  Execution-time scoped fragment read grants (`POST /v1/media/workers/read-grants`)
  for standalone `serviceradar-media-worker` workloads (`1.6`, `design.md` `2.3`).

  - Authenticates workload-scoped callers (`media_worker` purpose / system actor;
    never human RBAC or cross-domain tokens).
  - Validates `job_id`, `catalog_entry_id`, and `descriptor_sha256` against live
    `VisualIndexJob` and `RecordingCatalogEntry` state before any job state
    transition.
  - Returns `{:error, :recording_gone}` (`410 Gone`) when the verified catalog
    entry is absent, has no `recording_block_id`, has `quarantine_reason` set,
    has `local_state == :quarantined`, or is terminally deleted
    (`local_state == :reclaimed` and `archive_state in [:deleted, :not_required]`),
    cancelling only the matching active job row.
  - Coalesces adjacent sampled fragment byte ranges into chunks `<= 4 MiB` while
    preserving exact `init_sha256` and per-fragment `sha256` digests from the
    frozen descriptor.
  - Backs reads either by:
    - `:archive` (`archive_state == :verified`): `ArchiveBinding` destination,
      `NVRArchiveReceipt` `init.mp4` and `media.m4s` keys/ETags/versions, two
      short-lived (`ttl_seconds`, default `300`, max `900`) AWS SigV4 pre-signed
      `GET` URLs (`X-Amz-SignedHeaders=host`, `UNSIGNED-PAYLOAD`, plus `versionId`
      when present) signed inside Core, and a `:reader`-only (`["HEAD", "GET"]`)
      `CredentialBrokerGrant` resolved via `ArchiveCredentialResolver` from
      `platform.network_credential_secrets` with `%RedactedCredential{}` redacting
      secrets on both `Inspect` and `Jason.Encoder` so S3 secret keys never cross
      the wire; OR
    - `:local` (`local_state == :present`): owning NVR member target and
      `analysis_read` pool descriptor plan.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.ArchiveStorageHTTP
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexJob

  require Ash.Query

  defmodule RedactedCredential do
    @moduledoc """
    Execution-time archive reader credential wrapper (`1.6`).

    Redacts secret material on both `Inspect` and `Jason.Encoder` so secret bytes
    can never be logged, inspected, or echoed in HTTP responses.
    """

    @derive {Inspect,
             except: [
               :access_key_id,
               :secret_access_key,
               :session_token,
               :headers,
               :credential
             ]}

    @derive {Jason.Encoder, only: [:reference, :generation, :role, :secret_id]}

    defstruct [
      :reference,
      :generation,
      :role,
      :secret_id,
      :access_key_id,
      :secret_access_key,
      :session_token,
      :headers,
      :credential
    ]

    @type t :: %__MODULE__{
            reference: String.t() | nil,
            generation: pos_integer() | nil,
            role: :reader | String.t() | nil,
            secret_id: String.t() | nil,
            access_key_id: String.t() | nil,
            secret_access_key: String.t() | nil,
            session_token: String.t() | nil,
            headers: map() | list() | nil,
            credential: map() | nil
          }
  end

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @max_init_bytes 1_048_576
  @max_chunk_bytes 4_194_304
  @max_coalesce_gap_bytes 262_144
  @default_ttl_seconds 300
  @max_ttl_seconds 900
  @system_actor SystemActor.system(:camera_visual_worker_read_grants)

  @doc "Maximum byte length of a single coalesced fragment range (`4 MiB`)."
  @spec max_chunk_bytes() :: pos_integer()
  def max_chunk_bytes, do: @max_chunk_bytes

  @doc """
  Issues a short-lived execution-time fragment read grant for an active
  `VisualIndexJob`.

  Supports both `issue_read_grant(installation, params, opts)` and
  `issue_read_grant(params, opts)`.
  """
  @spec issue_read_grant(map(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def issue_read_grant(installation_or_params, params_or_opts \\ %{}, opts \\ [])

  def issue_read_grant(params, opts, []) when is_map(params) and is_list(opts) do
    do_issue_read_grant(%{purpose: :media_worker}, params, opts)
  end

  def issue_read_grant(installation, params, opts)
      when is_map(installation) and is_map(params) and is_list(opts) do
    do_issue_read_grant(installation, params, opts)
  end

  def issue_read_grant(_, _, _), do: {:error, :invalid_read_grant_request}

  defp do_issue_read_grant(installation, params, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = normalize_ttl(Keyword.get(opts, :ttl_seconds, @default_ttl_seconds))
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- authorize_worker_caller(installation, opts),
         {:ok, req} <- validate_request(params),
         {:ok, job} <- load_and_check_job(req, installation, loaders),
         {:ok, entry} <- load_and_check_catalog_entry(req, job, loaders),
         {:ok, descriptor} <- load_frozen_descriptor(entry, loaders),
         {:ok, init_slice} <- extract_init_slice(descriptor, entry),
         {:ok, fragments} <- resolve_sampled_fragments(job, descriptor) do
      coalesced = coalesce_fragment_ranges(fragments)
      expires_at = DateTime.shift(now, second: ttl_seconds)

      build_backing_grant(
        installation,
        entry,
        job,
        init_slice,
        fragments,
        coalesced,
        ttl_seconds,
        now,
        expires_at,
        opts,
        loaders
      )
    end
  end

  @doc """
  Coalesces ordered sampled fragments into contiguous byte-range chunks bounded
  at `<= 4 MiB` (`4_194_304` bytes) while preserving exact per-fragment offsets
  and SHA-256 digests.
  """
  @spec coalesce_fragment_ranges([map()]) :: [map()]
  def coalesce_fragment_ranges([]), do: []

  def coalesce_fragment_ranges(fragments) when is_list(fragments) do
    sorted = Enum.sort_by(fragments, & &1.offset)

    chunks_rev =
      Enum.reduce(sorted, [], fn frag, acc ->
        append_or_coalesce_fragment(frag, acc)
      end)

    chunks_rev
    |> Enum.reverse()
    |> Enum.map(&finalize_chunk/1)
  end

  defp append_or_coalesce_fragment(frag, []) do
    [new_chunk(frag)]
  end

  defp append_or_coalesce_fragment(frag, [current | rest]) do
    frag_last = frag.offset + frag.length - 1
    gap = frag.offset - (current.last + 1)
    merged_len = frag_last - current.first + 1

    if gap >= 0 and gap <= @max_coalesce_gap_bytes and merged_len <= @max_chunk_bytes do
      updated = %{
        current
        | last: frag_last,
          fragments_rev: [frag | current.fragments_rev]
      }

      [updated | rest]
    else
      [new_chunk(frag), current | rest]
    end
  end

  defp new_chunk(frag) do
    %{
      first: frag.offset,
      last: frag.offset + frag.length - 1,
      fragments_rev: [frag]
    }
  end

  defp finalize_chunk(chunk) do
    frags = Enum.reverse(chunk.fragments_rev)
    chunk_first = chunk.first
    chunk_len = chunk.last - chunk.first + 1

    %{
      "first" => chunk_first,
      "last" => chunk.last,
      "length" => chunk_len,
      "fragment_sequences" => Enum.map(frags, & &1.sequence),
      "slices" =>
        Enum.map(frags, fn f ->
          %{
            "sequence" => f.sequence,
            "offset" => f.offset,
            "relative_offset" => f.offset - chunk_first,
            "length" => f.length,
            "start_ns" => f.start_ns,
            "duration_ns" => f.duration_ns,
            "sha256" => f.sha256
          }
        end)
    }
  end

  # ---------------------------------------------------------------------------
  # Validation & State Verification
  # ---------------------------------------------------------------------------

  defp authorize_worker_caller(installation, opts) do
    purpose = fetch_val(installation, :purpose) || fetch_val(installation, :auth_domain)

    invalid_domain? =
      not is_nil(purpose) and
        purpose not in [:media_worker, "media_worker", :vantage_worker, "vantage_worker"]

    cond do
      invalid_domain? ->
        {:error, :unauthorized_worker}

      Keyword.has_key?(opts, :actor) ->
        case Keyword.get(opts, :actor) do
          %{role: :system} -> :ok
          %{workload_purpose: wp} when wp in [:media_worker, :vantage_worker] -> :ok
          _ -> {:error, :unauthorized_worker}
        end

      true ->
        :ok
    end
  end

  defp validate_request(params) when is_map(params) do
    with :ok <- validate_optional_schema_version(params),
         {:ok, job_id} <- cast_uuid_field(fetch_val(params, :job_id), :invalid_job_id),
         {:ok, entry_id} <-
           cast_uuid_field(fetch_val(params, :catalog_entry_id), :invalid_catalog_entry_id),
         {:ok, desc_sha} <- parse_hex64_field(fetch_val(params, :descriptor_sha256)) do
      {:ok,
       %{
         job_id: job_id,
         catalog_entry_id: entry_id,
         descriptor_sha256: desc_sha
       }}
    end
  end

  defp cast_uuid_field(value, error_atom) do
    case cast_uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_atom}
    end
  end

  defp parse_hex64_field(value) do
    case parse_hex64(value) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :invalid_descriptor_sha256}
    end
  end

  defp validate_optional_schema_version(params) do
    case fetch_val(params, :schema_version) do
      nil -> :ok
      1 -> :ok
      _ -> {:error, :invalid_schema_version}
    end
  end

  defp load_and_check_catalog_entry(req, job, loaders) do
    with {:ok, entry} <- load_catalog_entry(req.catalog_entry_id, loaders),
         :ok <- verify_entry_descriptor_sha(req.descriptor_sha256, entry) do
      case RecordingCatalogEntry.availability(entry) do
        :playable ->
          {:ok, entry}

        :recording_gone ->
          with :ok <- cancel_matching_job(job, req, loaders) do
            {:error, :recording_gone}
          end

        :recording_unavailable ->
          {:error, :recording_unavailable}
      end
    end
  end

  defp load_and_check_job(req, installation, loaders) do
    case load_job(req.job_id, installation, loaders) do
      {:ok, nil} ->
        {:error, :job_not_found}

      {:ok, job} ->
        job_entry_id = to_string(fetch_val(job, :catalog_entry_id) || "")
        job_sha = fetch_val(job, :descriptor_sha256)
        state = normalize_job_state(fetch_val(job, :state))

        cond do
          job_entry_id != req.catalog_entry_id ->
            {:error, :job_catalog_mismatch}

          job_sha != req.descriptor_sha256 ->
            {:error, :descriptor_sha256_mismatch}

          state == :cancelled ->
            {:error, :recording_gone}

          state in [:completed, :failed_terminal] ->
            {:error, :job_already_terminal}

          state in [:pending, :dispatched] ->
            {:ok, job}

          true ->
            {:error, :invalid_job_state}
        end

      {:error, _} = err ->
        err
    end
  end

  defp verify_entry_descriptor_sha(_req_sha, nil), do: :ok

  defp verify_entry_descriptor_sha(req_sha, entry) do
    if req_sha == fetch_val(entry, :descriptor_sha256) do
      :ok
    else
      {:error, :descriptor_sha256_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # Descriptor & Fragment Slicing
  # ---------------------------------------------------------------------------

  defp extract_init_slice(descriptor, entry) do
    init = Map.get(descriptor, "init") || Map.get(descriptor, :init)
    entry_init_sha = fetch_val(entry, :init_sha256)

    with %{} <- init,
         length when is_integer(length) and length in 1..@max_init_bytes <-
           fetch_val(init, :length),
         {:ok, sha} <- parse_hex64(fetch_val(init, :sha256)),
         true <- is_nil(entry_init_sha) or sha == entry_init_sha do
      {:ok,
       %{
         "object_name" => "init.mp4",
         "offset" => 0,
         "first" => 0,
         "last" => length - 1,
         "length" => length,
         "sha256" => sha
       }}
    else
      _ -> {:error, :invalid_recording_descriptor}
    end
  end

  defp resolve_sampled_fragments(job, descriptor) do
    desc_fragments = Map.get(descriptor, "fragments") || Map.get(descriptor, :fragments) || []
    by_seq = Map.new(desc_fragments, &{fetch_val(&1, :sequence), &1})

    requested =
      case fetch_val(job, :sampled_fragments) do
        list when is_list(list) and list != [] ->
          list

        _ ->
          case sampled_fragments_from_targets(fetch_val(job, :sampled_targets)) do
            list when is_list(list) and list != [] ->
              list

            _ ->
              VisualIndexDispatcher.sample_descriptor_fragments(descriptor, 2000, 64)
          end
      end

    requested
    |> Enum.reduce_while({:ok, []}, fn req_frag, {:ok, acc} ->
      seq = fetch_val(req_frag, :sequence)

      case Map.get(by_seq, seq) do
        nil ->
          {:halt, {:error, :fragment_not_found}}

        authoritative ->
          validate_authoritative_fragment(authoritative, acc)
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_sampled_fragments}
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp validate_authoritative_fragment(frag, acc) do
    seq = fetch_val(frag, :sequence)
    offset = fetch_val(frag, :offset)
    length = fetch_val(frag, :length)
    start_ns = fetch_val(frag, :start_ns) || 0
    duration_ns = fetch_val(frag, :duration_ns) || 0
    sha = fetch_val(frag, :sha256)

    cond do
      not (is_integer(seq) and seq >= 0 and is_integer(offset) and offset >= 0 and
             is_integer(length) and length > 0) ->
        {:halt, {:error, :invalid_recording_descriptor}}

      length > @max_chunk_bytes ->
        {:halt, {:error, :recording_range_too_large}}

      not (is_binary(sha) and Regex.match?(@hex64, sha)) ->
        {:halt, {:error, :invalid_recording_descriptor}}

      true ->
        item = %{
          sequence: seq,
          offset: offset,
          length: length,
          first: offset,
          last: offset + length - 1,
          start_ns: start_ns,
          duration_ns: duration_ns,
          sha256: sha
        }

        {:cont, {:ok, [item | acc]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Transport Backing (:archive preferred when verified, else :local)
  # ---------------------------------------------------------------------------

  defp build_backing_grant(
         installation,
         entry,
         job,
         init_slice,
         fragments,
         coalesced,
         ttl_seconds,
         now,
         expires_at,
         opts,
         loaders
       ) do
    archive_state = normalize_atom(fetch_val(entry, :archive_state))
    local_state = normalize_atom(fetch_val(entry, :local_state))

    cond do
      archive_state == :verified ->
        build_archive_grant(
          installation,
          entry,
          job,
          init_slice,
          fragments,
          coalesced,
          ttl_seconds,
          now,
          expires_at,
          opts,
          loaders
        )

      local_state == :present ->
        build_local_grant(
          entry,
          job,
          init_slice,
          fragments,
          coalesced,
          ttl_seconds,
          expires_at,
          opts,
          loaders
        )

      true ->
        {:error, :recording_unavailable}
    end
  end

  defp build_archive_grant(
         _installation,
         entry,
         job,
         init_slice,
         fragments,
         coalesced,
         ttl_seconds,
         now,
         expires_at,
         opts,
         loaders
       ) do
    with {:ok, binding} <- load_archive_binding(entry, loaders),
         {:ok, receipt} <- load_archive_receipt(entry, binding, loaders),
         {:ok, init_obj, media_obj} <-
           verify_archive_objects(entry, binding, receipt, init_slice, fragments),
         {:ok, broker_grant, redacted_cred} <-
           resolve_archive_reader_grant(binding, ttl_seconds, now, opts, loaders),
         {:ok, init_presigned_url, media_presigned_url} <-
           presign_archive_object_urls(
             binding,
             init_obj,
             media_obj,
             redacted_cred,
             ttl_seconds,
             now
           ) do
      {:ok,
       %{
         schema_version: 1,
         backing: :archive,
         source: "archive",
         job_id: to_string(fetch_val(job, :id)),
         catalog_entry_id: to_string(fetch_val(entry, :id)),
         camera_source_id: to_string(fetch_val(entry, :camera_source_id)),
         stream_profile_id: to_string(fetch_val(entry, :stream_profile_id)),
         storage_id: to_string(fetch_val(entry, :storage_id)),
         block_key: fetch_val(entry, :block_key),
         descriptor_sha256: fetch_val(entry, :descriptor_sha256),
         init_sha256: init_slice["sha256"],
         ttl_seconds: ttl_seconds,
         expires_at: DateTime.to_iso8601(expires_at),
         init:
           Map.merge(init_slice, %{
             "key" => init_obj["key"],
             "etag" => init_obj["etag"],
             "version_id" => Map.get(init_obj, "version_id"),
             "presigned_url" => init_presigned_url
           }),
         media: %{
           "object_name" => "media.m4s",
           "key" => media_obj["key"],
           "length" => media_obj["length"],
           "sha256" => media_obj["sha256"],
           "etag" => media_obj["etag"],
           "version_id" => Map.get(media_obj, "version_id"),
           "presigned_url" => media_presigned_url
         },
         fragments: Enum.map(fragments, &serialize_fragment/1),
         coalesced_ranges: coalesced,
         archive: %{
           "binding_id" => to_string(fetch_val(binding, :id)),
           "provider" => fetch_val(binding, :provider),
           "endpoint" => fetch_val(binding, :endpoint),
           "region" => fetch_val(binding, :region),
           "bucket" => fetch_val(binding, :bucket),
           "namespace" => fetch_val(binding, :namespace),
           "required_encryption" => fetch_val(binding, :required_encryption),
           "destination_sha256" => fetch_val(binding, :destination_sha256),
           "init_key" => init_obj["key"],
           "init_etag" => init_obj["etag"],
           "init_presigned_url" => init_presigned_url,
           "media_key" => media_obj["key"],
           "media_etag" => media_obj["etag"],
           "media_presigned_url" => media_presigned_url
         },
         grant: broker_grant,
         credential: redacted_cred
       }}
    end
  end

  defp presign_archive_object_urls(
         binding,
         init_obj,
         media_obj,
         %RedactedCredential{} = redacted_cred,
         ttl_seconds,
         now
       ) do
    provider = %{
      credential: redacted_cred,
      destination: %{
        endpoint: fetch_val(binding, :endpoint),
        region: fetch_val(binding, :region),
        bucket: fetch_val(binding, :bucket)
      }
    }

    with {:ok, init_url} <-
           ArchiveStorageHTTP.presign_get_url(provider, init_obj["key"],
             expires: ttl_seconds,
             datetime: now,
             version_id: Map.get(init_obj, "version_id")
           ),
         {:ok, media_url} <-
           ArchiveStorageHTTP.presign_get_url(provider, media_obj["key"],
             expires: ttl_seconds,
             datetime: now,
             version_id: Map.get(media_obj, "version_id")
           ) do
      {:ok, init_url, media_url}
    end
  end

  defp build_local_grant(
         entry,
         job,
         init_slice,
         fragments,
         coalesced,
         ttl_seconds,
         expires_at,
         opts,
         loaders
       ) do
    storage_id = to_string(fetch_val(entry, :storage_id))
    block_key = fetch_val(entry, :block_key)

    case resolve_nvr_member(entry, storage_id, opts, loaders) do
      nvr_member when is_binary(nvr_member) and nvr_member != "" ->
        {:ok,
         %{
           schema_version: 1,
           backing: :local,
           source: "local",
           read_pool: "analysis_read",
           job_id: to_string(fetch_val(job, :id)),
           catalog_entry_id: to_string(fetch_val(entry, :id)),
           camera_source_id: to_string(fetch_val(entry, :camera_source_id)),
           stream_profile_id: to_string(fetch_val(entry, :stream_profile_id)),
           storage_id: storage_id,
           block_key: block_key,
           nvr_member: nvr_member,
           descriptor_sha256: fetch_val(entry, :descriptor_sha256),
           init_sha256: init_slice["sha256"],
           ttl_seconds: ttl_seconds,
           expires_at: DateTime.to_iso8601(expires_at),
           init: Map.put(init_slice, "path", "/v1/blocks/#{block_key}/init"),
           fragments:
             Enum.map(fragments, fn f ->
               f
               |> serialize_fragment()
               |> Map.put("path", "/v1/blocks/#{block_key}/fragments/#{f.sequence}")
             end),
           coalesced_ranges: coalesced,
           local: %{
             "nvr_member" => nvr_member,
             "storage_id" => storage_id,
             "block_key" => block_key,
             "pool" => "analysis_read",
             "purpose" => "analysis_read",
             "init_path" => "/v1/blocks/#{block_key}/init"
           }
         }}

      _ ->
        {:error, :recording_unavailable}
    end
  end

  defp serialize_fragment(f) do
    %{
      "sequence" => f.sequence,
      "offset" => f.offset,
      "first" => f.first,
      "last" => f.last,
      "length" => f.length,
      "start_ns" => f.start_ns,
      "duration_ns" => f.duration_ns,
      "sha256" => f.sha256
    }
  end

  # ---------------------------------------------------------------------------
  # Archive Binding, Receipt & Reader Credential Resolution
  # ---------------------------------------------------------------------------

  defp verify_archive_objects(entry, binding, receipt, init_slice, fragments) do
    namespace = fetch_val(binding, :namespace)
    sid = to_string(fetch_val(entry, :storage_id))
    bkey = to_string(fetch_val(entry, :block_key))
    expected_init_key = Enum.join([namespace, sid, bkey, "init.mp4"], "/")
    expected_media_key = Enum.join([namespace, sid, bkey, "media.m4s"], "/")
    objects = fetch_val(receipt, :objects) || []

    init_obj = find_receipt_object(objects, "init.mp4")
    media_obj = find_receipt_object(objects, "media.m4s")
    max_end = fragments |> Enum.map(&(&1.offset + &1.length)) |> Enum.max(fn -> 0 end)

    cond do
      is_nil(init_obj) or is_nil(media_obj) ->
        {:error, :archive_receipt_incomplete}

      init_obj["key"] != expected_init_key or media_obj["key"] != expected_media_key ->
        {:error, :archive_key_family_mismatch}

      init_obj["length"] != init_slice["length"] or init_obj["sha256"] != init_slice["sha256"] ->
        {:error, :archive_receipt_mismatch}

      not is_integer(media_obj["length"]) or max_end > media_obj["length"] ->
        {:error, :invalid_recording_range}

      true ->
        {:ok, init_obj, media_obj}
    end
  end

  defp find_receipt_object(objects, target_name) do
    Enum.find_value(objects, fn obj ->
      if fetch_val(obj, :name) == target_name do
        %{
          "name" => fetch_val(obj, :name),
          "key" => fetch_val(obj, :key),
          "length" => fetch_val(obj, :length),
          "sha256" => fetch_val(obj, :sha256),
          "etag" => fetch_val(obj, :etag),
          "version_id" => fetch_val(obj, :version_id)
        }
      end
    end)
  end

  defp resolve_archive_reader_grant(binding, ttl_seconds, now, opts, loaders) do
    custom = Keyword.get(opts, :credential_resolver) || Map.get(loaders, :credential_resolver)

    cond do
      is_function(custom, 3) ->
        normalize_custom_grant(custom.(binding, :reader, ttl_seconds), binding, ttl_seconds, now)

      is_function(custom, 2) ->
        normalize_custom_grant(custom.(binding, :reader), binding, ttl_seconds, now)

      true ->
        resolve_cnpg_reader_grant(binding, ttl_seconds, now, opts, loaders)
    end
  end

  defp normalize_custom_grant({:ok, %{grant: grant, credential: cred}}, _binding, _ttl, _now) do
    {:ok, serialize_broker_grant(grant), wrap_redacted_credential(cred, nil)}
  end

  defp normalize_custom_grant({:ok, doc}, binding, ttl_seconds, now) when is_map(doc) do
    secret_id = fetch_val(doc, :secret_id) || "00000000-0000-4000-8000-000000000001"

    {:ok, attrs} =
      ArchiveCredentialResolver.grant_attrs(binding, :reader, secret_id,
        ttl_seconds: ttl_seconds,
        now: now
      )

    {:ok, serialize_broker_grant(attrs), wrap_redacted_credential(doc, secret_id)}
  end

  defp normalize_custom_grant({:error, _} = err, _binding, _ttl, _now), do: err
  defp normalize_custom_grant(_, _binding, _ttl, _now), do: {:error, :archive_reader_unavailable}

  defp resolve_cnpg_reader_grant(binding, ttl_seconds, now, opts, loaders) do
    with {:ok, settings} <- load_archive_settings(loaders),
         secret_id when is_binary(secret_id) <-
           fetch_val(settings, :reader_credential_secret_id) ||
             fetch_val(settings, :writer_credential_secret_id) do
      resolver_opts =
        opts
        |> Keyword.take([:secret_loader, :grant_issuer, :broker, :audit?, :min_remaining_seconds])
        |> Keyword.merge(actor: @system_actor, ttl_seconds: ttl_seconds, now: now)

      with {:ok, grant} <-
             ArchiveCredentialResolver.issue_or_reuse_grant(
               binding,
               :reader,
               secret_id,
               resolver_opts
             ),
           :ok <- enforce_reader_only_grant(grant),
           {:ok, runtime_doc} <-
             ArchiveCredentialResolver.resolve_runtime_credential(
               binding,
               :reader,
               grant,
               resolver_opts
             ) do
        {:ok, serialize_broker_grant(grant), wrap_redacted_credential(runtime_doc, secret_id)}
      end
    else
      nil -> {:error, :archive_reader_credential_not_configured}
      {:error, _} = err -> err
    end
  end

  defp enforce_reader_only_grant(grant) do
    methods = fetch_val(grant, :allowed_methods) || []

    if Enum.sort(methods) == ["GET", "HEAD"] do
      :ok
    else
      {:error, :grant_methods_not_reader_only}
    end
  end

  defp serialize_broker_grant(grant) do
    expires_at =
      case fetch_val(grant, :expires_at) do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        iso when is_binary(iso) -> iso
        _ -> nil
      end

    %{
      "grant_id" => fetch_val(grant, :id) && to_string(fetch_val(grant, :id)),
      "grant_type" => fetch_val(grant, :grant_type) || "camera_archive_credential",
      "role" => "reader",
      "purpose" => fetch_val(grant, :purpose) || "camera_archive_read",
      "secret_ref" => fetch_val(grant, :secret_ref),
      "allowed_schemes" => fetch_val(grant, :allowed_schemes) || ["https"],
      "allowed_hosts" => fetch_val(grant, :allowed_hosts) || [],
      "allowed_ports" => fetch_val(grant, :allowed_ports) || [443],
      "allowed_paths" => fetch_val(grant, :allowed_paths) || [],
      "allowed_methods" => fetch_val(grant, :allowed_methods) || ["HEAD", "GET"],
      "expires_at" => expires_at
    }
  end

  defp wrap_redacted_credential(%RedactedCredential{} = cred, _default_secret_id), do: cred

  defp wrap_redacted_credential(doc, default_secret_id) when is_map(doc) do
    %RedactedCredential{
      reference: fetch_val(doc, :reference),
      generation: fetch_val(doc, :generation),
      role: :reader,
      secret_id: fetch_val(doc, :secret_id) || default_secret_id,
      access_key_id: fetch_val(doc, :access_key_id),
      secret_access_key: fetch_val(doc, :secret_access_key),
      session_token: fetch_val(doc, :session_token),
      headers: fetch_val(doc, :headers),
      credential: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Loaders & DB Helpers
  # ---------------------------------------------------------------------------

  defp load_catalog_entry(entry_id, loaders) do
    cond do
      is_function(Map.get(loaders, :entry_loader), 1) ->
        loaders.entry_loader.(entry_id)

      is_function(Map.get(loaders, :catalog_loader), 0) ->
        with {:ok, rows} <- loaders.catalog_loader.() do
          {:ok, Enum.find(rows, &(to_string(fetch_val(&1, :id)) == entry_id))}
        end

      map_size(loaders) > 0 ->
        {:ok, nil}

      true ->
        RecordingCatalogEntry
        |> Ash.Query.filter(id == ^entry_id)
        |> Ash.Query.load([:recording_block, :archive_binding, :nvr_archive_receipt])
        |> Ash.read_one(actor: @system_actor)
    end
  end

  defp load_job(job_id, installation, loaders) do
    case caller_purpose(installation) do
      purpose when purpose in [:vantage_worker, "vantage_worker"] ->
        load_vantage_only_job(job_id, loaders)

      purpose when purpose in [nil, :media_worker, "media_worker"] ->
        load_media_or_vantage_job(job_id, loaders)

      _ ->
        {:error, :unauthorized_worker}
    end
  end

  defp caller_purpose(installation) do
    fetch_val(installation, :purpose) || fetch_val(installation, :auth_domain)
  end

  defp load_vantage_only_job(job_id, loaders) do
    vantage_loader = Map.get(loaders, :vantage_job_loader)
    job_loader = Map.get(loaders, :job_loader)

    cond do
      is_function(vantage_loader, 1) ->
        filter_vantage_loader_result(vantage_loader.(job_id), fn job ->
          not is_struct(job, VisualIndexJob)
        end)

      is_function(job_loader, 1) ->
        filter_vantage_loader_result(job_loader.(job_id), &vantage_job?/1)

      map_size(loaders) > 0 ->
        {:ok, nil}

      true ->
        VantageJob.get_by_id(job_id, actor: @system_actor, not_found_error?: false)
    end
  end

  defp filter_vantage_loader_result({:ok, %{} = job}, accept?) do
    if accept?.(job), do: {:ok, job}, else: {:ok, nil}
  end

  defp filter_vantage_loader_result(other, _accept?), do: other

  defp load_media_or_vantage_job(job_id, loaders) do
    vantage_loader = Map.get(loaders, :vantage_job_loader)

    cond do
      is_function(Map.get(loaders, :job_loader), 1) ->
        case loaders.job_loader.(job_id) do
          {:ok, nil} when is_function(vantage_loader, 1) -> vantage_loader.(job_id)
          other -> other
        end

      is_function(vantage_loader, 1) ->
        vantage_loader.(job_id)

      map_size(loaders) > 0 ->
        {:ok, nil}

      true ->
        case VisualIndexJob.get_by_id(job_id, actor: @system_actor, not_found_error?: false) do
          {:ok, %VisualIndexJob{} = job} ->
            {:ok, job}

          {:ok, nil} ->
            VantageJob.get_by_id(job_id, actor: @system_actor, not_found_error?: false)

          {:error, _} = err ->
            err
        end
    end
  end

  defp cancel_matching_job(job, req, loaders) do
    cond do
      is_function(Map.get(loaders, :cancel_job_fn), 2) ->
        loaders.cancel_job_fn.(job, req)

      map_size(loaders) > 0 ->
        :ok

      true ->
        job_id = fetch_val(job, :id)
        resource = if vantage_job?(job), do: VantageJob, else: VisualIndexJob

        resource
        |> Ash.Query.filter(
          id == ^job_id and
            catalog_entry_id == ^req.catalog_entry_id and
            descriptor_sha256 == ^req.descriptor_sha256 and
            state in [:pending, :dispatched]
        )
        |> Ash.bulk_update(
          :mark_cancelled,
          %{last_error_class: "source_deleted_or_quarantined"},
          actor: @system_actor,
          strategy: [:atomic],
          return_errors?: true
        )
        |> case do
          %Ash.BulkResult{status: :success} -> :ok
          %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
        end
    end
  end

  defp vantage_job?(%VantageJob{}), do: true
  defp vantage_job?(job) when is_map(job), do: not is_nil(fetch_val(job, :pipeline_id))
  defp vantage_job?(_), do: false

  defp sampled_fragments_from_targets(targets) when is_list(targets) do
    targets
    |> Enum.reduce([], fn target, acc ->
      case fetch_val(target, :fragment_sequence) do
        seq when is_integer(seq) and seq >= 0 -> [seq | acc]
        _ -> acc
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{"sequence" => &1})
  end

  defp sampled_fragments_from_targets(_), do: []

  defp load_frozen_descriptor(entry, loaders) do
    direct =
      fetch_val(entry, :frozen_descriptor) ||
        fetch_val(entry, :descriptor) ||
        fetch_val(fetch_val(entry, :recording_block) || %{}, :descriptor)

    cond do
      is_map(direct) ->
        {:ok, direct}

      is_function(Map.get(loaders, :block_loader), 1) ->
        case loaders.block_loader.(fetch_val(entry, :recording_block_id)) do
          {:ok, %{descriptor: desc}} when is_map(desc) -> {:ok, desc}
          _ -> {:error, :recording_unavailable}
        end

      map_size(loaders) == 0 and not is_nil(fetch_val(entry, :recording_block_id)) ->
        case Ash.get(RecordingBlock, fetch_val(entry, :recording_block_id),
               actor: @system_actor,
               not_found_error?: false
             ) do
          {:ok, %RecordingBlock{descriptor: desc}} when is_map(desc) -> {:ok, desc}
          _ -> {:error, :recording_unavailable}
        end

      true ->
        {:error, :recording_unavailable}
    end
  end

  defp load_archive_binding(entry, loaders) do
    preloaded = fetch_val(entry, :archive_binding)
    binding_id = fetch_val(entry, :archive_binding_id)

    cond do
      is_map(preloaded) and not is_struct(preloaded, Ash.NotLoaded) and
          not is_nil(fetch_val(preloaded, :id)) ->
        {:ok, preloaded}

      is_nil(binding_id) ->
        {:error, :recording_unavailable}

      is_function(Map.get(loaders, :binding_loader), 1) ->
        case loaders.binding_loader.(binding_id) do
          {:ok, %{} = binding} -> {:ok, binding}
          _ -> {:error, :recording_unavailable}
        end

      map_size(loaders) > 0 ->
        {:error, :recording_unavailable}

      true ->
        case Ash.get(ArchiveBinding, binding_id, actor: @system_actor, not_found_error?: false) do
          {:ok, %ArchiveBinding{} = binding} -> {:ok, binding}
          _ -> {:error, :recording_unavailable}
        end
    end
  end

  defp load_archive_receipt(entry, binding, loaders) do
    preloaded = fetch_val(entry, :nvr_archive_receipt)
    receipt_id = fetch_val(entry, :nvr_archive_receipt_id)
    sid = fetch_val(entry, :storage_id)
    bkey = fetch_val(entry, :block_key)
    binding_id = fetch_val(binding, :id)

    cond do
      is_map(preloaded) and not is_struct(preloaded, Ash.NotLoaded) and
          is_list(fetch_val(preloaded, :objects)) ->
        {:ok, preloaded}

      is_function(Map.get(loaders, :receipt_loader), 1) ->
        case loaders.receipt_loader.(entry) do
          {:ok, %{} = r} -> {:ok, r}
          _ -> {:error, :recording_unavailable}
        end

      map_size(loaders) > 0 ->
        {:error, :recording_unavailable}

      not is_nil(receipt_id) ->
        case Ash.get(NVRArchiveReceipt, receipt_id, actor: @system_actor, not_found_error?: false) do
          {:ok, %NVRArchiveReceipt{} = r} -> {:ok, r}
          _ -> {:error, :recording_unavailable}
        end

      true ->
        NVRArchiveReceipt
        |> Ash.Query.filter(
          storage_id == ^sid and block_key == ^bkey and archive_binding_id == ^binding_id
        )
        |> Ash.read_one(actor: @system_actor)
        |> case do
          {:ok, %NVRArchiveReceipt{} = r} -> {:ok, r}
          _ -> {:error, :recording_unavailable}
        end
    end
  end

  defp load_archive_settings(loaders) do
    case Map.get(loaders, :settings_loader) do
      loader when is_function(loader, 0) -> loader.()
      _ when map_size(loaders) > 0 -> {:ok, RecordingArchiveSettings.default_settings()}
      _ -> RecordingArchiveSettings.get_settings(actor: @system_actor)
    end
  end

  defp resolve_nvr_member(entry, storage_id, opts, loaders) do
    from_map =
      opts
      |> Keyword.get(:member_by_storage_id, %{})
      |> Map.get(storage_id)

    entry_member = fetch_val(entry, :nvr_member)

    cond do
      non_empty_string?(from_map) ->
        String.trim(from_map)

      non_empty_string?(entry_member) ->
        String.trim(entry_member)

      is_function(Map.get(loaders, :policy_loader), 1) ->
        case loaders.policy_loader.(entry) do
          {:ok, pol} when is_map(pol) -> trim_non_empty(fetch_val(pol, :nvr_member))
          _ -> nil
        end

      map_size(loaders) > 0 ->
        nil

      true ->
        cam_id = fetch_val(entry, :camera_source_id)
        prof_id = fetch_val(entry, :stream_profile_id)

        case CameraRecordingPolicy.get_by_camera_profile(cam_id, prof_id,
               actor: @system_actor,
               not_found_error?: false
             ) do
          {:ok, %CameraRecordingPolicy{nvr_member: member}} -> trim_non_empty(member)
          _ -> nil
        end
    end
  end

  defp non_empty_string?(val) when is_binary(val), do: String.trim(val) != ""
  defp non_empty_string?(_), do: false

  defp trim_non_empty(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp trim_non_empty(_), do: nil

  defp normalize_ttl(ttl) when is_integer(ttl) and ttl in 1..@max_ttl_seconds, do: ttl
  defp normalize_ttl(_), do: @default_ttl_seconds

  defp cast_uuid(val) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

  defp parse_hex64(val) when is_binary(val) do
    if Regex.match?(@hex64, val), do: {:ok, val}, else: :error
  end

  defp parse_hex64(_), do: :error

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    allowed = RecordingCatalogEntry.local_states() ++ RecordingCatalogEntry.archive_states()
    Enum.find(allowed, &(Atom.to_string(&1) == val))
  end

  defp normalize_atom(_), do: nil

  defp normalize_job_state(val) when is_atom(val), do: val

  defp normalize_job_state(val) when is_binary(val) do
    allowed = Enum.uniq(VisualIndexJob.states() ++ VantageJob.states())
    Enum.find(allowed, &(Atom.to_string(&1) == val))
  end

  defp normalize_job_state(_), do: nil

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
