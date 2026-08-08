defmodule ServiceRadar.Automation.Ansible.AwxLaunchContract do
  @moduledoc """
  Canonical, secret-free AWX launch contract shared with the edge AWX plugin.

  The v1 shape is deliberately the plugin's exact `preflight` projection. It
  does not translate controller IDs, numeric AWX IDs, or numeric template
  settings into Elixir integers: the plugin emits those values as canonical
  decimal strings so JSON decoding cannot introduce floats or cross-runtime
  formatting drift. A reviewed binding stores that same projection with an
  empty `selected_hosts` list; live selected-host authority is dynamic and is
  validated separately by the secure launch gate.

  `from_binding/1` is the fail-closed reviewed-contract boundary. A historical
  digest-only binding returns `{:error, :reviewed_launch_snapshot_required}`.
  `from_plugin_result/1` validates the complete outer
  `serviceradar.awx_launch_preflight_result.v1` response and its advertised
  digest without retaining a raw AWX response.
  """

  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Credentials.CredentialRedactor

  @schema "serviceradar.awx_launch_contract.v1"
  @request_schema "serviceradar.awx_launch_preflight_request.v1"
  @target_snapshot_schema "serviceradar.awx_launch_target_snapshot.v1"
  @result_schema "serviceradar.awx_launch_preflight_result.v1"
  @result_verb "awx.fetch_launch_preflight"
  @sha256_hex ~r/\A[0-9a-f]{64}\z/
  @sha256_fingerprint ~r/\Asha256:[0-9a-f]{64}\z/
  @canonical_positive_id ~r/\A[1-9][0-9]*\z/
  @canonical_nonnegative_id ~r/\A(?:0|[1-9][0-9]*)\z/
  @lower_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @scm_revision ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @slug ~r/\A[a-z][a-z0-9_.-]{0,127}\z/
  @number_string ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
  @forbidden_text_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  # These values intentionally mirror the AWX launch-preflight plugin. The
  # contract consumes the plugin's canonical decimal strings, so accepting a
  # larger Elixir integer would create an attestation shape the plugin can
  # never emit.
  @max_awx_id 2_147_483_647
  @max_template_timeout 7 * 24 * 60 * 60
  @max_template_forks 10_000
  @max_template_job_slice_count 1_000
  @max_projected_result_bytes 3 * 1024 * 1024

  @top_level_keys MapSet.new([
                    "schema",
                    "controller_id",
                    "template",
                    "survey",
                    "survey_digest",
                    "project",
                    "inventory",
                    "credentials",
                    "execution_environment",
                    "selected_hosts"
                  ])

  @result_keys MapSet.new([
                 "schema",
                 "verb",
                 "ok",
                 "request_digest",
                 "preflight",
                 "preflight_digest"
               ])

  @request_keys MapSet.new([
                  "schema",
                  "controller_id",
                  "template_id",
                  "project_id",
                  "inventory_id",
                  "credential_ids",
                  "execution_environment_id",
                  "selected_hosts"
                ])

  @template_keys MapSet.new([
                   "id",
                   "name",
                   "modified",
                   "project_id",
                   "inventory_id",
                   "playbook",
                   "job_type",
                   "scm_branch",
                   "timeout",
                   "forks",
                   "job_slice_count",
                   "allow_simultaneous",
                   "diff_mode",
                   "job_tags",
                   "skip_tags",
                   "survey_enabled",
                   "credential_ids",
                   "execution_environment_id",
                   "prompt_on_launch"
                 ])

  @prompt_keys MapSet.new([
                 "ask_credential_on_launch",
                 "ask_diff_mode_on_launch",
                 "ask_execution_environment_on_launch",
                 "ask_forks_on_launch",
                 "ask_instance_groups_on_launch",
                 "ask_inventory_on_launch",
                 "ask_job_slice_count_on_launch",
                 "ask_job_type_on_launch",
                 "ask_labels_on_launch",
                 "ask_limit_on_launch",
                 "ask_scm_branch_on_launch",
                 "ask_skip_tags_on_launch",
                 "ask_tags_on_launch",
                 "ask_timeout_on_launch",
                 "ask_variables_on_launch",
                 "ask_verbosity_on_launch"
               ])

  @unsupported_prompt_keys MapSet.new([
                             "ask_diff_mode_on_launch",
                             "ask_execution_environment_on_launch",
                             "ask_forks_on_launch",
                             "ask_instance_groups_on_launch",
                             "ask_job_slice_count_on_launch",
                             "ask_labels_on_launch",
                             "ask_scm_branch_on_launch",
                             "ask_skip_tags_on_launch",
                             "ask_tags_on_launch",
                             "ask_timeout_on_launch",
                             "ask_variables_on_launch",
                             "ask_verbosity_on_launch"
                           ])

  @project_keys MapSet.new([
                  "id",
                  "name",
                  "modified",
                  "scm_type",
                  "scm_url",
                  "scm_branch",
                  "scm_revision",
                  "scm_clean",
                  "status"
                ])
  @inventory_keys MapSet.new(["id", "name", "modified", "kind"])
  # `modified` is part of the plugin's projection. Credential ID/type alone
  # cannot detect a secret or injector change made in place on AWX.
  @credential_keys MapSet.new(["id", "name", "modified", "type"])
  @credential_type_keys MapSet.new(["id", "name", "kind"])
  @environment_keys MapSet.new(["id", "name", "image_reference", "image_digest"])
  @survey_keys MapSet.new(["spec"])
  @survey_required_field_keys MapSet.new(["variable", "question_name", "type", "required"])
  @survey_optional_field_keys MapSet.new(["choices", "min", "max", "question_description"])
  @host_keys MapSet.new([
               "membership_id",
               "controller_id",
               "inventory_id",
               "awx_host_id",
               "canonical_device_uid",
               "host_name",
               "ansible_host",
               "enabled",
               "membership_generation",
               "source_fingerprint",
               "identity_variables_digest"
             ])

  @request_host_keys MapSet.new([
                       "membership_id",
                       "controller_id",
                       "inventory_id",
                       "awx_host_id",
                       "canonical_device_uid",
                       "host_name",
                       "ansible_host",
                       "enabled",
                       "membership_generation",
                       "source_fingerprint"
                     ])
  @survey_types MapSet.new([
                  "text",
                  "textarea",
                  "integer",
                  "float",
                  "multiplechoice",
                  "multiselect"
                ])

  @max_credentials 128
  @max_hosts 128
  @max_survey_fields 100

  @doc "The reviewed/preflight projection schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The versioned selector schema accepted by the AWX preflight plugin."
  @spec request_schema() :: String.t()
  def request_schema, do: @request_schema

  @doc "The outer AWX plugin result schema identifier."
  @spec result_schema() :: String.t()
  def result_schema, do: @result_schema

  @doc "The only AWX plugin verb accepted by `from_plugin_result/1`."
  @spec result_verb() :: String.t()
  def result_verb, do: @result_verb

  @doc """
  Validates the exact non-secret request passed to `awx.fetch_launch_preflight`.

  This is the canonical source for the selector request used by the live gate.
  It rejects a hostless request, an unsorted credential or host list, unknown
  keys, atoms, numbers, and every attempt to add a controller grant or other
  secret-bearing value.
  """
  @spec validate_request(term()) :: {:ok, map()} | {:error, atom() | term()}
  def validate_request(request) when is_map(request) do
    with :ok <- validate_string_only_json(request),
         :ok <- validate_secret_free(request),
         :ok <- exact_map(request, @request_keys),
         :ok <-
           equals(request["schema"], @request_schema, :unsupported_awx_preflight_request_schema),
         :ok <- valid_lower_uuid(request["controller_id"]),
         :ok <- valid_positive_id(request["template_id"]),
         :ok <- valid_positive_id(request["project_id"]),
         :ok <- valid_positive_id(request["inventory_id"]),
         :ok <- sorted_unique_ids(request["credential_ids"]),
         :ok <- valid_positive_id(request["execution_environment_id"]),
         :ok <-
           validate_request_hosts(
             request["selected_hosts"],
             request["controller_id"],
             request["inventory_id"]
           ) do
      {:ok, request}
    end
  end

  def validate_request(_request), do: {:error, :invalid_awx_preflight_request}

  @doc "Returns the canonical SHA-256 digest the plugin advertises as `request_digest`."
  @spec request_digest(term()) :: {:ok, String.t()} | {:error, atom() | term()}
  def request_digest(request) do
    with {:ok, canonical} <- validate_request(request) do
      CanonicalJSON.digest(canonical)
    end
  end

  @doc "Returns the fixed-schema dynamic target snapshot from a validated preflight request."
  @spec target_snapshot(term()) :: {:ok, map()} | {:error, atom() | term()}
  def target_snapshot(request) do
    with {:ok, request} <- validate_request(request) do
      {:ok,
       %{
         "schema" => @target_snapshot_schema,
         "controller_id" => request["controller_id"],
         "inventory_id" => request["inventory_id"],
         "selected_hosts" => request["selected_hosts"]
       }}
    end
  end

  @doc "Returns the canonical digest recorded as `target_snapshot_digest` for a validated request."
  @spec target_snapshot_digest(term()) :: {:ok, String.t()} | {:error, atom() | term()}
  def target_snapshot_digest(request) do
    with {:ok, snapshot} <- target_snapshot(request) do
      CanonicalJSON.digest(snapshot)
    end
  end

  @doc """
  Builds and validates the plugin request from a reviewed binding and exact,
  already-authorized target tuples.

  `selected_hosts` must use the request shape described by `validate_request/1`.
  The helper intentionally does not derive target names or addresses from a
  live controller response.
  """
  @spec request_from(map(), [map()]) :: {:ok, map()} | {:error, atom() | term()}
  def request_from(binding, selected_hosts) when is_list(selected_hosts) do
    with {:ok, reviewed} <- from_binding(binding) do
      template = reviewed["template"]

      validate_request(%{
        "schema" => @request_schema,
        "controller_id" => reviewed["controller_id"],
        "template_id" => template["id"],
        "project_id" => reviewed["project"]["id"],
        "inventory_id" => reviewed["inventory"]["id"],
        "credential_ids" => template["credential_ids"],
        "execution_environment_id" => template["execution_environment_id"],
        "selected_hosts" => selected_hosts
      })
    end
  end

  def request_from(_binding, _selected_hosts), do: {:error, :invalid_awx_preflight_request}

  @doc """
  Validates the exact v1 `preflight` projection emitted by the AWX plugin.

  The projection may contain a non-empty `selected_hosts` list when it came
  from a live read. A reviewed binding uses the same schema with an empty list;
  use `from_binding/1` when that additional invariant is required.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, atom()}
  def validate(snapshot) do
    with :ok <- validate_string_only_json(snapshot),
         :ok <- validate_secret_free(snapshot),
         :ok <- exact_map(snapshot, @top_level_keys),
         :ok <- equals(snapshot["schema"], @schema, :unsupported_awx_launch_contract_schema),
         :ok <- valid_lower_uuid(snapshot["controller_id"]),
         :ok <- validate_template(snapshot["template"]),
         :ok <- validate_survey(snapshot["survey"], snapshot["survey_digest"]),
         :ok <- validate_project(snapshot["project"]),
         :ok <- validate_inventory(snapshot["inventory"]),
         :ok <- validate_credentials(snapshot["credentials"]),
         :ok <- validate_environment(snapshot["execution_environment"]),
         :ok <- validate_hosts(snapshot["selected_hosts"]),
         :ok <- validate_internal_references(snapshot) do
      {:ok, snapshot}
    end
  end

  @doc """
  Returns the normalized map used for digesting and equality.

  v1 intentionally performs no coercion. In particular, accepted identifiers
  and numeric settings are already canonical decimal strings, so a caller can
  compare a decoded plugin projection without inventing a controller name,
  version field, integer conversion, or placeholder value.
  """
  @spec normalize(term()) :: {:ok, map()} | {:error, atom()}
  def normalize(snapshot), do: validate(snapshot)

  @doc "Returns the SHA-256 digest of a validated complete preflight projection."
  @spec digest(term()) :: {:ok, String.t()} | {:error, atom() | term()}
  def digest(snapshot) do
    with {:ok, canonical} <- normalize(snapshot) do
      CanonicalJSON.digest(canonical)
    end
  end

  @doc "Validates a full preflight projection and its exact canonical digest."
  @spec verify(term(), term()) :: {:ok, map()} | {:error, atom() | term()}
  def verify(snapshot, expected_digest) do
    with :ok <- valid_digest(expected_digest),
         {:ok, canonical} <- normalize(snapshot),
         {:ok, actual_digest} <- CanonicalJSON.digest(canonical),
         :ok <- equals(actual_digest, expected_digest, :awx_preflight_digest_mismatch) do
      {:ok, canonical}
    end
  end

  @doc """
  Validates the complete AWX plugin result envelope and its advertised digest.

  Returns only the typed, redacted fields needed by the gate:
  `%{preflight: map, request_digest: sha256, preflight_digest: sha256}`.
  The caller must compare selected hosts to its own immutable target snapshot;
  `static_equivalent?/2` deliberately ignores that dynamic list.
  """
  @spec from_plugin_result(term()) ::
          {:ok, %{preflight: map(), request_digest: String.t(), preflight_digest: String.t()}}
          | {:error, atom() | term()}
  def from_plugin_result(result) when is_map(result) do
    with :ok <- validate_string_only_json(result),
         :ok <- exact_map(result, @result_keys),
         :ok <- equals(result["schema"], @result_schema, :unsupported_awx_preflight_result_schema),
         :ok <- equals(result["verb"], @result_verb, :unsupported_awx_preflight_result_verb),
         :ok <- equals(result["ok"], true, :awx_preflight_result_not_ok),
         :ok <- valid_digest(result["request_digest"]),
         {:ok, preflight} <- verify(result["preflight"], result["preflight_digest"]),
         :ok <- require_live_hosts(preflight) do
      {:ok,
       %{
         preflight: preflight,
         request_digest: result["request_digest"],
         preflight_digest: result["preflight_digest"]
       }}
    end
  end

  def from_plugin_result(_result), do: {:error, :invalid_awx_preflight_result}

  @doc "Returns the canonical digest of the exact validated plugin result envelope."
  @spec result_digest(term()) :: {:ok, String.t()} | {:error, atom() | term()}
  def result_digest(result) do
    with {:ok, _projection} <- from_plugin_result(result) do
      CanonicalJSON.digest(result)
    end
  end

  @doc """
  Validates a plugin result and proves that it attests to `expected_request`.

  This compares the plugin-advertised request digest to the canonical digest
  computed locally. It deliberately leaves target-drift classification to
  `verify_targets/2`, so callers can surface a safe target-specific review
  reason instead of treating a valid but drifted controller read as malformed.
  """
  @spec verify_plugin_result(term(), term()) ::
          {:ok, %{preflight: map(), request_digest: String.t(), preflight_digest: String.t()}}
          | {:error, atom() | term()}
  def verify_plugin_result(result, expected_request) do
    with {:ok, projection} <- from_plugin_result(result),
         {:ok, expected_digest} <- request_digest(expected_request),
         :ok <-
           equals(
             projection.request_digest,
             expected_digest,
             :awx_preflight_request_digest_mismatch
           ) do
      {:ok, projection}
    end
  end

  @doc """
  Verifies that the dynamic hosts in a live preflight exactly match an
  already-authorized request target list.

  In addition to the ten request fields, this checks the plugin's derived
  `identity_variables_digest` against the canonical digest of each expected
  `ansible_host`. A controller cannot substitute an address, host, membership,
  inventory, or identity digest while retaining a valid static contract.
  """
  @spec verify_targets(term(), term()) :: :ok | {:error, atom() | term()}
  def verify_targets(expected_request, live_preflight) do
    with {:ok, request} <- validate_request(expected_request),
         {:ok, preflight} <- validate(live_preflight),
         :ok <-
           equals(
             request["controller_id"],
             preflight["controller_id"],
             :awx_preflight_target_mismatch
           ),
         :ok <-
           equals(
             request["inventory_id"],
             preflight["inventory"]["id"],
             :awx_preflight_target_mismatch
           ),
         :ok <- compare_request_targets(request["selected_hosts"], preflight["selected_hosts"]) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_target_mismatch}
    end
  end

  @doc "Returns whether `verify_targets/2` accepts the exact dynamic target set."
  @spec targets_equivalent?(term(), term()) :: boolean()
  def targets_equivalent?(expected_request, live_preflight),
    do: verify_targets(expected_request, live_preflight) == :ok

  @doc """
  Projects a complete preflight to the static binding-review surface.

  `selected_hosts` is the only dynamic field; it is cleared rather than
  synthesized. The resulting map is the exact form persisted in
  `reviewed_launch_snapshot`.
  """
  @spec static_projection(term()) :: {:ok, map()} | {:error, atom()}
  def static_projection(snapshot) do
    with {:ok, canonical} <- normalize(snapshot) do
      {:ok, Map.put(canonical, "selected_hosts", [])}
    end
  end

  @doc "Compares two preflights after removing only dynamic selected-host evidence."
  @spec static_equivalent?(term(), term()) :: boolean()
  def static_equivalent?(left, right) do
    with {:ok, left} <- static_projection(left),
         {:ok, right} <- static_projection(right),
         {:ok, left_json} <- CanonicalJSON.encode(left),
         {:ok, right_json} <- CanonicalJSON.encode(right) do
      left_json == right_json
    else
      _ -> false
    end
  end

  @doc """
  Classifies a reviewed-versus-live static contract mismatch without returning
  values from either AWX projection.

  The selected-host set is intentionally excluded because it is dynamic and is
  checked separately by `verify_targets/2`. A malformed projection remains a
  generic static drift rather than exposing controller data through an error.
  """
  @spec static_drift_reason(term(), term()) ::
          :none
          | :awx_preflight_controller_drift
          | :awx_preflight_template_project_drift
          | :awx_preflight_inventory_drift
          | :awx_preflight_credential_set_drift
          | :awx_preflight_execution_environment_drift
          | :awx_preflight_survey_contract_drift
          | :awx_preflight_prompt_policy_drift
          | :awx_preflight_static_drift
  def static_drift_reason(left, right) do
    with {:ok, left} <- static_projection(left),
         {:ok, right} <- static_projection(right) do
      classify_static_drift(left, right)
    else
      _ -> :awx_preflight_static_drift
    end
  end

  @doc "Returns true only when every preflight field, including selected hosts, is equal."
  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(left, right) do
    with {:ok, left} <- normalize(left),
         {:ok, right} <- normalize(right),
         {:ok, left_json} <- CanonicalJSON.encode(left),
         {:ok, right_json} <- CanonicalJSON.encode(right) do
      left_json == right_json
    else
      _ -> false
    end
  end

  defp classify_static_drift(left, right) do
    left_template = left["template"]
    right_template = right["template"]

    cond do
      left == right ->
        :none

      left["controller_id"] != right["controller_id"] ->
        :awx_preflight_controller_drift

      left["survey"] != right["survey"] or left["survey_digest"] != right["survey_digest"] ->
        :awx_preflight_survey_contract_drift

      left["credentials"] != right["credentials"] or
          left_template["credential_ids"] != right_template["credential_ids"] ->
        :awx_preflight_credential_set_drift

      left["execution_environment"] != right["execution_environment"] or
          left_template["execution_environment_id"] != right_template["execution_environment_id"] ->
        :awx_preflight_execution_environment_drift

      left_template["prompt_on_launch"] != right_template["prompt_on_launch"] ->
        :awx_preflight_prompt_policy_drift

      left["inventory"] != right["inventory"] or
          left_template["inventory_id"] != right_template["inventory_id"] ->
        :awx_preflight_inventory_drift

      left["project"] != right["project"] or
        left_template["project_id"] != right_template["project_id"] or
          left_template != right_template ->
        :awx_preflight_template_project_drift

      true ->
        :awx_preflight_static_drift
    end
  end

  @doc """
  Extracts a launchable static reviewed contract from a binding.

  The helper rechecks canonical content, digest, legacy metadata digest, all
  binding selectors, prompt policy, and the absence of dynamic hosts. This is
  intentionally independent of how the row was written to the database.
  """
  @spec from_binding(map()) :: {:ok, map()} | {:error, atom() | term()}
  def from_binding(binding) when is_map(binding) do
    snapshot = binding_value(binding, :reviewed_launch_snapshot)
    snapshot_digest = binding_value(binding, :reviewed_launch_snapshot_digest)

    with :ok <- reviewed_snapshot_presence(snapshot, snapshot_digest),
         :ok <- reviewed_metadata_digest_matches(binding, snapshot_digest),
         {:ok, canonical} <- verify(snapshot, snapshot_digest),
         :ok <- require_static_hosts(canonical),
         :ok <- validate_binding_projection(binding, canonical) do
      {:ok, canonical}
    end
  end

  def from_binding(_binding), do: {:error, :reviewed_launch_snapshot_required}

  @doc "Returns whether a binding has a complete reviewed static launch contract."
  @spec launchable?(map()) :: boolean()
  def launchable?(binding), do: match?({:ok, _snapshot}, from_binding(binding))

  defp validate_template(value) do
    with :ok <- exact_map(value, @template_keys),
         :ok <- valid_positive_id(value["id"]),
         :ok <- bounded_text(value["name"], 255, false),
         :ok <- valid_timestamp(value["modified"]),
         :ok <- valid_positive_id(value["project_id"]),
         :ok <- valid_positive_id(value["inventory_id"]),
         :ok <- valid_playbook(value["playbook"]),
         :ok <- one_of(value["job_type"], MapSet.new(["run", "check"]), :invalid_awx_job_type),
         :ok <- bounded_text(value["scm_branch"], 512, true),
         :ok <- valid_nonnegative_setting(value["timeout"], @max_template_timeout),
         :ok <- valid_nonnegative_setting(value["forks"], @max_template_forks),
         :ok <-
           valid_nonnegative_setting(value["job_slice_count"], @max_template_job_slice_count),
         :ok <- boolean(value["allow_simultaneous"], :invalid_awx_allow_simultaneous),
         :ok <- boolean(value["diff_mode"], :invalid_awx_diff_mode),
         :ok <- bounded_text(value["job_tags"], 8_192, true),
         :ok <- bounded_text(value["skip_tags"], 8_192, true),
         :ok <- equals(value["survey_enabled"], true, :awx_survey_must_be_enabled),
         :ok <- sorted_unique_ids(value["credential_ids"]),
         :ok <- valid_positive_id(value["execution_environment_id"]) do
      validate_prompts(value["prompt_on_launch"])
    end
  end

  defp validate_prompts(value) do
    with :ok <- exact_map(value, @prompt_keys),
         :ok <- all_boolean_values(value, @prompt_keys, :invalid_awx_prompt_flag),
         :ok <- equals(value["ask_variables_on_launch"], false, :awx_variables_prompt_forbidden) do
      unsupported_prompts_disabled(value)
    end
  end

  defp unsupported_prompts_disabled(prompts) do
    if Enum.all?(@unsupported_prompt_keys, &(prompts[&1] == false)),
      do: :ok,
      else: {:error, :unsupported_awx_prompt_enabled}
  end

  defp validate_survey(value, digest) do
    with :ok <- exact_map(value, @survey_keys),
         :ok <- valid_digest(digest),
         :ok <- validate_survey_fields(value["spec"]),
         {:ok, actual_digest} <- CanonicalJSON.digest(value) do
      equals(actual_digest, digest, :awx_survey_digest_mismatch)
    end
  end

  defp validate_survey_fields(fields)
       when is_list(fields) and length(fields) <= @max_survey_fields do
    with :ok <- unique_survey_names(fields),
         {:ok, markers} <-
           Enum.reduce_while(fields, {:ok, MapSet.new()}, fn field, {:ok, markers} ->
             case validate_survey_field(field) do
               {:ok, nil} -> {:cont, {:ok, markers}}
               {:ok, marker} -> {:cont, {:ok, MapSet.put(markers, marker)}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      required_dispatch_markers(markers)
    end
  end

  defp validate_survey_fields(_fields), do: {:error, :invalid_awx_survey_spec}

  defp unique_survey_names(fields) do
    fields
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      %{"variable" => name}, {:ok, names} when is_binary(name) ->
        normalized = String.downcase(name)

        if MapSet.member?(names, normalized),
          do: {:halt, {:error, :duplicate_awx_survey_variable}},
          else: {:cont, {:ok, MapSet.put(names, normalized)}}

      _field, _acc ->
        {:halt, {:error, :invalid_awx_survey_spec}}
    end)
    |> case do
      {:ok, _names} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_survey_field(field) do
    with :ok <-
           map_with_required_and_optional_keys(
             field,
             @survey_required_field_keys,
             @survey_optional_field_keys
           ),
         :ok <- bounded_text(field["variable"], 128, false),
         :ok <- bounded_text(field["question_name"], 1_024, true),
         :ok <- one_of(field["type"], @survey_types, :invalid_awx_survey_type),
         :ok <- boolean(field["required"], :invalid_awx_survey_required_flag),
         :ok <- validate_survey_choices(field["type"], Map.get(field, "choices", [])),
         :ok <- validate_optional_number(field, "min"),
         :ok <- validate_optional_number(field, "max"),
         :ok <- validate_survey_bounds(field),
         :ok <- validate_optional_description(field) do
      # The plugin intentionally serializes all survey numbers as strings so
      # the cross-runtime canonical digest never depends on JSON number
      # decoding. The older marker helper predates that contract and expects
      # integer marker bounds, so adapt only its private validation input.
      case DispatchMarkerContract.validate_survey_field(dispatch_marker_validation_field(field)) do
        :ok -> {:ok, field["variable"]}
        :not_marker -> validate_reviewed_survey_field(field)
        {:error, _reason} -> {:error, :invalid_awx_dispatch_marker_survey}
      end
    end
  end

  defp validate_reviewed_survey_field(field) do
    if VariableSchema.reviewed_input_name?(field["variable"]),
      do: {:ok, nil},
      else: {:error, :unsafe_awx_survey_variable}
  end

  defp validate_survey_choices(type, values)
       when type in ["multiplechoice", "multiselect"] and is_list(values) do
    if Enum.all?(values, &match?(:ok, bounded_text(&1, 1_024, false))) and
         length(values) == length(Enum.uniq(values)),
       do: :ok,
       else: {:error, :invalid_awx_survey_choices}
  end

  defp validate_survey_choices(_type, []), do: :ok
  defp validate_survey_choices(_type, _values), do: {:error, :invalid_awx_survey_choices}

  defp validate_optional_number(field, key) do
    case Map.fetch(field, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if Regex.match?(@number_string, value),
          do: :ok,
          else: {:error, :invalid_awx_survey_bounds}

      _ ->
        {:error, :invalid_awx_survey_bounds}
    end
  end

  defp validate_survey_bounds(field) do
    case {Map.get(field, "min"), Map.get(field, "max")} do
      {nil, _max} ->
        :ok

      {_min, nil} ->
        :ok

      {min, max} ->
        if compare_decimal_strings(min, max) == :gt,
          do: {:error, :invalid_awx_survey_bounds},
          else: :ok
    end
  end

  defp compare_decimal_strings(left, right) do
    case {Decimal.parse(left), Decimal.parse(right)} do
      {{left, ""}, {right, ""}} -> Decimal.compare(left, right)
      _ -> :gt
    end
  end

  defp validate_optional_description(field) do
    case Map.fetch(field, "question_description") do
      :error -> :ok
      {:ok, value} -> bounded_text(value, 8_192, true)
    end
  end

  defp dispatch_marker_validation_field(field) do
    Enum.reduce(["min", "max"], field, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when is_binary(value) ->
          case Integer.parse(value) do
            {parsed, ""} -> Map.put(acc, key, parsed)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp required_dispatch_markers(markers) do
    required =
      DispatchMarkerContract.contract()
      |> Map.fetch!("fields")
      |> MapSet.new(& &1["variable"])

    if markers == required,
      do: :ok,
      else: {:error, :awx_dispatch_marker_survey_incomplete}
  end

  defp validate_project(value) do
    with :ok <- exact_map(value, @project_keys),
         :ok <- valid_positive_id(value["id"]),
         :ok <- bounded_text(value["name"], 255, false),
         :ok <- valid_timestamp(value["modified"]),
         :ok <- valid_slug(value["scm_type"]),
         :ok <- valid_scm_url(value["scm_url"]),
         :ok <- bounded_text(value["scm_branch"], 512, true),
         :ok <- valid_scm_revision(value["scm_revision"]),
         :ok <- equals(value["scm_clean"], true, :awx_project_must_be_clean) do
      bounded_text(value["status"], 64, false)
    end
  end

  defp validate_inventory(value) do
    with :ok <- exact_map(value, @inventory_keys),
         :ok <- valid_positive_id(value["id"]),
         :ok <- bounded_text(value["name"], 255, false),
         :ok <- valid_timestamp(value["modified"]) do
      bounded_text(value["kind"], 64, true)
    end
  end

  defp validate_credentials(values)
       when is_list(values) and length(values) in 1..@max_credentials do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, ids} ->
      case validate_credential(value) do
        :ok -> {:cont, {:ok, [value["id"] | ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed_ids} ->
        ids = Enum.reverse(reversed_ids)

        if ids == sort_ids(ids) and length(ids) == length(Enum.uniq(ids)),
          do: :ok,
          else: {:error, :awx_credentials_must_be_sorted_and_unique}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_credentials(_values), do: {:error, :invalid_awx_credentials}

  defp validate_credential(value) do
    with :ok <- exact_map(value, @credential_keys),
         :ok <- valid_positive_id(value["id"]),
         :ok <- bounded_text(value["name"], 255, false),
         :ok <- valid_timestamp(value["modified"]) do
      validate_credential_type(value["type"])
    end
  end

  defp validate_credential_type(value) do
    with :ok <- exact_map(value, @credential_type_keys),
         :ok <- valid_positive_id(value["id"]),
         :ok <- bounded_text(value["name"], 255, false) do
      valid_slug(value["kind"])
    end
  end

  defp validate_environment(value) do
    with :ok <- exact_map(value, @environment_keys),
         :ok <- valid_positive_id(value["id"]),
         :ok <- bounded_text(value["name"], 255, false),
         :ok <- bounded_text(value["image_reference"], 2_048, false),
         :ok <- valid_fingerprint(value["image_digest"]) do
      immutable_image_reference(value["image_reference"], value["image_digest"])
    end
  end

  defp validate_hosts(hosts) when is_list(hosts) and length(hosts) <= @max_hosts do
    hosts
    |> Enum.reduce_while({:ok, []}, fn host, {:ok, ids} ->
      case validate_host(host) do
        :ok -> {:cont, {:ok, [host["awx_host_id"] | ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed_ids} ->
        ids = Enum.reverse(reversed_ids)

        if ids == sort_ids(ids) and length(ids) == length(Enum.uniq(ids)),
          do: :ok,
          else: {:error, :awx_selected_hosts_must_be_sorted_and_unique}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_hosts(_hosts), do: {:error, :invalid_awx_selected_hosts}

  defp validate_request_hosts(hosts, controller_id, inventory_id)
       when is_list(hosts) and length(hosts) in 1..@max_hosts do
    hosts
    |> Enum.reduce_while({:ok, %{host_ids: [], membership_ids: MapSet.new()}}, fn host,
                                                                                  {:ok, acc} ->
      case validate_request_host(host, controller_id, inventory_id) do
        :ok ->
          membership_id = host["membership_id"]

          if MapSet.member?(acc.membership_ids, membership_id) do
            {:halt, {:error, :duplicate_awx_selected_host_membership}}
          else
            {:cont,
             {:ok,
              %{
                host_ids: [host["awx_host_id"] | acc.host_ids],
                membership_ids: MapSet.put(acc.membership_ids, membership_id)
              }}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, %{host_ids: reversed_ids}} ->
        ids = Enum.reverse(reversed_ids)

        if ids == sort_ids(ids),
          do: :ok,
          else: {:error, :awx_selected_hosts_must_be_sorted_and_unique}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_request_hosts(_hosts, _controller_id, _inventory_id),
    do: {:error, :invalid_awx_selected_hosts}

  defp validate_request_host(value, controller_id, inventory_id) do
    with :ok <- exact_map(value, @request_host_keys),
         :ok <- valid_lower_uuid(value["membership_id"]),
         :ok <-
           equals(value["controller_id"], controller_id, :awx_selected_host_controller_mismatch),
         :ok <- equals(value["inventory_id"], inventory_id, :awx_selected_host_inventory_mismatch),
         :ok <- valid_positive_id(value["awx_host_id"]),
         :ok <- bounded_text(value["canonical_device_uid"], 1_024, false),
         :ok <- valid_normalized_host_name(value["host_name"]),
         :ok <- valid_normalized_address(value["ansible_host"]),
         :ok <- equals(value["enabled"], true, :awx_selected_host_must_be_enabled),
         :ok <- valid_positive_id(value["membership_generation"]) do
      valid_fingerprint(value["source_fingerprint"])
    end
  end

  defp validate_host(value) do
    with :ok <- exact_map(value, @host_keys),
         :ok <- valid_lower_uuid(value["membership_id"]),
         :ok <- valid_lower_uuid(value["controller_id"]),
         :ok <- valid_positive_id(value["inventory_id"]),
         :ok <- valid_positive_id(value["awx_host_id"]),
         :ok <- bounded_text(value["canonical_device_uid"], 1_024, false),
         :ok <- valid_normalized_host_name(value["host_name"]),
         :ok <- valid_normalized_address(value["ansible_host"]),
         :ok <- equals(value["enabled"], true, :awx_selected_host_must_be_enabled),
         :ok <- valid_positive_id(value["membership_generation"]),
         :ok <- valid_fingerprint(value["source_fingerprint"]) do
      valid_digest(value["identity_variables_digest"])
    end
  end

  defp validate_internal_references(snapshot) do
    template = snapshot["template"]
    project = snapshot["project"]
    inventory = snapshot["inventory"]
    environment = snapshot["execution_environment"]
    credentials = snapshot["credentials"]
    host_controller_ids = Enum.map(snapshot["selected_hosts"], & &1["controller_id"])
    host_inventory_ids = Enum.map(snapshot["selected_hosts"], & &1["inventory_id"])

    cond do
      template["project_id"] != project["id"] ->
        {:error, :awx_template_project_reference_mismatch}

      template["inventory_id"] != inventory["id"] ->
        {:error, :awx_template_inventory_reference_mismatch}

      template["execution_environment_id"] != environment["id"] ->
        {:error, :awx_template_environment_reference_mismatch}

      template["credential_ids"] != Enum.map(credentials, & &1["id"]) ->
        {:error, :awx_template_credential_reference_mismatch}

      Enum.any?(host_controller_ids, &(&1 != snapshot["controller_id"])) ->
        {:error, :awx_selected_host_controller_mismatch}

      Enum.any?(host_inventory_ids, &(&1 != inventory["id"])) ->
        {:error, :awx_selected_host_inventory_mismatch}

      true ->
        :ok
    end
  end

  defp compare_request_targets(expected_hosts, live_hosts)
       when length(expected_hosts) == length(live_hosts) do
    expected_hosts
    |> Enum.zip(live_hosts)
    |> Enum.reduce_while(:ok, fn {expected, live}, :ok ->
      with :ok <-
             equals(
               Map.take(live, MapSet.to_list(@request_host_keys)),
               expected,
               :awx_preflight_target_mismatch
             ),
           {:ok, expected_identity_digest} <-
             CanonicalJSON.digest(%{"ansible_host" => expected["ansible_host"]}),
           :ok <-
             equals(
               live["identity_variables_digest"],
               expected_identity_digest,
               :awx_preflight_target_mismatch
             ) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp compare_request_targets(_expected_hosts, _live_hosts),
    do: {:error, :awx_preflight_target_mismatch}

  defp reviewed_snapshot_presence(nil, nil), do: {:error, :reviewed_launch_snapshot_required}

  defp reviewed_snapshot_presence(nil, _digest),
    do: {:error, :reviewed_launch_snapshot_incomplete}

  defp reviewed_snapshot_presence(_snapshot, nil),
    do: {:error, :reviewed_launch_snapshot_incomplete}

  defp reviewed_snapshot_presence(_snapshot, _digest), do: :ok

  defp reviewed_metadata_digest_matches(binding, snapshot_digest) do
    with :ok <- valid_digest(snapshot_digest),
         {:ok, metadata} <- normalized_map(binding_value(binding, :review_metadata)),
         :ok <-
           equals(
             metadata["awx_snapshot_digest"],
             snapshot_digest,
             :review_metadata_snapshot_digest_mismatch
           ) do
      :ok
    else
      _ -> {:error, :review_metadata_snapshot_digest_mismatch}
    end
  end

  defp require_static_hosts(%{"selected_hosts" => []}), do: :ok

  defp require_static_hosts(_snapshot),
    do: {:error, :reviewed_launch_snapshot_must_not_include_targets}

  defp require_live_hosts(%{"selected_hosts" => [_first | _rest]}), do: :ok
  defp require_live_hosts(_snapshot), do: {:error, :awx_preflight_selected_hosts_required}

  defp validate_binding_projection(binding, snapshot) do
    template = snapshot["template"]
    project = snapshot["project"]
    inventory = snapshot["inventory"]
    prompts = template["prompt_on_launch"]

    with :ok <- same_uuid(snapshot["controller_id"], binding_value(binding, :controller_id)),
         :ok <- same_id(template["id"], binding_value(binding, :job_template_id)),
         :ok <- same_id(project["id"], binding_value(binding, :project_id)),
         :ok <- same_value(project["scm_revision"], binding_value(binding, :scm_revision)),
         :ok <- inventory_allowed(inventory["id"], binding_value(binding, :allowed_inventory_ids)),
         :ok <- credentials_match(snapshot["credentials"], binding_value(binding, :credentials)),
         :ok <-
           same_id(environment_id(snapshot), binding_value(binding, :execution_environment_id)),
         :ok <-
           equals(
             binding_value(binding, :project_update_on_launch),
             false,
             :binding_project_update_forbidden
           ),
         :ok <- prompt_matches_binding(prompts, binding),
         :ok <- job_type_matches_binding(template["job_type"], binding),
         {:ok, _contract} <-
           DispatchMarkerContract.from_review_metadata(binding_value(binding, :review_metadata)) do
      :ok
    else
      _ -> {:error, :reviewed_launch_snapshot_binding_mismatch}
    end
  end

  defp environment_id(snapshot), do: snapshot["execution_environment"]["id"]

  defp same_uuid(left, right) do
    case {Ecto.UUID.cast(left), Ecto.UUID.cast(right)} do
      {{:ok, normalized}, {:ok, normalized}} -> :ok
      _ -> {:error, :reviewed_launch_snapshot_binding_mismatch}
    end
  end

  defp same_id(left, right) when is_integer(right) and right > 0 do
    if right <= @max_awx_id and left == Integer.to_string(right),
      do: :ok,
      else: {:error, :reviewed_launch_snapshot_binding_mismatch}
  end

  defp same_id(left, right) when is_binary(right) do
    if match?(:ok, valid_positive_id(right)) and left == right,
      do: :ok,
      else: {:error, :reviewed_launch_snapshot_binding_mismatch}
  end

  defp same_id(_left, _right), do: {:error, :reviewed_launch_snapshot_binding_mismatch}

  defp same_value(left, right) when left == right, do: :ok
  defp same_value(_left, _right), do: {:error, :reviewed_launch_snapshot_binding_mismatch}

  defp inventory_allowed(inventory_id, ids) when is_list(ids) do
    if Enum.any?(ids, &(same_id(inventory_id, &1) == :ok)),
      do: :ok,
      else: {:error, :reviewed_launch_snapshot_binding_mismatch}
  end

  defp inventory_allowed(_inventory_id, _ids),
    do: {:error, :reviewed_launch_snapshot_binding_mismatch}

  defp credentials_match(snapshot_credentials, binding_credentials)
       when is_list(binding_credentials) do
    with {:ok, refs} <- binding_credential_refs(binding_credentials) do
      expected = Enum.sort_by(refs, & &1["id"])

      actual =
        Enum.map(snapshot_credentials, fn credential ->
          %{"id" => credential["id"], "kind" => credential["type"]["kind"]}
        end)

      if actual ==
           Enum.map(expected, &%{"id" => Integer.to_string(&1["id"]), "kind" => &1["kind"]}),
         do: :ok,
         else: {:error, :reviewed_launch_snapshot_binding_mismatch}
    end
  end

  defp credentials_match(_snapshot_credentials, _binding_credentials),
    do: {:error, :reviewed_launch_snapshot_binding_mismatch}

  defp binding_credential_refs(credentials) do
    credentials
    |> Enum.reduce_while({:ok, []}, fn credential, {:ok, refs} ->
      with {:ok, normalized} <- normalized_map(credential),
           true <- MapSet.equal?(MapSet.new(Map.keys(normalized)), MapSet.new(["id", "kind"])),
           true <-
             is_integer(normalized["id"]) and normalized["id"] > 0 and
               normalized["id"] <= @max_awx_id,
           true <- valid_slug?(normalized["kind"]) do
        {:cont, {:ok, [%{"id" => normalized["id"], "kind" => normalized["kind"]} | refs]}}
      else
        _ -> {:halt, {:error, :reviewed_launch_snapshot_binding_mismatch}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp prompt_matches_binding(prompts, binding) do
    expected = %{
      "ask_inventory_on_launch" => binding_value(binding, :ask_inventory_on_launch),
      "ask_credential_on_launch" => binding_value(binding, :ask_credential_on_launch),
      "ask_limit_on_launch" => binding_value(binding, :ask_limit_on_launch),
      "ask_job_type_on_launch" => binding_value(binding, :ask_job_type_on_launch)
    }

    if Enum.all?(expected, fn {key, value} -> is_boolean(value) and prompts[key] == value end),
      do: :ok,
      else: {:error, :reviewed_launch_snapshot_binding_mismatch}
  end

  defp job_type_matches_binding(job_type, binding) do
    case {binding_value(binding, :run_mode_supported),
          binding_value(binding, :check_mode_supported)} do
      {true, false} when job_type == "run" -> :ok
      {false, true} when job_type == "check" -> :ok
      {true, true} when job_type in ["run", "check"] -> :ok
      _ -> {:error, :reviewed_launch_snapshot_binding_mismatch}
    end
  end

  defp validate_string_only_json(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn
      {key, nested}, :ok ->
        if is_binary(key) and safe_launch_preflight_text(key, 256, false) do
          case validate_string_only_json(nested) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        else
          {:halt, {:error, :awx_launch_contract_keys_must_be_strings}}
        end
    end)
  end

  defp validate_string_only_json(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn nested, :ok ->
      case validate_string_only_json(nested) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_string_only_json(value) when is_binary(value) do
    if safe_launch_preflight_text(value, @max_projected_result_bytes, true),
      do: :ok,
      else: {:error, :invalid_awx_launch_contract_text}
  end

  defp validate_string_only_json(value) when is_boolean(value), do: :ok

  defp validate_string_only_json(value) when is_float(value),
    do: {:error, :awx_launch_contract_floats_forbidden}

  defp validate_string_only_json(_value),
    do: {:error, :awx_launch_contract_values_must_be_strings_or_booleans}

  defp validate_secret_free(snapshot) do
    if CredentialRedactor.redact(snapshot) == snapshot and
         not contains_secret_reference?(snapshot),
       do: :ok,
       else: {:error, :awx_launch_contract_must_be_secret_free}
  end

  defp contains_secret_reference?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, nested} -> contains_secret_reference?(nested) end)

  defp contains_secret_reference?(value) when is_list(value),
    do: Enum.any?(value, &contains_secret_reference?/1)

  defp contains_secret_reference?(value) when is_binary(value) do
    normalized = String.downcase(value)
    String.contains?(normalized, ["secretref:", "credentialref:", "bearer ", "pveapitoken="])
  end

  defp contains_secret_reference?(_value), do: false

  defp exact_map(value, expected_keys) when is_map(value) do
    if MapSet.new(Map.keys(value)) == expected_keys,
      do: :ok,
      else: {:error, :invalid_awx_launch_contract_fields}
  end

  defp exact_map(_value, _expected_keys), do: {:error, :invalid_awx_launch_contract_fields}

  defp map_with_required_and_optional_keys(value, required, optional) when is_map(value) do
    keys = MapSet.new(Map.keys(value))

    if MapSet.subset?(required, keys) and MapSet.subset?(keys, MapSet.union(required, optional)),
      do: :ok,
      else: {:error, :invalid_awx_survey_fields}
  end

  defp map_with_required_and_optional_keys(_value, _required, _optional),
    do: {:error, :invalid_awx_survey_fields}

  defp normalized_map(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, normalized} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(normalized_key) and String.valid?(normalized_key) and
           not Map.has_key?(normalized, normalized_key) do
        {:cont, {:ok, Map.put(normalized, normalized_key, nested)}}
      else
        {:halt, {:error, :invalid_awx_launch_contract_fields}}
      end
    end)
  end

  defp normalized_map(_value), do: {:error, :invalid_awx_launch_contract_fields}

  defp valid_lower_uuid(value) when is_binary(value) do
    # Ecto.UUID.cast/1 accepts 16-byte UUID binaries and normalizes a few
    # textual variants. The Go plugin accepts only the already-canonical
    # lowercase spelling, so the cast result must be *exactly* the supplied
    # string rather than merely a valid UUID value.
    if Regex.match?(@lower_uuid, value) and Ecto.UUID.cast(value) == {:ok, value},
      do: :ok,
      else: {:error, :invalid_awx_controller_id}
  end

  defp valid_lower_uuid(_value), do: {:error, :invalid_awx_controller_id}

  defp valid_positive_id(value) when is_binary(value) do
    if canonical_decimal_in_range?(value, @canonical_positive_id, 1, @max_awx_id),
      do: :ok,
      else: {:error, :invalid_awx_resource_id}
  end

  defp valid_positive_id(_value), do: {:error, :invalid_awx_resource_id}

  defp valid_nonnegative_setting(value, max) when is_binary(value) and is_integer(max) do
    if canonical_decimal_in_range?(value, @canonical_nonnegative_id, 0, max),
      do: :ok,
      else: {:error, :invalid_awx_numeric_setting}
  end

  defp valid_nonnegative_setting(_value, _max), do: {:error, :invalid_awx_numeric_setting}

  defp canonical_decimal_in_range?(value, pattern, minimum, maximum) do
    if Regex.match?(pattern, value) do
      case Integer.parse(value) do
        {parsed, ""} when parsed >= minimum and parsed <= maximum -> true
        _ -> false
      end
    else
      false
    end
  end

  defp sorted_unique_ids(values) when is_list(values) and length(values) <= @max_credentials do
    if Enum.all?(values, &match?(:ok, valid_positive_id(&1))) and values == sort_ids(values) and
         length(values) == length(Enum.uniq(values)),
       do: :ok,
       else: {:error, :awx_ids_must_be_sorted_and_unique}
  end

  defp sorted_unique_ids(_values), do: {:error, :awx_ids_must_be_sorted_and_unique}

  defp sort_ids(values), do: Enum.sort_by(values, &String.to_integer/1)

  defp bounded_text(value, max, allow_empty) when is_binary(value) do
    if safe_launch_preflight_text(value, max, allow_empty),
      do: :ok,
      else: {:error, :invalid_awx_text}
  end

  defp bounded_text(_value, _max, _allow_empty), do: {:error, :invalid_awx_text}

  # This mirrors the plugin's `safeLaunchPreflightText`: Cc and Cf are
  # rejected by its shared static-text guard, and Zl/Zp are additionally
  # rejected because Go and Jason encode those separators differently.
  defp safe_launch_preflight_text(value, max, allow_empty) when is_binary(value) do
    String.valid?(value) and byte_size(value) <= max and
      (allow_empty or byte_size(value) > 0) and
      not String.match?(value, @forbidden_text_codepoints)
  end

  defp safe_launch_preflight_text(_value, _max, _allow_empty), do: false

  defp valid_normalized_host_name(value) when is_binary(value) do
    case normalize_host_name(value) do
      {:ok, ^value} -> :ok
      _ -> {:error, :invalid_awx_selected_host_name}
    end
  end

  defp valid_normalized_host_name(_value), do: {:error, :invalid_awx_selected_host_name}

  defp normalize_host_name(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if literal_awx_host_token?(normalized),
      do: {:ok, normalized},
      else: {:error, :invalid_awx_selected_host_name}
  end

  defp normalize_host_name(_value), do: {:error, :invalid_awx_selected_host_name}

  defp literal_awx_host_token?(value) when is_binary(value) do
    byte_size(value) in 1..255 and value not in ["all", "ungrouped"] and
      value
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.all?(fn {char, index} ->
        ascii_alpha_numeric?(char) or
          (index > 0 and char in [?., ?_, ?-])
      end)
  end

  defp literal_awx_host_token?(_value), do: false

  defp ascii_alpha_numeric?(char) do
    char in ?A..?Z or char in ?a..?z or char in ?0..?9
  end

  defp valid_normalized_address(value) when is_binary(value) do
    case normalize_address(value) do
      {:ok, ^value} -> :ok
      _ -> {:error, :invalid_awx_selected_host_address}
    end
  end

  defp valid_normalized_address(_value), do: {:error, :invalid_awx_selected_host_address}

  defp normalize_address(value) when is_binary(value) do
    value = value |> String.trim() |> strip_ipv6_brackets()

    cond do
      not safe_launch_preflight_text(value, 255, false) ->
        {:error, :invalid_awx_selected_host_address}

      String.contains?(value, ["/", "\\", "@", "?", "#", "%"]) ->
        {:error, :invalid_awx_selected_host_address}

      String.contains?(value, ":") ->
        if value |> :binary.bin_to_list() |> Enum.all?(&ipv6_address_byte?/1),
          do: {:ok, String.downcase(value)},
          else: {:error, :invalid_awx_selected_host_address}

      true ->
        normalized = value |> String.downcase() |> strip_one_trailing_dot()

        if normalized != "" and not String.contains?(normalized, "..") and
             normalized
             |> :binary.bin_to_list()
             |> Enum.all?(&hostname_address_byte?/1),
           do: {:ok, normalized},
           else: {:error, :invalid_awx_selected_host_address}
    end
  end

  defp normalize_address(_value), do: {:error, :invalid_awx_selected_host_address}

  defp strip_ipv6_brackets(value) do
    if byte_size(value) >= 2 and String.starts_with?(value, "[") and String.ends_with?(value, "]"),
      do: binary_part(value, 1, byte_size(value) - 2),
      else: value
  end

  defp strip_one_trailing_dot(value) do
    if String.ends_with?(value, "."),
      do: binary_part(value, 0, byte_size(value) - 1),
      else: value
  end

  defp ipv6_address_byte?(char),
    do: char in ?0..?9 or char in ?a..?f or char in ?A..?F or char in [?:, ?.]

  defp hostname_address_byte?(char), do: char in ?a..?z or char in ?0..?9 or char in [?., ?_, ?-]

  defp valid_playbook(value) do
    with :ok <- bounded_text(value, 1_024, false),
         false <- String.starts_with?(value, "/"),
         false <- Enum.member?(String.split(value, "/", trim: false), "..") do
      :ok
    else
      _ -> {:error, :invalid_awx_playbook}
    end
  end

  defp valid_timestamp(value) when is_binary(value) do
    if match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value)),
      do: :ok,
      else: {:error, :invalid_awx_timestamp}
  end

  defp valid_timestamp(_value), do: {:error, :invalid_awx_timestamp}

  defp valid_scm_revision(value) when is_binary(value) do
    if Regex.match?(@scm_revision, value), do: :ok, else: {:error, :invalid_awx_scm_revision}
  end

  defp valid_scm_revision(_value), do: {:error, :invalid_awx_scm_revision}

  defp valid_slug(value) do
    if valid_slug?(value), do: :ok, else: {:error, :invalid_awx_slug}
  end

  defp valid_slug?(value), do: is_binary(value) and Regex.match?(@slug, value)

  defp valid_scm_url(value) do
    with :ok <- bounded_text(value, 2_048, false),
         false <- String.contains?(value, ["?", "#", "@"]),
         true <- String.contains?(value, "://") do
      :ok
    else
      _ -> {:error, :invalid_awx_scm_url}
    end
  end

  defp valid_fingerprint(value) when is_binary(value) do
    if Regex.match?(@sha256_fingerprint, value), do: :ok, else: {:error, :invalid_awx_fingerprint}
  end

  defp valid_fingerprint(_value), do: {:error, :invalid_awx_fingerprint}

  defp immutable_image_reference(reference, digest) do
    if String.ends_with?(reference, "@#{digest}"),
      do: :ok,
      else: {:error, :invalid_awx_execution_environment_image}
  end

  defp all_boolean_values(map, keys, error) do
    if Enum.all?(keys, &is_boolean(map[&1])), do: :ok, else: {:error, error}
  end

  defp boolean(value, _error) when is_boolean(value), do: :ok
  defp boolean(_value, error), do: {:error, error}

  defp one_of(value, values, error) do
    if MapSet.member?(values, value), do: :ok, else: {:error, error}
  end

  defp valid_digest(value) when is_binary(value) do
    if Regex.match?(@sha256_hex, value),
      do: :ok,
      else: {:error, :invalid_awx_launch_contract_digest}
  end

  defp valid_digest(_value), do: {:error, :invalid_awx_launch_contract_digest}

  defp equals(left, right, _error) when left == right, do: :ok
  defp equals(_left, _right, error), do: {:error, error}

  defp binding_value(binding, key) when is_map(binding) and is_atom(key) do
    Map.get(binding, key, Map.get(binding, Atom.to_string(key)))
  end
end
