defmodule ServiceRadarWebNG.CameraTimelineReader do
  @moduledoc """
  Copy resolution, SHA-256 and byte-length verification, reader behaviour seams,
  and local-integrity fallback for camera timeline playback (`D.3`, `D3`–`D6`,
  `spec.md:614-666`).

  ## Reader Behaviour Seams

  `fetch_local/2` (`D.1` NVR local read listener) and `fetch_archive/2` (`D.2`
  isolated archive reader per-request credential mode) can be supplied via:
  - per-request/per-test options (`opts[:readers]`, e.g. from
    `conn.private[:camera_timeline_readers]`), accepting `%{local: fun_or_mod, archive: fun_or_mod}`
    or a module implementing `@behaviour ServiceRadarWebNG.CameraTimelineReader`;
  - application configuration (`Application.get_env(:serviceradar_web_ng, :camera_timeline_readers, [])`);
  - default implementations returning `{:error, :reader_unavailable}` when neither
    reader is installed.
  """

  @behaviour __MODULE__

  alias ServiceRadar.Camera.RecordingTimeline

  @default_local_timeout_ms 2_000
  @default_archive_timeout_ms 10_000

  @type read_result :: %{
          bytes: binary(),
          copy: :local | :archive,
          provisional?: boolean(),
          copy_header: String.t(),
          plan: map()
        }

  @callback fetch_local(plan :: map(), deadline_ms :: integer()) ::
              {:ok, binary()} | {:error, term()}

  @callback fetch_archive(plan :: map(), deadline_ms :: integer()) ::
              {:ok, binary()} | {:error, term()}

  @impl true
  def fetch_local(_plan, _deadline_ms), do: {:error, :reader_unavailable}

  @impl true
  def fetch_archive(_plan, _deadline_ms), do: {:error, :reader_unavailable}

  @doc """
  Executes ordered candidate plans returned by `RecordingTimeline.resolve_read_plans/5`
  according to `source_mode` (`:auto | :local | :archive`), verifying exact byte
  length and lowercase SHA-256 against the frozen descriptor before returning bytes.

  On local SHA-256 or byte-length mismatch:
  - the bad bytes are NEVER returned;
  - `RecordingTimeline.mark_local_integrity_failure/2` (or `opts[:mark_local_integrity_failure]`)
    marks the local copy `:missing` (`local_integrity`);
  - in `:auto` mode, falls back to the `:archive` plan ONLY when a verified archive
    plan is present (and `archive_verified?` holds); otherwise returns
    `{:error, :recording_integrity_failed}`.
  """
  @spec execute_plans([map()], :auto | :local | :archive, keyword()) ::
          {:ok, read_result()} | {:error, atom()}
  def execute_plans(plans, source_mode, opts \\ [])
      when is_list(plans) and source_mode in [:auto, :local, :archive] and is_list(opts) do
    local_plan = Enum.find(plans, &(Map.get(&1, :copy) == :local))
    archive_plan = Enum.find(plans, &(Map.get(&1, :copy) == :archive))

    case source_mode do
      :local ->
        execute_forced_local(local_plan, opts)

      :archive ->
        execute_forced_archive(archive_plan, opts)

      :auto ->
        execute_auto(local_plan, archive_plan, opts)
    end
  end

  defp execute_forced_local(nil, _opts), do: {:error, :recording_unavailable}

  defp execute_forced_local(local_plan, opts) do
    case read_and_verify_local(local_plan, opts) do
      {:ok, result} ->
        {:ok, result}

      {:integrity_failed, _archive_verified?} ->
        {:error, :recording_integrity_failed}

      {:error, :not_found} ->
        {:error, :recording_unavailable}

      {:error, _reason} ->
        {:error, :reader_unavailable}
    end
  end

  defp execute_forced_archive(nil, _opts), do: {:error, :recording_unavailable}

  defp execute_forced_archive(archive_plan, opts) do
    read_and_verify_archive(archive_plan, opts)
  end

  defp execute_auto(nil, nil, _opts), do: {:error, :recording_unavailable}

  defp execute_auto(nil, archive_plan, opts) do
    read_and_verify_archive(archive_plan, opts)
  end

  defp execute_auto(local_plan, nil, opts) do
    case read_and_verify_local(local_plan, opts) do
      {:ok, result} -> {:ok, result}
      {:integrity_failed, _} -> {:error, :recording_integrity_failed}
      {:error, :not_found} -> {:error, :recording_unavailable}
      {:error, _reason} -> {:error, :reader_unavailable}
    end
  end

  defp execute_auto(local_plan, archive_plan, opts) do
    case read_and_verify_local(local_plan, opts) do
      {:ok, result} ->
        {:ok, result}

      {:integrity_failed, true} ->
        read_and_verify_archive(archive_plan, opts)

      {:integrity_failed, false} ->
        {:error, :recording_integrity_failed}

      {:error, _recoverable_local_failure} ->
        read_and_verify_archive(archive_plan, opts)
    end
  end

  defp read_and_verify_local(local_plan, opts) do
    local_timeout_ms = Keyword.get(opts, :local_timeout_ms, @default_local_timeout_ms)
    deadline_ms = compute_deadline_ms(local_timeout_ms, opts)
    reader_fn = resolve_local_reader(opts)

    case invoke_reader(reader_fn, :fetch_local, local_plan, deadline_ms) do
      {:ok, bytes} when is_binary(bytes) ->
        if System.monotonic_time(:millisecond) > deadline_ms do
          {:error, :timeout}
        else
          if valid_digest_and_length?(bytes, local_plan) do
            provisional? = Map.get(local_plan, :provisional?, false) == true

            copy_header =
              Map.get(local_plan, :recording_copy_header) ||
                if(provisional?, do: "local; provisional", else: "local")

            {:ok,
             %{
               bytes: bytes,
               copy: :local,
               provisional?: provisional?,
               copy_header: copy_header,
               plan: local_plan
             }}
          else
            archive_verified? = handle_local_integrity_failure(local_plan, opts)
            {:integrity_failed, archive_verified?}
          end
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :reader_unavailable}
    end
  end

  defp read_and_verify_archive(archive_plan, opts) do
    archive_timeout_ms = Keyword.get(opts, :archive_timeout_ms, @default_archive_timeout_ms)
    deadline_ms = compute_deadline_ms(archive_timeout_ms, opts)
    {reader_fn, custom?} = resolve_archive_reader(opts)

    if not custom? and not is_nil(Map.get(archive_plan, :credential_error)) do
      {:error, :reader_unavailable}
    else
      case invoke_reader(reader_fn, :fetch_archive, archive_plan, deadline_ms) do
        {:ok, bytes} when is_binary(bytes) ->
          cond do
            System.monotonic_time(:millisecond) > deadline_ms ->
              {:error, :reader_unavailable}

            valid_digest_and_length?(bytes, archive_plan) ->
              {:ok,
               %{
                 bytes: bytes,
                 copy: :archive,
                 provisional?: false,
                 copy_header: "archive",
                 plan: archive_plan
               }}

            true ->
              {:error, :recording_integrity_failed}
          end

        {:error, :not_found} ->
          {:error, :recording_unavailable}

        {:error, _reason} ->
          {:error, :reader_unavailable}

        _ ->
          {:error, :reader_unavailable}
      end
    end
  end

  defp valid_digest_and_length?(bytes, plan) when is_binary(bytes) and is_map(plan) do
    expected_len = Map.get(plan, :expected_length)
    expected_sha = Map.get(plan, :expected_sha256)

    is_integer(expected_len) and
      byte_size(bytes) == expected_len and
      is_binary(expected_sha) and
      :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == expected_sha
  end

  defp handle_local_integrity_failure(local_plan, opts) do
    entry_id = to_string(Map.get(local_plan, :entry_id) || "")
    core_opts = Keyword.get(opts, :core_opts, [])

    result =
      case Keyword.get(opts, :mark_local_integrity_failure) do
        fun when is_function(fun, 2) -> fun.(entry_id, core_opts)
        fun when is_function(fun, 1) -> fun.(entry_id)
        _ -> RecordingTimeline.mark_local_integrity_failure(entry_id, core_opts)
      end

    case result do
      {:ok, %{archive_verified?: verified?}} -> verified? == true
      _ -> false
    end
  end

  defp compute_deadline_ms(step_timeout_ms, opts) do
    now_ms = System.monotonic_time(:millisecond)
    step_deadline = now_ms + step_timeout_ms

    case Keyword.get(opts, :request_deadline_ms) do
      req_deadline when is_integer(req_deadline) -> min(step_deadline, req_deadline)
      _ -> step_deadline
    end
  end

  defp resolve_local_reader(opts) do
    readers = Keyword.get(opts, :readers)
    app_cfg = Application.get_env(:serviceradar_web_ng, :camera_timeline_readers, [])

    pick_reader(readers, [:local, :local_reader]) ||
      pick_reader(app_cfg, [:local, :local_reader]) ||
      __MODULE__
  end

  defp resolve_archive_reader(opts) do
    readers = Keyword.get(opts, :readers)
    app_cfg = Application.get_env(:serviceradar_web_ng, :camera_timeline_readers, [])

    case pick_reader(readers, [:archive, :archive_reader]) ||
           pick_reader(app_cfg, [:archive, :archive_reader]) do
      nil -> {__MODULE__, false}
      custom -> {custom, true}
    end
  end

  defp pick_reader(nil, _keys), do: nil
  defp pick_reader(mod, _keys) when is_atom(mod), do: mod

  defp pick_reader(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp pick_reader(list, keys) when is_list(list) do
    Enum.find_value(keys, fn key -> Keyword.get(list, key) end)
  end

  defp pick_reader(_, _keys), do: nil

  defp invoke_reader(fun, _callback, plan, deadline_ms) when is_function(fun, 2) do
    fun.(plan, deadline_ms)
  end

  defp invoke_reader(fun, _callback, plan, _deadline_ms) when is_function(fun, 1) do
    fun.(plan)
  end

  defp invoke_reader(mod, callback, plan, deadline_ms) when is_atom(mod) do
    apply(mod, callback, [plan, deadline_ms])
  end
end
