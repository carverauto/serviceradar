defmodule ServiceRadar.Edge.RemoteAccessRecordings do
  @moduledoc """
  Policy-gated recording manifest lifecycle for remote-access sessions.

  This module creates storage/retention metadata and aggregate counters only.
  Terminal input/output payload persistence remains separately gated and is
  disabled unless trusted policy explicitly enables raw content recording.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessRecordingEvent
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.RBAC

  @default_storage_backend "datasvc_object_store"
  @default_storage_bucket "remote-access-recordings"
  @default_storage_prefix "remote-access"
  @default_retention_days 30
  @export_permission "devices.remote_access.recordings.export"

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
    attrs = finish_attrs(recording, attrs)

    with {:ok, updated} <-
           RemoteAccessRecording.complete(recording, attrs, actor: system_actor(:complete)) do
      write_audit(:remote_access_recording_completed, updated, opts)
      {:ok, updated}
    end
  end

  @spec fail(RemoteAccessRecording.t() | nil, term(), map(), keyword()) ::
          {:ok, RemoteAccessRecording.t() | nil} | {:error, term()}
  def fail(recording, reason, attrs, opts \\ [])
  def fail(nil, _reason, _attrs, _opts), do: {:ok, nil}

  def fail(%RemoteAccessRecording{} = recording, reason, attrs, opts) when is_map(attrs) do
    attrs =
      recording
      |> finish_attrs(attrs)
      |> Map.put(:failure_reason, format_reason(reason))

    with {:ok, updated} <-
           RemoteAccessRecording.fail(recording, attrs, actor: system_actor(:fail)) do
      write_audit(:remote_access_recording_failed, updated, opts)
      {:ok, updated}
    end
  end

  @spec record_event(RemoteAccessRecording.t() | nil, map(), keyword()) ::
          {:ok, RemoteAccessRecordingEvent.t() | nil} | {:error, term()}
  def record_event(recording, attrs, opts \\ [])
  def record_event(nil, _attrs, _opts), do: {:ok, nil}

  def record_event(%RemoteAccessRecording{} = recording, attrs, opts) when is_map(attrs) do
    attrs = event_attrs(recording, attrs, opts)
    RemoteAccessRecordingEvent.record(attrs, actor: system_actor(:event))
  end

  @spec list_events(RemoteAccessRecording.t() | binary(), keyword()) ::
          {:ok, [RemoteAccessRecordingEvent.t()]} | {:error, term()}
  def list_events(recording_or_id, opts \\ [])

  def list_events(%RemoteAccessRecording{id: recording_id}, opts) do
    list_events(recording_id, opts)
  end

  def list_events(recording_id, opts) when is_binary(recording_id) do
    RemoteAccessRecordingEvent.list_for_recording(recording_id, scope_opts(opts))
  end

  @spec export(RemoteAccessRecording.t() | binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def export(recording_or_id, opts \\ [])

  def export(%RemoteAccessRecording{} = recording, opts) do
    with :ok <- authorize_export(opts),
         {:ok, events} <- list_events(recording, opts) do
      write_audit(:remote_access_recording_exported, recording, opts)

      {:ok,
       %{
         recording: recording,
         manifest: export_manifest(recording, events),
         events: events
       }}
    end
  end

  def export(recording_id, opts) when is_binary(recording_id) do
    with :ok <- authorize_export(opts),
         {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(recording_id, scope_opts(opts)) do
      export(recording, opts)
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

  defp finish_attrs(recording, attrs) do
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
        "raw_terminal_payloads_stored" => terminal_payloads_allowed?(recording.policy)
      })

    %{
      input_bytes: input_bytes,
      output_bytes: output_bytes,
      event_count: event_count,
      manifest: manifest,
      completed_at: now
    }
  end

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
      "storage_backend" => storage.backend,
      "storage_bucket" => storage.bucket,
      "object_key" => storage.object_key,
      "recording_mode" => Map.get(policy, "mode") || "metadata",
      "content_recording" => terminal_payloads_allowed?(policy),
      "policy" => policy
    }
    |> Map.merge(extra)
    |> reject_blank()
    |> CredentialRedactor.redact()
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

    %{
      recording_id: recording.id,
      session_id: recording.session_id,
      sequence: positive_int(value(attrs, "sequence")) || next_sequence(recording.id, opts),
      stream: stream,
      event_type: event_type(attrs, stream),
      occurred_at: event_time(attrs),
      byte_count: byte_count,
      payload_sha256: payload_hash,
      payload_text: payload_decision.text,
      payload_redacted: payload_decision.redacted?,
      redaction_reason: payload_decision.reason,
      metadata: metadata,
      retention_expires_at: recording.retention_expires_at
    }
    |> reject_nil()
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
      binary -> :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
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
      if(changed?, do: "credential_redaction", else: nil)
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

  defp export_manifest(recording, events) do
    recording.manifest
    |> normalize_policy()
    |> Map.merge(%{
      "exported_at" => DateTime.to_iso8601(RemoteAccessRecording.utc_now()),
      "export_event_count" => length(events),
      "export_contains_payload_text" => Enum.any?(events, &is_binary(&1.payload_text)),
      "export_payloads_redacted" => Enum.any?(events, & &1.payload_redacted)
    })
  end

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
          failure_reason: recording.failure_reason
        }
        |> CredentialRedactor.redact()
        |> reject_blank(),
      severity: audit_severity(action),
      message: "Remote access recording #{action_suffix(action)}"
    )
  end

  defp audit_severity(:remote_access_recording_failed), do: :high
  defp audit_severity(_action), do: :medium

  defp action_suffix(:remote_access_recording_created), do: "created"
  defp action_suffix(:remote_access_recording_active), do: "active"
  defp action_suffix(:remote_access_recording_completed), do: "completed"
  defp action_suffix(:remote_access_recording_failed), do: "failed"
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
