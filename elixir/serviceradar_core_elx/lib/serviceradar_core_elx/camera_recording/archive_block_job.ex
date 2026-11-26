defmodule ServiceRadarCoreElx.CameraRecording.ArchiveBlockJob do
  @moduledoc """
  Oban worker (`nvr_archive` queue) that archives one sealed local NVR block to
  object storage (`A.4.1`, design section `A6`).

  Uniqueness is enforced per `catalog_entry_id` across non-terminal queued states
  (`[:available, :scheduled, :retryable]`) so duplicate enqueues coalesce without
  an orphaned `:executing` job stalling future work.

  Execution flow:
  1. Loads `RecordingCatalogEntry` and verifies eligibility (`archive_state` in
     `[:pending, :failed_retryable]` and `local_state == :present`). Entries that
     are already `:verified`, `:not_required`, or missing locally exit cleanly.
  2. Applies Transition 5 (`:not_required`) if deployment archiving was disabled
     or the camera policy changed to `:local_only`.
  3. Honors A6 "Held jobs" (`StorageEntitlements.archive_uploads_held?`, disabled
     recording, closed recovery gate) by snoozing without consuming an attempt or
     mutating catalog state.
  4. Resolves the NVR member from `storage_id` and delegates upload + readback
     verification to `NVRArchive.archive_block/5`.
  5. On verified receipt, records `NVRArchiveReceipt` and transitions
     `RecordingCatalogEntry` to `:verified` atomically in one transaction, then
     broadcasts a best-effort `:archive_verified` update via
     `ServiceRadar.Camera.RecordingPubSub`. For a re-archive request
     (Transition 8: entry already carries `nvr_archive_receipt_id`), a retained
     receipt matching the previously recorded receipt is refused and returns
     the entry to `:missing`.
  6. On 503 `archive_busy`, snoozes without consuming an attempt. On retryable
     failures (502, other 503s, 400, 404, non-conflict 409s, `:outcome_unknown`,
     binding/request shape errors, credential or NVR target unavailability),
     transitions the entry to `:failed_retryable` and returns `{:snooze, backoff}`
     with jittered exponential backoff (30 s doubling to 30 min) so the job retries
     indefinitely while the block exists without exhausting Oban `max_attempts`,
     stopping cleanly if `local_state != :present` or `archive_state` is no longer
     eligible. On terminal refusals (409 `archive_receipt_conflict`, Core receipt
     conflict, and 422), transitions the entry to `:failed_terminal`, broadcasts
     a best-effort `:archive_failed_terminal` update via
     `ServiceRadar.Camera.RecordingPubSub`, and discards the job.
  """

  # ServiceRadar runs OSS Oban (Oban.Engines.Basic), not Oban Pro.
  # credo:disable-for-next-line Jump.CredoChecks.UseObanProWorker
  use Oban.Worker,
    queue: :nvr_archive,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:catalog_entry_id],
      states: [:available, :scheduled, :retryable]
    ]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingPubSub
  alias ServiceRadar.Repo
  alias ServiceRadar.Storage.StorageEntitlements
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarCoreElx.CameraRecording.NVRArchive
  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  require Ash.Query
  require Logger

  @system_actor SystemActor.system(:camera_nvr_archive_job)
  @eligible_archive_states [:pending, :failed_retryable]
  @busy_snooze_base_seconds 10
  @busy_snooze_jitter_seconds 5
  @held_snooze_seconds 60
  @min_backoff_seconds 30
  @max_backoff_seconds 1_800
  @telemetry_event [:serviceradar, :camera_recording, :archive_block, :outcome]

  @doc """
  Enqueues an `ArchiveBlockJob` for a `RecordingCatalogEntry` when its
  `archive_state` is `:pending`.

  Best-effort: never raises or stalls the caller if Oban is unavailable or
  returns an error.
  """
  @spec enqueue_for_entry(RecordingCatalogEntry.t() | map(), keyword()) ::
          {:ok, Oban.Job.t()} | :skipped | {:error, term()}
  def enqueue_for_entry(entry, opts \\ [])

  def enqueue_for_entry(%{id: entry_id, archive_state: :pending}, opts) when is_binary(entry_id) and is_list(opts) do
    enqueue(entry_id, opts)
  end

  def enqueue_for_entry(_entry, _opts), do: :skipped

  @doc """
  Enqueues an `ArchiveBlockJob` for `catalog_entry_id` via `ObanSupport.safe_insert/2`.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(catalog_entry_id, opts \\ [])

  def enqueue(catalog_entry_id, opts) when is_binary(catalog_entry_id) and is_list(opts) do
    case Ecto.UUID.cast(catalog_entry_id) do
      {:ok, uuid} ->
        job = new(%{"catalog_entry_id" => uuid})

        try do
          case ObanSupport.safe_insert(job, opts) do
            {:ok, _inserted} = ok ->
              ok

            {:error, :oban_unavailable} = error ->
              error

            {:error, reason} = error ->
              Logger.warning("NVR archive job enqueue failed for catalog entry #{uuid}: #{inspect(reason, limit: 8)}")

              error
          end
        catch
          kind, reason ->
            Logger.warning(
              "NVR archive job enqueue exited for catalog entry #{uuid}: #{inspect({kind, reason}, limit: 8)}"
            )

            {:error, {:enqueue_exit, {kind, reason}}}
        end

      :error ->
        {:error, :invalid_catalog_entry_id}
    end
  end

  def enqueue(_catalog_entry_id, _opts), do: {:error, :invalid_catalog_entry_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"catalog_entry_id" => catalog_entry_id}}) do
    run(catalog_entry_id)
  end

  def perform(%Oban.Job{}) do
    {:cancel, :invalid_catalog_entry_id}
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    retry_backoff_seconds(attempt)
  end

  @doc """
  Computes jittered exponential backoff in seconds (30 s doubling to 30 min).
  """
  @spec retry_backoff_seconds(pos_integer(), (-> float())) :: pos_integer()
  def retry_backoff_seconds(attempt, rand_fn \\ &:rand.uniform/0) when is_integer(attempt) and is_function(rand_fn, 0) do
    exp = max(attempt - 1, 0)
    base = min(@min_backoff_seconds * Integer.pow(2, min(exp, 10)), @max_backoff_seconds)
    jitter = trunc(base * 0.2 * rand_fn.())
    min(base + jitter, @max_backoff_seconds)
  end

  @doc """
  Runs the archive workflow for `catalog_entry_id`. Accepts injectable hooks in
  `opts` for hermetic unit testing without a live database or NVR daemon.
  """
  @spec run(String.t(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:discard, term()} | {:cancel, term()}
  def run(catalog_entry_id, opts \\ [])

  def run(catalog_entry_id, opts) when is_binary(catalog_entry_id) and is_list(opts) do
    case Ecto.UUID.cast(catalog_entry_id) do
      {:ok, uuid} ->
        execute(uuid, opts)

      :error ->
        {:cancel, :invalid_catalog_entry_id}
    end
  end

  def run(_catalog_entry_id, _opts), do: {:cancel, :invalid_catalog_entry_id}

  defp execute(entry_id, opts) do
    case load_entry(entry_id, opts) do
      {:ok, nil} ->
        emit_outcome(:skipped, entry_id, nil)
        :ok

      {:ok, entry} ->
        process_entry(entry, opts)

      {:error, reason} ->
        error_class = sanitize_error_class(reason, "catalog_load_failed")
        emit_outcome(:failed_retryable, entry_id, error_class)
        {:snooze, retry_backoff_seconds(1, rand_fn(opts))}
    end
  end

  defp process_entry(entry, opts) do
    cond do
      entry.archive_state not in @eligible_archive_states ->
        emit_outcome(:skipped, entry.id, nil)
        :ok

      entry.local_state != :present ->
        emit_outcome(:skipped, entry.id, nil)
        :ok

      true ->
        proceed_eligible_entry(entry, opts)
    end
  end

  defp proceed_eligible_entry(entry, opts) do
    with {:ok, settings} <- load_settings(opts),
         :owed <- check_owed_copy(entry, settings, opts),
         :proceed <- check_archive_hold(opts),
         {:ok, binding} <- load_binding(entry, settings, opts),
         {:ok, secret_id} <- fetch_writer_secret_id(settings),
         {:ok, member} <- resolve_member(entry.storage_id, opts) do
      archive_and_commit(entry, member, binding, secret_id, opts)
    else
      :not_owed ->
        transition_not_required(entry, opts)

      {:held, reason} ->
        emit_outcome(:snoozed, entry.id, sanitize_error_class(reason, "archive_held"))
        {:snooze, held_snooze_seconds(opts)}

      {:error, reason} ->
        classify_and_handle_error(entry, reason, opts)
    end
  end

  defp check_owed_copy(entry, settings, opts) do
    if settings.archive_enabled == true do
      case load_policy(entry, opts) do
        {:ok, %{storage: :local_only}} -> :not_owed
        {:ok, _policy_or_nil} -> :owed
        {:error, reason} -> {:error, reason}
      end
    else
      :not_owed
    end
  end

  defp check_archive_hold(opts) do
    hold_fn =
      Keyword.get(opts, :archive_uploads_held_fn, fn ->
        StorageEntitlements.archive_uploads_held?()
      end)

    case hold_fn.() do
      {true, reason} -> {:held, reason}
      {false, nil} -> :proceed
    end
  end

  defp fetch_writer_secret_id(%{writer_credential_secret_id: secret_id}) when is_binary(secret_id) and secret_id != "",
    do: {:ok, secret_id}

  defp fetch_writer_secret_id(_settings), do: {:error, :archive_credential_unavailable}

  defp archive_and_commit(entry, member, binding, secret_id, opts) do
    archive_fn = Keyword.get(opts, :archive_fn, &NVRArchive.archive_block/5)
    archive_opts = Keyword.get(opts, :archive_opts, [])

    case archive_fn.(member, entry.block_key, binding, secret_id, archive_opts) do
      {:ok, receipt} when is_map(receipt) ->
        commit_verified_receipt(entry, binding, receipt, opts)

      {:error, reason} ->
        classify_and_handle_error(entry, reason, opts)
    end
  end

  defp commit_verified_receipt(entry, binding, receipt, opts) do
    case encode_receipt(receipt) do
      {:ok, receipt_bytes} ->
        persist_verified(entry, binding, receipt_bytes, opts)

      {:error, error_class} ->
        fail_retryable(entry, error_class, opts)
    end
  end

  defp encode_receipt(receipt) do
    case CanonicalJSON.encode(receipt) do
      {:ok, bytes} when byte_size(bytes) in 1..8_192 -> {:ok, bytes}
      _ -> {:error, "invalid_archive_receipt"}
    end
  end

  defp persist_verified(entry, binding, receipt_bytes, opts) do
    now = now_fn(opts).()
    commit_fn = Keyword.get(opts, :commit_verified_fn, &default_commit_verified/4)

    case commit_fn.(entry, binding, receipt_bytes, now) do
      {:ok, :verified} ->
        emit_outcome(:completed, entry.id, nil)
        RecordingPubSub.broadcast_updated(Map.get(entry, :camera_source_id), :archive_verified)
        :ok

      {:ok, :skipped} ->
        emit_outcome(:skipped, entry.id, nil)
        :ok

      {:ok, :rearchive_refused} ->
        emit_outcome(:rearchive_refused, entry.id, "rearchive_retained_receipt_refused")
        :ok

      {:error, reason} ->
        if receipt_conflict_error?(reason) do
          fail_terminal(entry, "archive_receipt_conflict", opts)
        else
          error_class = sanitize_error_class(reason, "archive_commit_failed")
          fail_retryable(entry, error_class, opts)
        end
    end
  end

  defp default_commit_verified(entry, binding, receipt_bytes, now) do
    receipt_sha256 = :sha256 |> :crypto.hash(receipt_bytes) |> Base.encode16(case: :lower)

    Repo.transaction(fn ->
      with_result =
        with {:ok, current} <- lock_catalog_entry(entry.id) do
          commit_locked_entry(current, binding, receipt_bytes, receipt_sha256, now)
        end

      case with_result do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp commit_locked_entry(nil, _binding, _receipt_bytes, _receipt_sha256, _now), do: {:ok, :skipped}

  defp commit_locked_entry(%{archive_state: state}, _binding, _receipt_bytes, _receipt_sha256, _now)
       when state not in @eligible_archive_states, do: {:ok, :skipped}

  # Design A6 Transition 8: a re-archive request never treats a retained local
  # receipt as success; refuse and return the entry to `:missing`.
  defp commit_locked_entry(%{local_state: local_state}, _binding, _receipt_bytes, _receipt_sha256, _now)
       when local_state != :present, do: {:ok, :skipped}

  defp commit_locked_entry(
         %{nvr_archive_receipt_id: existing_receipt_id} = current,
         binding,
         receipt_bytes,
         receipt_sha256,
         now
       )
       when is_binary(existing_receipt_id) do
    case Ash.get(NVRArchiveReceipt, existing_receipt_id, actor: @system_actor, not_found_error?: false) do
      {:ok, %{receipt_sha256: ^receipt_sha256}} ->
        case update_catalog_archive_state(current, %{
               archive_state: :missing,
               archive_state_at: now,
               archive_attempts: current.archive_attempts + 1,
               archive_last_error_class: "rearchive_retained_receipt_refused"
             }) do
          {:ok, _updated} -> {:ok, :rearchive_refused}
          {:error, _} = error -> error
        end

      {:ok, _other_or_nil} ->
        record_and_verify_entry(current, binding, receipt_bytes, now)

      {:error, _} = error ->
        error
    end
  end

  defp commit_locked_entry(current, binding, receipt_bytes, _receipt_sha256, now) do
    record_and_verify_entry(current, binding, receipt_bytes, now)
  end

  defp record_and_verify_entry(current, binding, receipt_bytes, now) do
    with {:ok, recorded_receipt} <- record_receipt(binding.id, receipt_bytes, current.recording_block_id),
         {:ok, _updated} <-
           update_catalog_archive_state(current, %{
             archive_state: :verified,
             archive_state_at: now,
             archive_binding_id: binding.id,
             nvr_archive_receipt_id: recorded_receipt.id,
             archived_at: recorded_receipt.verified_at,
             archive_attempts: current.archive_attempts + 1,
             archive_last_error_class: nil
           }) do
      {:ok, :verified}
    end
  end

  defp record_receipt(binding_id, receipt_bytes, recording_block_id) do
    NVRArchiveReceipt
    |> Ash.Changeset.for_create(:record, %{
      archive_binding_id: binding_id,
      receipt_bytes: receipt_bytes,
      recording_block_id: recording_block_id
    })
    |> Ash.create(actor: @system_actor)
  end

  defp receipt_conflict_error?(%InvalidArgument{field: :receipt_bytes, message: msg}) when is_binary(msg) do
    String.contains?(msg, "conflicts with retained record")
  end

  defp receipt_conflict_error?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &receipt_conflict_error?/1)
  end

  defp receipt_conflict_error?(_other), do: false

  defp lock_catalog_entry(entry_id) do
    RecordingCatalogEntry
    |> Ash.Query.filter(id == ^entry_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @system_actor)
  end

  defp classify_and_handle_error(entry, reason, opts) do
    case classify_error(reason) do
      {:snooze, :busy} ->
        emit_outcome(:snoozed, entry.id, "archive_busy")
        {:snooze, busy_snooze_seconds(opts)}

      {:snooze, :held, error_class} ->
        emit_outcome(:snoozed, entry.id, error_class)
        {:snooze, held_snooze_seconds(opts)}

      {:terminal, error_class} ->
        fail_terminal(entry, error_class, opts)

      {:retryable, error_class} ->
        fail_retryable(entry, error_class, opts)
    end
  end

  @doc false
  @spec classify_error(term()) ::
          {:snooze, :busy}
          | {:snooze, :held, String.t()}
          | {:terminal, String.t()}
          | {:retryable, String.t()}
  def classify_error({:archive_status, 503, %{"error" => "archive_busy"}}), do: {:snooze, :busy}

  def classify_error(:recording_disabled), do: {:snooze, :held, "recording_disabled"}
  def classify_error(:nvr_recovery_closed), do: {:snooze, :held, "nvr_recovery_closed"}

  def classify_error({:archive_status, 409, %{"error" => "archive_receipt_conflict"}}),
    do: {:terminal, "archive_receipt_conflict"}

  def classify_error({:archive_status, 422, body}), do: {:terminal, body_error_class(body, "archive_unprocessable")}

  def classify_error({:archive_status, 400, body}), do: {:retryable, body_error_class(body, "invalid_archive_request")}

  def classify_error({:archive_status, 404, body}), do: {:retryable, body_error_class(body, "block_not_found")}

  def classify_error({:archive_status, 409, body}), do: {:retryable, body_error_class(body, "archive_conflict")}

  def classify_error({:archive_status, 502, body}), do: {:retryable, body_error_class(body, "archive_provider_error")}

  def classify_error({:archive_status, 503, body}), do: {:retryable, body_error_class(body, "archive_unavailable")}

  def classify_error({:archive_status, status, body}) when is_integer(status) and status >= 500,
    do: {:retryable, body_error_class(body, "archive_server_error")}

  def classify_error({:archive_status, status, body}) when is_integer(status),
    do: {:retryable, body_error_class(body, "archive_http_error")}

  def classify_error(:outcome_unknown), do: {:retryable, "outcome_unknown"}

  def classify_error({:archive_credential_unavailable, reason}) when is_atom(reason),
    do: {:retryable, sanitize_error_class("credential_#{reason}", "archive_credential_unavailable")}

  def classify_error(reason)
      when reason in [
             :nvr_client_not_configured,
             :invalid_nvr_client_config,
             :unknown_nvr_member,
             :unknown_nvr_storage,
             :duplicate_nvr_storage_id
           ], do: {:retryable, sanitize_error_class(reason, "nvr_target_unavailable")}

  def classify_error(reason), do: {:retryable, sanitize_error_class(reason, "archive_retryable_error")}

  defp fail_retryable(entry, error_class, opts) do
    now = now_fn(opts).()
    next_attempt = (entry.archive_attempts || 0) + 1

    _ =
      transition_entry(
        entry,
        %{
          archive_state: :failed_retryable,
          archive_state_at: now,
          archive_attempts: next_attempt,
          archive_last_error_class: error_class
        },
        opts
      )

    emit_outcome(:failed_retryable, entry.id, error_class)
    {:snooze, retry_backoff_seconds(next_attempt, rand_fn(opts))}
  end

  defp fail_terminal(entry, error_class, opts) do
    now = now_fn(opts).()
    next_attempt = (entry.archive_attempts || 0) + 1

    case transition_entry(
           entry,
           %{
             archive_state: :failed_terminal,
             archive_state_at: now,
             archive_attempts: next_attempt,
             archive_last_error_class: error_class
           },
           opts
         ) do
      {:ok, _updated} ->
        Logger.warning(
          "NVR archive block #{entry.block_key} reached failed_terminal (#{error_class}) for catalog entry #{entry.id}"
        )

        emit_outcome(:failed_terminal, entry.id, error_class)
        RecordingPubSub.broadcast_updated(Map.get(entry, :camera_source_id), :archive_failed_terminal)
        {:discard, error_class}

      {:error, reason} ->
        retry_class = sanitize_error_class(reason, "catalog_update_failed")
        emit_outcome(:failed_retryable, entry.id, retry_class)
        {:snooze, retry_backoff_seconds(next_attempt, rand_fn(opts))}
    end
  end

  defp transition_not_required(entry, opts) do
    now = now_fn(opts).()

    case transition_entry(
           entry,
           %{
             archive_state: :not_required,
             archive_state_at: now,
             archive_last_error_class: nil
           },
           opts
         ) do
      {:ok, _updated} ->
        emit_outcome(:skipped, entry.id, nil)
        :ok

      {:error, reason} ->
        retry_class = sanitize_error_class(reason, "catalog_update_failed")
        emit_outcome(:failed_retryable, entry.id, retry_class)
        {:snooze, retry_backoff_seconds((entry.archive_attempts || 0) + 1, rand_fn(opts))}
    end
  end

  defp transition_entry(entry, attrs, opts) do
    transition_fn = Keyword.get(opts, :transition_entry_fn, &update_catalog_archive_state/2)
    transition_fn.(entry, attrs)
  end

  defp update_catalog_archive_state(entry, attrs) do
    entry
    |> Ash.Changeset.for_update(:transition_archive_state, attrs)
    |> Ash.Changeset.filter(expr(archive_state in ^@eligible_archive_states and local_state == :present))
    |> Ash.update(actor: @system_actor)
  end

  defp load_entry(entry_id, opts) do
    loader =
      Keyword.get(opts, :entry_loader, fn id ->
        Ash.get(RecordingCatalogEntry, id, actor: @system_actor, not_found_error?: false)
      end)

    loader.(entry_id)
  end

  defp load_settings(opts) do
    loader =
      Keyword.get(opts, :settings_loader, fn ->
        RecordingArchiveSettings.get_settings(actor: @system_actor)
      end)

    loader.()
  end

  defp load_policy(entry, opts) do
    loader = Keyword.get(opts, :policy_loader, &default_policy_loader/1)
    loader.(entry)
  end

  defp default_policy_loader(%{camera_source_id: cam_id, stream_profile_id: prof_id})
       when is_binary(cam_id) and is_binary(prof_id) do
    CameraRecordingPolicy.get_by_camera_profile(cam_id, prof_id,
      actor: @system_actor,
      not_found_error?: false
    )
  end

  defp default_policy_loader(_entry), do: {:ok, nil}

  defp load_binding(entry, settings, opts) do
    binding_id = entry.archive_binding_id || settings.active_archive_binding_id

    if is_binary(binding_id) do
      loader =
        Keyword.get(opts, :binding_loader, fn id ->
          Ash.get(ArchiveBinding, id, actor: @system_actor, not_found_error?: false)
        end)

      case loader.(binding_id) do
        {:ok, nil} -> {:error, :archive_binding_not_found}
        {:ok, binding} when is_map(binding) -> {:ok, binding}
        {:error, _} = error -> error
      end
    else
      {:error, :archive_binding_missing}
    end
  end

  defp resolve_member(storage_id, opts) do
    resolver =
      Keyword.get(opts, :member_resolver, fn sid ->
        case NVRTargetConfig.resolve_by_storage_id(sid, Keyword.get(opts, :archive_opts, [])) do
          {:ok, %{member: member}} -> {:ok, member}
          {:error, _} = error -> error
        end
      end)

    resolver.(storage_id)
  end

  defp body_error_class(%{"error" => raw}, fallback) when is_binary(raw), do: sanitize_error_class(raw, fallback)

  defp body_error_class(_body, fallback), do: fallback

  defp sanitize_error_class(value, fallback) when is_atom(value),
    do: value |> Atom.to_string() |> sanitize_error_class(fallback)

  defp sanitize_error_class(value, fallback) when is_binary(value) do
    sanitized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_:-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 64)

    if sanitized == "", do: fallback, else: sanitized
  end

  defp sanitize_error_class(_value, fallback), do: fallback

  defp busy_snooze_seconds(opts) do
    case Keyword.fetch(opts, :busy_snooze_seconds) do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 ->
        seconds

      _ ->
        @busy_snooze_base_seconds + trunc(@busy_snooze_jitter_seconds * rand_fn(opts).())
    end
  end

  defp held_snooze_seconds(opts) do
    Keyword.get(opts, :held_snooze_seconds, @held_snooze_seconds)
  end

  defp rand_fn(opts), do: Keyword.get(opts, :rand_fn, &:rand.uniform/0)

  defp now_fn(opts), do: Keyword.get(opts, :now_fn, &DateTime.utc_now/0)

  defp emit_outcome(outcome, catalog_entry_id, error_class) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{
        outcome: outcome,
        catalog_entry_id: catalog_entry_id,
        error_class: error_class
      }
    )
  end
end
