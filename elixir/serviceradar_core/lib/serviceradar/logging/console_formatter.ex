defmodule ServiceRadar.Logging.ConsoleFormatter do
  @moduledoc """
  `:logger` formatter for the console (pod stdout) handler of every ServiceRadar
  Elixir release.

  Call sites attach the failure reason and the identifiers of a log line as
  metadata (`Logger.warning("X failed", reason: inspect(reason), agent_id: id)`).
  The console prints a metadata key only when it is named in `printed_keys/0`,
  so that list is the single place that decides what an operator can read from
  `kubectl logs`. Each release selects this formatter in its `config/config.exs`:

      config :logger, :default_handler,
        formatter: {ServiceRadar.Logging.ConsoleFormatter, %{}}

  ## Adding a metadata key

  A key used by a `Logger.warning/2` or `Logger.error/2` call must be in exactly
  one of two lists, and `//build:logger_metadata_contract_test` fails otherwise:

    * `printed_keys/0` when every call site puts an identifier, a count, a
      name or an already-redacted failure description under it. Redact a
      credentialed URL, a token or a request body where the value is built; do
      not rely on this module to hide it.
    * `withheld_keys/0`, with the reason, when the value must stay off the
      console.

  ## Bounded values

  A printed value longer than `max_value_bytes/0` bytes is cut at that length and
  marked with the size of the original, for example
  `reason=<first bytes>...[truncated, 20480 bytes]`. Line breaks inside a value are printed
  as `\\n` so one event stays one line. Values that are not strings, numbers or
  atoms are printed with a depth-limited `inspect/2`.

  Only the console rendering is bounded. The log event itself is never
  modified: the message text is formatted by `Logger.Formatter` exactly as
  before, and every other handler, including the OTLP log handler that
  `ServiceRadar.Telemetry.OtelSetup` registers, receives the full metadata.
  """

  @behaviour :logger_formatter

  @default_template "$time $metadata[$level] $message\n"
  @max_value_bytes 512
  @inspect_opts [limit: 50, printable_limit: 1024]

  # Every key below was reviewed at its call sites: the value is an identifier,
  # a name, a count, a duration, or a failure description that carries no
  # credential. The list also names the keys of call sites that build their
  # metadata at run time, which the contract test cannot read. Keep it sorted.
  @printed_keys ~w(
    absolute_timeout_seconds action active_run_count actor_id addon_id addon_version advisory_id
    after_prune_edges age_bound_seconds agent_id agent_scope agent_uid agent_uids alert_id
    applied_days args assessment_id assignment_id attempt attempt_id attempted_at attempts
    awx_job_id awx_template_id batch_count batch_index batch_number batch_run_count batch_size
    batches body_partition bytes caller caller_pid cancelled_jobs candidate_assignment_ids
    cap_dropped cause certificate_partition_id check check_id checker_id chunk chunk_hours
    chunks cluster_id cn cnpg_export_enabled collection_id column command_id command_type
    compress_after_hours config_version configured_days constraint consumer consumer_name
    contract_id controller_id controller_index count count_per_minute credential_secret_id
    cutoff cve_id dataset deleted delivery_count delivery_id demoted_manifest_rows
    desktop_session_id dest device_count device_id device_ids device_uid diagnostics dir
    discarded_count discarded_jobs discovered_stream dlq_sequence drop_point dropped_chunks
    dropped_total durable endpoint_role ensure_reason episode_uid error error_count errors
    event_id event_type exception execution_id expected_agent_id expected_command_type
    expected_gateway_node expired_inflight expired_sequences failed failed_occurrences
    failed_since failure_arity failure_code failure_kind failure_module failures filter_subject
    frame_type gateway_id grant_id handler_id hazards health_condition healthy host id
    identity_component_id identity_component_type identity_partition_id if_index
    integration_source_id interface_uid interval invocation_id ip job_id jti key kind known
    known_sources label lane lifecycle_reason limit_bytes mapper_evidence_edges
    matched_assignment_ids max_age_ms max_buffered max_deliver media_ingest_id media_session_id
    message_size message_type metadata method metric min_canonical_edges missing missing_objects
    msg_id new_state node oban_job_id object_key observed occurrences oldest_age_seconds
    oldest_pending_ms ongoing_failure operation orphan_grace_seconds overdue_seconds owner_pid
    package_id partition partition_id parts pass payload_field_count payload_kind pending_count
    phase pipeline plugin_assignment_id plugin_id plugin_package_id policy_id port producer_id
    producer_type profile_id profile_name progress_percent promoted_starved_jobs protocols
    provider_id provider_key pull_subjects query queue reason reasons received_agent_id
    received_gateway_node recorded recovered recovery_errors registry_epoch relay_session_id
    release_tag released_stream remote_ip repo_url reported_command_type repository_id
    request_id requested_stream rescued_count rescued_jobs resource resource_key response
    result results retention_days retry_in_ms retrying rollout_id root_span_ratio
    root_spans route_id route_ids row_count rows rule_id rule_name run_id running sample
    sampler_address scan_id schedule_id schema scoped_series section_count series_key
    service_name services session_agent_id session_id session_partition_id session_started_at
    severity shard signal signing_key_id silence_id since snapshot_id source source_id sqlstate
    stale stale_conflict_cutoff_seconds stale_executing_minutes stale_job_count
    stale_oban_job_id stale_run_cutoff_seconds stale_threshold_minutes
    starvation_threshold_minutes state stats status step step_number stream subject
    subject_partition success sweep_group_execution_id sweep_group_id sweep_group_name table
    tables target_count target_id target_key threshold threshold_per_minute timeout_ms
    token_type topic total_spans transition_class trigger_mode type unexported_chunks
    update_kind updated_count upto url user_id version view viewer_id window_minutes worker
  )a

  # Keys that call sites use but the console must not print. Each entry says why.
  @withheld_keys [
    domain:
      "reserved by :logger, which replaces a caller-supplied value with its own domain list",
    path:
      "a request path can embed a one-time token, such as a password-reset or email-confirmation link",
    response_body: "a third-party HTTP response body can echo the data that was submitted"
  ]

  @type config :: %{optional(:format) => String.t()}

  @doc "Metadata keys the console prints, in print order."
  @spec printed_keys() :: [atom()]
  def printed_keys, do: @printed_keys

  @doc "Metadata keys that are deliberately kept off the console, with the reason for each."
  @spec withheld_keys() :: keyword(String.t())
  def withheld_keys, do: @withheld_keys

  @doc "Longest metadata value, in bytes, printed before the value is cut and marked."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @impl :logger_formatter
  def check_config(config) when is_map(config) do
    case Map.get(config, :format, @default_template) do
      format when is_binary(format) -> :ok
      other -> {:error, {:invalid_format, other}}
    end
  end

  def check_config(config), do: {:error, {:invalid_formatter_config, config}}

  @impl :logger_formatter
  def format(%{meta: meta} = event, config) do
    {Logger.Formatter, formatter_config} = formatter(config)
    Logger.Formatter.format(%{event | meta: bound_printed_values(meta)}, formatter_config)
  end

  # `Logger.Formatter.new/1` compiles the template, so build it once per
  # distinct handler configuration instead of once per log event.
  defp formatter(config) do
    key = {__MODULE__, config}

    case :persistent_term.get(key, nil) do
      nil ->
        formatter =
          Logger.Formatter.new(
            format: Map.get(config, :format, @default_template),
            metadata: @printed_keys
          )

        :persistent_term.put(key, formatter)
        formatter

      formatter ->
        formatter
    end
  end

  defp bound_printed_values(meta) do
    Enum.reduce(@printed_keys, meta, fn key, acc ->
      case acc do
        %{^key => value} when not is_nil(value) -> %{acc | key => printable(value)}
        _ -> acc
      end
    end)
  end

  defp printable(value) when is_binary(value) do
    if String.valid?(value), do: bound(value), else: bound(inspect(value, @inspect_opts))
  end

  defp printable(value) when is_integer(value), do: Integer.to_string(value)
  defp printable(value) when is_float(value), do: Float.to_string(value)

  defp printable(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> rest -> bound(rest)
      other -> bound(other)
    end
  end

  defp printable(value), do: bound(safe_inspect(value))

  defp safe_inspect(value) do
    inspect(value, @inspect_opts)
  rescue
    _ -> "[uninspectable]"
  end

  defp bound(text) do
    size = byte_size(text)

    text =
      if size > @max_value_bytes do
        [keep_valid_prefix(text), "...[truncated, ", Integer.to_string(size), " bytes]"]
      else
        text
      end

    text
    |> IO.iodata_to_binary()
    |> String.replace(["\r\n", "\n", "\r"], "\\n")
  end

  # A byte cut can land inside a multi-byte character; drop the partial one so
  # the console never receives invalid UTF-8.
  defp keep_valid_prefix(text) do
    prefix = binary_part(text, 0, @max_value_bytes)

    case :unicode.characters_to_binary(prefix) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end
end
