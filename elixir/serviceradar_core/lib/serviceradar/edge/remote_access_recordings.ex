defmodule ServiceRadar.Edge.RemoteAccessRecordings do
  @moduledoc """
  Policy-gated recording manifest lifecycle for remote-access sessions.

  This module creates storage/retention metadata and aggregate counters only.
  Terminal input/output payload persistence is intentionally deferred to a
  separately gated writer.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Events.AuditWriter

  @default_storage_backend "datasvc_object_store"
  @default_storage_bucket "remote-access-recordings"
  @default_storage_prefix "remote-access"
  @default_retention_days 30

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
             %{started_at: RemoteAccessRecording.utc_now()}, actor: system_actor(:active)) do
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
          "content_persistence" => "deferred",
          "raw_terminal_payloads_stored" => false
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
        "raw_terminal_payloads_stored" => false
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
