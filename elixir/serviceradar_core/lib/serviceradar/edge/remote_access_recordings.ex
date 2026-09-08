defmodule ServiceRadar.Edge.RemoteAccessRecordings do
  @moduledoc """
  Policy-gated recording manifest lifecycle for remote-access sessions.

  This module creates storage/retention metadata and aggregate counters only.
  Terminal input/output payload persistence remains separately gated and is
  disabled unless trusted policy explicitly enables raw content recording.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordingEvent
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Repo

  @default_storage_backend "datasvc_object_store"
  @default_storage_bucket "remote-access-recordings"
  @default_storage_prefix "remote-access"
  @default_retention_days 30
  @default_stale_after_seconds 4 * 60 * 60
  @default_stale_batch_size 100
  @export_permission "devices.remote_access.recordings.export"
  @delete_permission "devices.remote_access.recordings.delete"
  @view_all_permission "devices.remote_access.recordings.view_all"
  @integrity_algorithm "hmac-sha256-v1"
  @integrity_key_context "serviceradar-remote-access-recording-integrity"

  @spec ensure_for_session(map() | struct(), keyword()) ::
          {:ok, RemoteAccessRecording.t() | nil} | {:error, term()}
  def ensure_for_session(session, opts \\ []) do
    policy = session |> value("recording_policy") |> normalize_policy()

    if enabled?(policy) do
      create_manifest(session, policy, opts)
    else
      {:ok, nil}
    end
  end

  @spec activate(RemoteAccessRecording.t() | nil, keyword()) ::
          {:ok, RemoteAccessRecording.t() | nil} | {:error, term()}
  def activate(recording, opts \\ [])
  def activate(nil, _opts), do: {:ok, nil}

  def activate(%RemoteAccessRecording{} = recording, opts) do
    with {:ok, updated} <-
           RemoteAccessRecording.mark_active(
             recording,
             %{started_at: RemoteAccessRecording.utc_now()},
             actor: system_actor(:active)
           ) do
      write_audit(:remote_access_recording_active, updated, opts)
      {:ok, updated}
    end
  end

  @spec complete(RemoteAccessRecording.t() | nil, map(), keyword()) ::
          {:ok, RemoteAccessRecording.t() | nil} | {:error, term()}
  def complete(recording, attrs, opts \\ [])
  def complete(nil, _attrs, _opts), do: {:ok, nil}

  def complete(%RemoteAccessRecording{} = recording, attrs, opts) when is_map(attrs) do
    with {:ok, updated} <- finish_recording(recording, attrs, :complete) do
      write_audit(:remote_access_recording_completed, updated, opts)
      {:ok, updated}
    end
  end

  @spec fail(RemoteAccessRecording.t() | nil, term(), map(), keyword()) ::
          {:ok, RemoteAccessRecording.t() | nil} | {:error, term()}
  def fail(recording, reason, attrs, opts \\ [])
  def fail(nil, _reason, _attrs, _opts), do: {:ok, nil}

  def fail(%RemoteAccessRecording{} = recording, reason, attrs, opts) when is_map(attrs) do
    with {:ok, updated} <- finish_recording(recording, attrs, :fail, reason) do
      write_audit(:remote_access_recording_failed, updated, opts)
      {:ok, updated}
    end
  end

  @spec expire(RemoteAccessRecording.t() | nil, map(), keyword()) ::
          {:ok, RemoteAccessRecording.t() | nil} | {:error, term()}
  def expire(recording, attrs, opts \\ [])
  def expire(nil, _attrs, _opts), do: {:ok, nil}

  def expire(%RemoteAccessRecording{} = recording, attrs, opts) when is_map(attrs) do
    with {:ok, updated} <- finish_recording(recording, attrs, :expire) do
      write_audit(:remote_access_recording_expired, updated, opts)
      {:ok, updated}
    end
  end

  @spec expire_stale(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expire_stale(opts \\ []) do
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)
    batch_size = Keyword.get(opts, :batch_size, @default_stale_batch_size)

    with {:ok, stale_recordings} <- stale_recording_stats(stale_after_seconds, batch_size) do
      Enum.reduce_while(stale_recordings, {:ok, 0}, fn stats, {:ok, count} ->
        case expire_stale_recording(stats, opts) do
          {:ok, %RemoteAccessRecording{}} -> {:cont, {:ok, count + 1}}
          {:ok, nil} -> {:cont, {:ok, count}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @spec record_event(RemoteAccessRecording.t() | nil, map(), keyword()) ::
          {:ok, RemoteAccessRecordingEvent.t() | nil} | {:error, term()}
  def record_event(recording, attrs, opts \\ [])
  def record_event(nil, _attrs, _opts), do: {:ok, nil}

  def record_event(%RemoteAccessRecording{} = recording, attrs, opts) when is_map(attrs) do
    fn ->
      with :ok <- lock_recording(recording.id),
           {:ok, %RemoteAccessRecording{} = current_recording} <-
             current_recording(recording),
           :ok <- ensure_recordable_status(current_recording),
           attrs = event_attrs(current_recording, attrs, opts),
           {:ok, event, notifications} <-
             RemoteAccessRecordingEvent.record(attrs,
               actor: system_actor(:event),
               return_notifications?: true
             ) do
        {event, notifications}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, {%RemoteAccessRecordingEvent{} = event, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec event_integrity_hash(RemoteAccessRecordingEvent.t()) :: String.t()
  def event_integrity_hash(%RemoteAccessRecordingEvent{} = event) do
    event
    |> event_integrity_payload()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec list_events(RemoteAccessRecording.t() | binary(), keyword()) ::
          {:ok, [RemoteAccessRecordingEvent.t()]} | {:error, term()}
  def list_events(recording_or_id, opts \\ [])

  def list_events(%RemoteAccessRecording{id: recording_id}, opts) do
    list_events_for_authorized_recording(recording_id, opts)
  end

  def list_events(recording_id, opts) when is_binary(recording_id) do
    with {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(recording_id, actor: system_actor(:event_lookup)) do
      list_events_for_authorized_recording(recording, opts)
    end
  end

  @spec export(RemoteAccessRecording.t() | binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def export(recording_or_id, opts \\ [])

  def export(%RemoteAccessRecording{} = recording, opts) do
    export_id = Ecto.UUID.generate()

    with :ok <- authorize_export(opts),
         {:ok, export} <- locked_export(recording, opts, export_id) do
      write_audit(
        :remote_access_recording_exported,
        export.recording,
        Keyword.put(opts, :export_id, export_id)
      )

      {:ok, export}
    end
  end

  def export(recording_id, opts) when is_binary(recording_id) do
    with :ok <- authorize_export(opts),
         {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(recording_id, scope_opts(opts)) do
      export(recording, opts)
    end
  end

  defp locked_export(%RemoteAccessRecording{} = recording, opts, export_id) do
    fn ->
      with :ok <- lock_recording(recording.id),
           {:ok, %RemoteAccessRecording{} = current_recording} <- current_recording(recording),
           :ok <- ensure_exportable_status(current_recording),
           {:ok, events} <- list_events(current_recording, opts),
           {:ok, event_integrity} <- verify_event_chain(events),
           {:ok, manifest_integrity} <-
             verify_manifest_integrity(current_recording.manifest, event_integrity) do
        %{
          recording: current_recording,
          manifest:
            export_manifest(
              current_recording,
              events,
              event_integrity,
              manifest_integrity,
              export_id
            ),
          events: events,
          export_id: export_id
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, export} -> {:ok, export}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_exportable_status(%RemoteAccessRecording{status: status})
       when status in [:completed, :failed, :expired],
       do: :ok

  defp ensure_exportable_status(%RemoteAccessRecording{status: :deleted}),
    do: {:error, :recording_deleted}

  defp ensure_exportable_status(_recording), do: {:error, :recording_not_exportable}

  defp current_recording(%RemoteAccessRecording{id: recording_id}) do
    RemoteAccessRecording.get_by_id(recording_id, actor: system_actor(:event_recording_lookup))
  end

  defp ensure_recordable_status(%RemoteAccessRecording{status: status})
       when status in [:pending, :active], do: :ok

  defp ensure_recordable_status(_recording), do: {:error, :recording_sealed}

  defp finish_recording(recording, attrs, action, reason \\ nil)
       when action in [:complete, :fail, :expire] and is_map(attrs) do
    fn ->
      with :ok <- lock_recording(recording.id),
           {:ok, %RemoteAccessRecording{} = current_recording} <- current_recording(recording),
           :ok <- ensure_recordable_status(current_recording),
           {:ok, event_integrity} <- recording_event_integrity(current_recording),
           {:ok, finish_attrs} <- finish_attrs(current_recording, attrs, event_integrity),
           finish_attrs = maybe_put_failure_reason(finish_attrs, action, reason),
           {:ok, %RemoteAccessRecording{} = updated, notifications} <-
             finish_recording_action(current_recording, finish_attrs, action) do
        {updated, notifications}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, {%RemoteAccessRecording{} = updated, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_recording_action(recording, attrs, :complete) do
    RemoteAccessRecording.complete(recording, attrs,
      actor: system_actor(:complete),
      return_notifications?: true
    )
  end

  defp finish_recording_action(recording, attrs, :fail) do
    RemoteAccessRecording.fail(recording, attrs,
      actor: system_actor(:fail),
      return_notifications?: true
    )
  end

  defp finish_recording_action(recording, attrs, :expire) do
    RemoteAccessRecording.expire(recording, attrs,
      actor: system_actor(:expire),
      return_notifications?: true
    )
  end

  defp maybe_put_failure_reason(attrs, :fail, reason) do
    Map.put(attrs, :failure_reason, format_reason(reason))
  end

  defp maybe_put_failure_reason(attrs, _action, _reason), do: attrs

  defp lock_recording(recording_id) do
    case Ecto.UUID.cast(to_string(recording_id)) do
      {:ok, uuid} ->
        case Repo.query(lock_recording_sql(), [Ecto.UUID.dump!(uuid)]) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, %{num_rows: 0}} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :invalid_recording_id}
    end
  end

  defp lock_recording_sql do
    """
    SELECT id
    FROM platform.remote_access_recordings
    WHERE id = $1::uuid
    FOR UPDATE
    """
  end

  defp stale_recording_stats(stale_after_seconds, batch_size)
       when is_integer(stale_after_seconds) and stale_after_seconds > 0 and is_integer(batch_size) and
              batch_size > 0 do
    case Repo.query(stale_recording_stats_sql(), [stale_after_seconds, batch_size]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [id, event_count, input_bytes, output_bytes] ->
           %{
             id: id,
             event_count: nonnegative_int(event_count),
             input_bytes: nonnegative_int(input_bytes),
             output_bytes: nonnegative_int(output_bytes)
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_recording_stats(_stale_after_seconds, _batch_size),
    do: {:error, :invalid_stale_reaper_options}

  defp stale_recording_stats_sql do
    """
    SELECT
      r.id::text,
      count(e.id)::bigint,
      coalesce(sum(CASE WHEN e.stream = 'input' THEN e.byte_count ELSE 0 END), 0)::bigint,
      coalesce(sum(CASE WHEN e.stream = 'output' THEN e.byte_count ELSE 0 END), 0)::bigint
    FROM platform.remote_access_recordings r
    LEFT JOIN platform.remote_access_recording_events e ON e.recording_id = r.id
    WHERE r.status IN ('pending', 'active')
    GROUP BY r.id, r.updated_at
    HAVING greatest(r.updated_at, coalesce(max(e.inserted_at), r.updated_at)) <
      (now() AT TIME ZONE 'utc') - ($1::int * INTERVAL '1 second')
    ORDER BY r.updated_at ASC
    LIMIT $2
    """
  end

  defp expire_stale_recording(%{} = stats, opts) do
    with {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(stats.id, actor: system_actor(:stale_expire_lookup)) do
      expire(
        recording,
        %{
          input_bytes: stats.input_bytes,
          output_bytes: stats.output_bytes,
          event_count: stats.event_count
        },
        Keyword.put_new(opts, :audit_actor, system_actor(:stale_expire))
      )
    end
  end

  @spec delete(RemoteAccessRecording.t() | binary(), keyword()) ::
          {:ok, RemoteAccessRecording.t()} | {:error, term()}
  def delete(recording_or_id, opts \\ [])

  def delete(%RemoteAccessRecording{} = recording, opts) do
    with :ok <- authorize_delete(opts),
         {:ok, %RemoteAccessRecording{} = updated} <-
           RemoteAccessRecording.mark_deleted(recording, actor: system_actor(:delete)) do
      write_audit(:remote_access_recording_deleted, updated, opts)
      {:ok, updated}
    end
  end

  def delete(recording_id, opts) when is_binary(recording_id) do
    with :ok <- authorize_delete(opts),
         {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(recording_id, actor: system_actor(:delete_lookup)),
         {:ok, %RemoteAccessRecording{} = updated} <-
           RemoteAccessRecording.mark_deleted(recording, actor: system_actor(:delete)) do
      write_audit(:remote_access_recording_deleted, updated, opts)
      {:ok, updated}
    end
  end

  defp create_manifest(session, policy, opts) do
    now = RemoteAccessRecording.utc_now()
    session_id = session_id(session)
    storage = storage_config(policy, session_id)

    attrs = %{
      session_id: session_id,
      policy: policy,
      storage_backend: storage.backend,
      storage_bucket: storage.bucket,
      object_key: storage.object_key,
      manifest:
        base_manifest(session, policy, storage, %{
          "created_at" => DateTime.to_iso8601(now),
          "content_persistence" => content_persistence(policy),
          "raw_terminal_payloads_stored" => terminal_payloads_allowed?(policy)
        }),
      retention_expires_at: retention_expires_at(policy, now)
    }

    with {:ok, recording} <-
           RemoteAccessRecording.create_recording(attrs, actor: system_actor(:create)) do
      write_audit(:remote_access_recording_created, recording, opts)
      {:ok, recording}
    end
  end

  defp list_events_for_authorized_recording(
         %RemoteAccessRecording{id: recording_id} = recording,
         opts
       ) do
    with :ok <- authorize_recording_read(recording, opts),
         :ok <- ensure_playback_status(recording) do
      RemoteAccessRecordingEvent.list_for_recording(recording_id,
        actor: system_actor(:event_read)
      )
    end
  end

  defp list_events_for_authorized_recording(recording_id, opts) when is_binary(recording_id) do
    with {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(recording_id, actor: system_actor(:event_lookup)) do
      list_events_for_authorized_recording(recording, opts)
    end
  end

  defp ensure_playback_status(%RemoteAccessRecording{status: :deleted}),
    do: {:error, :recording_deleted}

  defp ensure_playback_status(_recording), do: :ok

  defp authorize_recording_read(recording, opts) do
    case export_actor(opts) do
      %{role: :system} = actor ->
        authorize_recording_read_for_actor(recording, actor)

      %{role: "system"} = actor ->
        authorize_recording_read_for_actor(recording, actor)

      nil ->
        {:error, :forbidden}

      actor ->
        authorize_recording_read_for_actor(recording, actor)
    end
  end

  defp authorize_recording_read_for_actor(_recording, %{role: role})
       when role in [:system, "system"], do: :ok

  defp authorize_recording_read_for_actor(recording, actor) do
    cond do
      RBAC.has_permission?(actor, @view_all_permission) ->
        :ok

      actor_uuid(actor) == nil ->
        {:error, :forbidden}

      true ->
        authorize_session_owner(recording, actor)
    end
  end

  defp authorize_session_owner(recording, actor) do
    with {:ok, %RemoteAccessSession{} = session} <-
           RemoteAccessSession.get_by_id(recording.session_id,
             actor: system_actor(:event_session_lookup)
           ) do
      if session.requested_by == actor_uuid(actor), do: :ok, else: {:error, :forbidden}
    end
  end

  defp actor_uuid(%{id: id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp actor_uuid(_actor), do: nil

  defp recording_event_integrity(%RemoteAccessRecording{id: recording_id}) do
    with {:ok, events} <-
           RemoteAccessRecordingEvent.list_for_recording(recording_id,
             actor: system_actor(:finish_event_read)
           ) do
      verify_event_chain(events)
    end
  end

  defp finish_attrs(recording, attrs, event_integrity) do
    now = RemoteAccessRecording.utc_now()
    input_bytes = nonnegative_int(value(attrs, "input_bytes"))
    output_bytes = nonnegative_int(value(attrs, "output_bytes"))
    event_count = nonnegative_int(value(attrs, "event_count"))

    manifest =
      recording.manifest
      |> normalize_policy()
      |> Map.merge(%{
        "completed_at" => DateTime.to_iso8601(now),
        "input_bytes" => input_bytes,
        "output_bytes" => output_bytes,
        "event_count" => event_count,
        "raw_terminal_payloads_stored" => terminal_payloads_allowed?(snapshot_policy(recording))
      })

    with :ok <- ensure_event_count_matches(event_count, event_integrity),
         {:ok, manifest} <- seal_manifest(manifest, event_integrity, now) do
      {:ok,
       %{
         input_bytes: input_bytes,
         output_bytes: output_bytes,
         event_count: event_count,
         manifest: manifest,
         completed_at: now
       }}
    end
  end

  defp ensure_event_count_matches(event_count, %{count: event_count}), do: :ok

  defp ensure_event_count_matches(_event_count, _event_integrity),
    do: {:error, :recording_event_count_mismatch}

  defp base_manifest(session, policy, storage, extra) do
    %{
      "version" => 1,
      "session_id" => session_id(session),
      "agent_id" => string_value(session, "agent_id"),
      "gateway_id" => string_value(session, "gateway_id"),
      "protocol" => string_value(session, "protocol"),
      "adapter" => string_value(session, "adapter"),
      "target_kind" => string_value(session, "target_kind"),
      "target_host" => string_value(session, "target_host"),
      "target_port" => nonnegative_int(value(session, "target_port")),
      "credential_custody_mode" => string_value(session, "credential_custody_mode"),
      "credential_rule_id" => string_value(session, "credential_rule_id"),
      "rbac_decision" => string_value(session, "rbac_decision"),
      "approval_id" => string_value(session, "approval_id"),
      "idle_timeout_seconds" => nonnegative_int(value(session, "idle_timeout_seconds")),
      "absolute_timeout_seconds" => nonnegative_int(value(session, "absolute_timeout_seconds")),
      "desktop_policy" => desktop_policy_manifest(session),
      "storage_backend" => storage.backend,
      "storage_bucket" => storage.bucket,
      "object_key" => storage.object_key,
      "recording_mode" => Map.get(policy, "mode") || "metadata",
      "content_recording" => terminal_payloads_allowed?(policy),
      "redaction_policy" => redaction_policy_snapshot(policy),
      "policy" => policy
    }
    |> Map.merge(extra)
    |> reject_blank()
    |> CredentialRedactor.redact()
  end

  defp redaction_policy_snapshot(policy) do
    %{
      "credential_redactor" => CredentialRedactor.version(),
      "decision_time" => "record_time",
      "policy_edits_retroactive" => false,
      "terminal_payloads_allowed" => terminal_payloads_allowed?(policy),
      "input_payloads_allowed" => input_payloads_allowed?(policy),
      "output_payloads_allowed" => output_payloads_allowed?(policy)
    }
  end

  defp snapshot_policy(%RemoteAccessRecording{manifest: manifest, policy: policy}) do
    manifest
    |> normalize_policy()
    |> Map.get("policy")
    |> normalize_policy()
    |> case do
      map when map_size(map) > 0 -> map
      _empty -> normalize_policy(policy)
    end
  end

  defp desktop_policy_manifest(session) do
    metadata =
      session
      |> value("metadata")
      |> normalize_policy()

    %{}
    |> maybe_put("tls", first_policy(metadata, ["target_tls", "tls_policy", "tls"]))
    |> maybe_put("nla", first_policy(metadata, ["nla", "nla_policy"]))
    |> maybe_put("screen", first_policy(metadata, ["screen_policy", "screen"]))
    |> maybe_put("redirection", first_policy(metadata, ["redirection_policy", "redirection"]))
    |> maybe_put("approval", first_policy(metadata, ["approval_policy", "approval"]))
    |> reject_blank()
  end

  defp first_policy(metadata, keys) do
    Enum.find_value(keys, fn key ->
      case value(metadata, key) do
        value when is_map(value) -> value
        value when value in [nil, "", %{}] -> nil
        value -> value
      end
    end)
  end

  defp storage_config(policy, session_id) do
    storage = policy |> value("storage") |> normalize_policy()

    backend =
      string_value(storage, "backend") ||
        string_value(policy, "storage_backend") ||
        @default_storage_backend

    bucket =
      string_value(storage, "bucket") ||
        string_value(policy, "storage_bucket") ||
        @default_storage_bucket

    prefix =
      string_value(storage, "prefix") ||
        string_value(policy, "storage_prefix") ||
        @default_storage_prefix

    object_key =
      string_value(storage, "object_key") ||
        string_value(policy, "object_key") ||
        generated_object_key(prefix, session_id)

    %{backend: backend, bucket: bucket, object_key: object_key}
  end

  defp generated_object_key(prefix, session_id) do
    prefix = prefix |> sanitize_path() |> String.trim("/")
    session_id = sanitize_path(session_id)

    [prefix, "sessions", session_id, "recording.jsonl"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("/")
  end

  defp retention_expires_at(policy, now) do
    case positive_int(value(policy, "retention_days")) || @default_retention_days do
      days when is_integer(days) -> DateTime.add(now, days * 86_400, :second)
      _ -> nil
    end
  end

  defp enabled?(policy) do
    truthy?(value(policy, "enabled")) or
      string_value(policy, "mode") in ["metadata", "terminal_io", "enhanced", "record"]
  end

  defp event_attrs(recording, attrs, opts) do
    policy = normalize_policy(recording.policy)
    stream = event_stream(attrs)
    payload = event_payload(attrs)
    payload_hash = payload_hash(payload)
    byte_count = event_byte_count(attrs, payload)
    metadata = event_metadata(attrs, payload)
    payload_decision = payload_decision(policy, stream, payload)
    sequence = positive_int(value(attrs, "sequence")) || next_sequence(recording.id, opts)

    reject_nil(%{
      recording_id: recording.id,
      session_id: recording.session_id,
      sequence: sequence,
      stream: stream,
      event_type: event_type(attrs, stream),
      occurred_at: event_time(attrs),
      byte_count: byte_count,
      payload_sha256: payload_hash,
      prior_event_hash: prior_event_hash(recording.id, sequence, opts),
      payload_text: payload_decision.text,
      payload_redacted: payload_decision.redacted?,
      redaction_reason: payload_decision.reason,
      metadata: metadata,
      retention_expires_at: recording.retention_expires_at
    })
  end

  defp event_stream(attrs) do
    case string_value(attrs, "stream") || string_value(attrs, "frame_type") ||
           string_value(attrs, "event_type") do
      "input" -> :input
      "stdin" -> :input
      "data_in" -> :input
      "output" -> :output
      "stdout" -> :output
      "stderr" -> :output
      "data" -> :output
      "resize" -> :resize
      "enhanced_event" -> :enhanced_event
      _ -> :event
    end
  end

  defp event_type(attrs, stream) do
    string_value(attrs, "event_type") ||
      string_value(attrs, "frame_type") ||
      Atom.to_string(stream)
  end

  defp event_payload(attrs) do
    value(attrs, "payload_text") || value(attrs, "payload") || value(attrs, "data")
  end

  defp event_time(attrs) do
    attrs
    |> value("occurred_at")
    |> fallback(value(attrs, "timestamp"))
    |> fallback(value(attrs, "event_time"))
    |> normalize_event_time()
    |> fallback(RemoteAccessRecording.utc_now())
  end

  defp normalize_event_time(%DateTime{} = value), do: DateTime.truncate(value, :second)

  defp normalize_event_time(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp normalize_event_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :second) do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp normalize_event_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp normalize_event_time(_value), do: nil

  defp event_byte_count(attrs, payload) do
    case value(attrs, "byte_count") do
      nil -> payload_byte_size(payload)
      value -> nonnegative_int(value)
    end
  end

  defp payload_byte_size(payload) when is_binary(payload), do: byte_size(payload)
  defp payload_byte_size(nil), do: 0

  defp payload_byte_size(payload) do
    payload
    |> stringify_nested()
    |> Jason.encode!()
    |> byte_size()
  rescue
    _error -> 0
  end

  defp payload_hash(nil), do: nil

  defp payload_hash(payload) do
    payload
    |> payload_binary()
    |> case do
      nil -> nil
      binary -> :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
    end
  end

  defp payload_binary(payload) when is_binary(payload), do: payload
  defp payload_binary(nil), do: nil

  defp payload_binary(payload) do
    payload
    |> stringify_nested()
    |> Jason.encode!()
  rescue
    _error -> nil
  end

  defp event_metadata(attrs, payload) do
    base =
      attrs
      |> value("metadata")
      |> normalize_policy()

    payload_metadata =
      case decode_json_payload(payload) do
        %{} = decoded -> %{"structured_payload" => CredentialRedactor.redact(decoded)}
        _ -> %{}
      end

    base
    |> Map.merge(payload_metadata)
    |> CredentialRedactor.redact()
  end

  defp decode_json_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_json_payload(%{} = payload), do: payload
  defp decode_json_payload(_payload), do: nil

  defp payload_decision(policy, :input, payload) do
    cond do
      !terminal_payloads_allowed?(policy) ->
        redacted_payload(nil, true, "content_recording_disabled")

      !input_payloads_allowed?(policy) ->
        redacted_payload(nil, true, "input_recording_disabled")

      true ->
        redact_payload(payload)
    end
  end

  defp payload_decision(policy, :output, payload) do
    if terminal_payloads_allowed?(policy) and output_payloads_allowed?(policy) do
      redact_payload(payload)
    else
      redacted_payload(nil, true, "content_recording_disabled")
    end
  end

  defp payload_decision(_policy, stream, _payload) when stream in [:enhanced_event, :event] do
    redacted_payload(nil, true, "structured_event_payload_not_stored")
  end

  defp payload_decision(_policy, _stream, _payload),
    do: redacted_payload(nil, true, "not_terminal_payload")

  defp redact_payload(nil), do: redacted_payload(nil, false, nil)

  defp redact_payload(payload) do
    text = payload_to_text(payload)
    redacted = CredentialRedactor.redact(text)
    changed? = redacted != text

    redacted_payload(
      redacted,
      changed?,
      if(changed?, do: "credential_redaction")
    )
  end

  defp payload_to_text(payload) when is_binary(payload), do: payload

  defp payload_to_text(payload) do
    payload
    |> stringify_nested()
    |> Jason.encode!()
  rescue
    _error -> inspect(payload)
  end

  defp redacted_payload(text, redacted?, reason) do
    %{text: text, redacted?: redacted?, reason: reason}
  end

  defp next_sequence(recording_id, opts) do
    recording_id
    |> RemoteAccessRecordingEvent.list_for_recording(scope_opts(opts))
    |> case do
      {:ok, []} -> 1
      {:ok, events} -> events |> Enum.map(& &1.sequence) |> Enum.max() |> Kernel.+(1)
      _ -> 1
    end
  end

  defp prior_event_hash(_recording_id, sequence, _opts) when sequence <= 1, do: nil

  defp prior_event_hash(recording_id, sequence, opts) do
    recording_id
    |> RemoteAccessRecordingEvent.latest_before_sequence(sequence, scope_opts(opts))
    |> case do
      {:ok, [event | _]} -> event_integrity_hash(event)
      _ -> nil
    end
  end

  defp event_integrity_payload(%RemoteAccessRecordingEvent{} = event) do
    stringify_nested(%{
      "id" => event.id,
      "recording_id" => event.recording_id,
      "session_id" => event.session_id,
      "sequence" => event.sequence,
      "stream" => format_atom(event.stream),
      "event_type" => event.event_type,
      "occurred_at" => format_datetime(event.occurred_at),
      "byte_count" => event.byte_count,
      "payload_sha256" => event.payload_sha256,
      "payload_text" => event.payload_text,
      "payload_redacted" => event.payload_redacted,
      "redaction_reason" => event.redaction_reason,
      "metadata" => event.metadata || %{},
      "retention_expires_at" => format_datetime(event.retention_expires_at),
      "prior_event_hash" => event.prior_event_hash
    })
  end

  defp content_persistence(policy) do
    if terminal_payloads_allowed?(policy), do: "terminal_payloads", else: "metadata"
  end

  defp terminal_payloads_allowed?(policy) do
    truthy?(value(policy, "record_terminal_payloads")) or
      truthy?(value(policy, "raw_terminal_payloads")) or
      truthy?(value(policy, "store_terminal_payloads")) or
      truthy?(value(policy, "content_recording_enabled")) or
      string_value(policy, "content_persistence") in [
        "terminal_payloads",
        "raw_terminal_payloads"
      ]
  end

  defp input_payloads_allowed?(policy) do
    truthy?(value(policy, "record_input")) or
      truthy?(value(policy, "record_inputs")) or
      truthy?(value(policy, "store_input"))
  end

  defp output_payloads_allowed?(policy) do
    value(policy, "record_output") not in [false, "false", "no", "0", 0] and
      value(policy, "record_outputs") not in [false, "false", "no", "0", 0]
  end

  defp export_manifest(recording, events, event_integrity, manifest_integrity, export_id) do
    recording.manifest
    |> normalize_policy()
    |> Map.merge(%{
      "export_id" => export_id,
      "exported_at" => DateTime.to_iso8601(RemoteAccessRecording.utc_now()),
      "export_event_count" => length(events),
      "export_contains_payload_text" => Enum.any?(events, &is_binary(&1.payload_text)),
      "export_payloads_redacted" => Enum.any?(events, & &1.payload_redacted),
      "event_chain_verified" => Map.get(event_integrity, :verified?),
      "event_chain_root" => Map.get(event_integrity, :root),
      "manifest_integrity_verified" => Map.get(manifest_integrity, :verified?),
      "manifest_integrity_status" => Map.get(manifest_integrity, :status)
    })
    |> reject_blank()
  end

  defp verify_event_chain(events) when is_list(events) do
    events = Enum.sort_by(events, &{&1.sequence, &1.inserted_at || &1.occurred_at})

    case verify_event_chain(events, nil, 0) do
      {:ok, nil, count} -> {:ok, %{verified?: true, root: nil, count: count}}
      {:ok, last_hash, count} -> {:ok, %{verified?: true, root: last_hash, count: count}}
      {:error, _reason} = error -> error
    end
  end

  defp verify_event_chain([], previous_hash, count), do: {:ok, previous_hash, count}

  defp verify_event_chain([event | rest], expected_prior_hash, count) do
    if event.prior_event_hash == expected_prior_hash do
      verify_event_chain(rest, event_integrity_hash(event), count + 1)
    else
      {:error, :recording_integrity_check_failed}
    end
  end

  defp seal_manifest(manifest, event_integrity, signed_at) do
    unsigned_manifest =
      manifest
      |> normalize_policy()
      |> Map.delete("integrity")

    integrity =
      reject_nil(%{
        "algorithm" => @integrity_algorithm,
        "event_chain_root" => Map.get(event_integrity, :root),
        "event_count" => Map.get(unsigned_manifest, "event_count"),
        "manifest_sha256" => sha256_hex(canonical_json(unsigned_manifest)),
        "signed_at" => DateTime.to_iso8601(signed_at)
      })

    with {:ok, signature} <- sign_manifest(unsigned_manifest, integrity) do
      {:ok, Map.put(unsigned_manifest, "integrity", Map.put(integrity, "signature", signature))}
    end
  end

  defp verify_manifest_integrity(manifest, event_integrity) do
    manifest = normalize_policy(manifest)
    integrity = manifest |> Map.get("integrity") |> normalize_policy()
    signature = string_value(integrity, "signature")

    cond do
      is_nil(signature) ->
        {:ok, %{verified?: false, status: "unsigned_legacy_manifest"}}

      Map.get(integrity, "algorithm") != @integrity_algorithm ->
        {:error, :recording_manifest_integrity_check_failed}

      Map.get(integrity, "event_chain_root") != Map.get(event_integrity, :root) ->
        {:error, :recording_manifest_integrity_check_failed}

      true ->
        unsigned_manifest = Map.delete(manifest, "integrity")
        unsigned_integrity = Map.delete(integrity, "signature")

        with {:ok, expected_signature} <- sign_manifest(unsigned_manifest, unsigned_integrity) do
          if :crypto.hash_equals(signature, expected_signature) do
            {:ok, %{verified?: true, status: "verified"}}
          else
            {:error, :recording_manifest_integrity_check_failed}
          end
        end
    end
  end

  defp sign_manifest(unsigned_manifest, unsigned_integrity) do
    with {:ok, key} <- integrity_key() do
      signature =
        :hmac
        |> :crypto.mac(
          :sha256,
          key,
          canonical_json(%{
            "integrity" => unsigned_integrity,
            "manifest" => unsigned_manifest
          })
        )
        |> Base.encode16(case: :lower)

      {:ok, signature}
    end
  end

  defp integrity_key do
    secret =
      Application.get_env(:serviceradar_core, :recording_integrity_secret) ||
        Application.get_env(:serviceradar_core, :crypto_secret) ||
        System.get_env("SERVICERADAR_RECORDING_INTEGRITY_SECRET") ||
        System.get_env("SERVICERADAR_EDGE_CRYPTO_SECRET") ||
        System.get_env("EDGE_ONBOARDING_ENCRYPTION_KEY")

    if is_binary(secret) and byte_size(secret) >= 32 do
      {:ok, :crypto.mac(:hmac, :sha256, @integrity_key_context, secret)}
    else
      {:error, :recording_integrity_secret_missing}
    end
  end

  defp sha256_hex(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> stringify_map()
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested_value)
      end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value) when is_atom(value), do: value |> Atom.to_string() |> Jason.encode!()
  defp canonical_json(value), do: Jason.encode!(value)

  defp authorize_export(opts) do
    case export_actor(opts) do
      %{role: :system} ->
        :ok

      %{role: "system"} ->
        :ok

      nil ->
        {:error, :forbidden}

      actor ->
        if RBAC.has_permission?(actor, @export_permission), do: :ok, else: {:error, :forbidden}
    end
  end

  defp authorize_delete(opts) do
    case export_actor(opts) do
      %{role: :system} ->
        :ok

      %{role: "system"} ->
        :ok

      nil ->
        {:error, :forbidden}

      actor ->
        if RBAC.has_permission?(actor, @delete_permission), do: :ok, else: {:error, :forbidden}
    end
  end

  defp export_actor(opts) do
    Keyword.get(opts, :actor) ||
      Keyword.get(opts, :audit_actor) ||
      (Keyword.get(opts, :scope) && Map.get(Keyword.get(opts, :scope), :user))
  end

  defp scope_opts(opts) do
    cond do
      scope = Keyword.get(opts, :scope) -> [scope: scope]
      actor = Keyword.get(opts, :actor) -> [actor: actor]
      actor = Keyword.get(opts, :audit_actor) -> [actor: actor]
      true -> [actor: system_actor(:read)]
    end
  end

  defp normalize_policy(policy) when is_map(policy) do
    policy
    |> stringify_map()
    |> scrub_sensitive()
    |> CredentialRedactor.redact()
  end

  defp normalize_policy(_policy), do: %{}

  defp scrub_sensitive(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if sensitive_key?(key) do
        {key, "REDACTED"}
      else
        {key, scrub_sensitive(nested_value)}
      end
    end)
  end

  defp scrub_sensitive(value) when is_list(value), do: Enum.map(value, &scrub_sensitive/1)
  defp scrub_sensitive(value), do: value

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  defp sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    normalized in [
      "credential",
      "credentials",
      "passphrase",
      "password",
      "private_key",
      "secret",
      "ticket",
      "token"
    ] or String.ends_with?(normalized, "_credential") or
      String.ends_with?(normalized, "_password") or
      String.ends_with?(normalized, "_secret") or String.ends_with?(normalized, "_ticket") or
      String.ends_with?(normalized, "_token")
  end

  defp sensitive_key?(_key), do: false

  defp write_audit(action, recording, opts) do
    actor = Keyword.get(opts, :audit_actor) || Keyword.get(opts, :actor)
    audit_writer = Keyword.get(opts, :audit_writer, AuditWriter)

    audit_writer.write_async(
      action: action,
      resource_type: "remote_access_recording",
      resource_id: recording.id,
      resource_name: recording.session_id,
      actor: actor,
      details:
        %{
          session_id: recording.session_id,
          status: format_atom(recording.status),
          storage_backend: recording.storage_backend,
          storage_bucket: recording.storage_bucket,
          object_key: recording.object_key,
          retention_expires_at: format_datetime(recording.retention_expires_at),
          input_bytes: recording.input_bytes,
          output_bytes: recording.output_bytes,
          event_count: recording.event_count,
          failure_reason: recording.failure_reason,
          export_id: Keyword.get(opts, :export_id)
        }
        |> CredentialRedactor.redact()
        |> reject_blank(),
      severity: audit_severity(action),
      message: "Remote access recording #{action_suffix(action)}"
    )
  end

  defp audit_severity(:remote_access_recording_failed), do: :high
  defp audit_severity(:remote_access_recording_deleted), do: :high
  defp audit_severity(_action), do: :medium

  defp action_suffix(:remote_access_recording_created), do: "created"
  defp action_suffix(:remote_access_recording_active), do: "active"
  defp action_suffix(:remote_access_recording_completed), do: "completed"
  defp action_suffix(:remote_access_recording_expired), do: "expired"
  defp action_suffix(:remote_access_recording_failed), do: "failed"
  defp action_suffix(:remote_access_recording_deleted), do: "deleted"
  defp action_suffix(action), do: Atom.to_string(action)

  defp system_actor(suffix), do: SystemActor.system(:"remote_access_recording_#{suffix}")

  defp session_id(session), do: string_value(session, "id") || string_value(session, "session_id")

  defp string_value(container, key), do: container |> value(key) |> string_or_nil()

  defp value(container, key) when is_map(container) do
    atom_key = safe_existing_atom(key)
    Map.get(container, key) || (atom_key && Map.get(container, atom_key))
  end

  defp value(_container, _key), do: nil

  defp fallback(nil, fallback), do: fallback
  defp fallback("", fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp string_or_nil(nil), do: nil

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_value), do: nil

  defp truthy?(value) when value in [true, "true", "required", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp nonnegative_int(value) when is_integer(value) and value >= 0, do: value

  defp nonnegative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp nonnegative_int(_value), do: 0

  defp format_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value), do: value

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_blank(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp reject_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp blank?(value) when value in [nil, "", 0], do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  defp stringify_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_nested(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_nested(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_nested(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_nested(%_{} = value), do: value
  defp stringify_nested(value) when is_map(value), do: stringify_map(value)
  defp stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp sanitize_path(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._\/-]/, "-")
    |> String.replace(~r/\/+/, "/")
  end
end
