defmodule ServiceRadar.Automation.Ansible.CallbackCommandContract do
  @moduledoc """
  Canonical, secret-free callback command and correlation contract.

  Outbox rows retain only scalar correlation fields and SHA-256 digests. The
  actual command request is rebuilt from immutable operation, execution, grant,
  and target state before every dispatch and must match the stored digest.
  """

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.SecretRefs

  @context_schema "serviceradar.automation_callback_command/v1"
  @awx_command_schema "serviceradar.awx_command.v1"
  @callback_binding_schema "serviceradar.awx_callback_credential_binding.v1"
  @terminal_job_statuses ~w(successful failed error canceled)
  @max_recent_candidates 5_000

  @type attempt_source :: map() | struct()

  @spec build_attempt(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_attempt(base, execution, request, opts)
      when is_map(base) and is_map(execution) and is_map(request) and is_list(opts) do
    stage = Keyword.fetch!(opts, :stage)
    purpose = Keyword.fetch!(opts, :purpose)
    command_type = Keyword.fetch!(opts, :command_type)
    command_id = Keyword.get_lazy(opts, :command_id, &Ecto.UUID.generate/0)
    attempt = Keyword.get(opts, :attempt, 1)

    attrs = %{
      grant_id: value(base, :grant_id),
      operation_id: value(base, :operation_id),
      execution_id: value(base, :execution_id),
      controller_id: value(base, :controller_id),
      dispatch_agent_id: value(base, :dispatch_agent_id),
      dispatch_partition_id: value(base, :dispatch_partition_id),
      cleanup_only: Keyword.get(opts, :cleanup_only, false),
      stage: stage,
      purpose: purpose,
      attempt: attempt,
      command_id: command_id,
      command_type: command_type,
      request_schema_version: @context_schema,
      expected_credential_id: Keyword.get(opts, :expected_credential_id),
      expected_job_id: Keyword.get(opts, :expected_job_id),
      reconcile_after: Keyword.get(opts, :reconcile_after),
      terminal_job_snapshot: Keyword.get(opts, :terminal_job_snapshot),
      candidate_job_ids: Keyword.get(opts, :candidate_job_ids, []),
      deadline_at: Keyword.fetch!(opts, :deadline_at),
      next_attempt_at: Keyword.get(opts, :next_attempt_at)
    }

    with {:ok, command_id} <- uuid(command_id),
         :ok <- validate_dispatch_principal(attrs),
         :ok <-
           validate_terminal_evidence(
             purpose,
             attrs.terminal_job_snapshot,
             attrs.expected_job_id
           ),
         :ok <- validate_candidate_jobs(stage, attrs.expected_job_id, attrs.candidate_job_ids),
         context = context(attrs, execution),
         {:ok, request_digest} <- CanonicalJSON.digest(request),
         {:ok, context_digest} <- CanonicalJSON.digest(context) do
      {:ok,
       attrs
       |> Map.put(:command_id, command_id)
       |> Map.put(:request_digest, request_digest)
       |> Map.put(:context_digest, context_digest)}
    end
  end

  def build_attempt(_base, _execution, _request, _opts),
    do: {:error, :invalid_callback_command_attempt}

  defp validate_dispatch_principal(attrs) do
    if nonempty?(attrs.dispatch_agent_id) and nonempty?(attrs.dispatch_partition_id) and
         is_boolean(attrs.cleanup_only),
       do: :ok,
       else: {:error, :invalid_callback_dispatch_principal}
  end

  @spec context(attempt_source(), map() | struct()) :: map()
  def context(attempt, execution) do
    %{
      "schema" => @context_schema,
      "stage" => to_string(value(attempt, :stage)),
      "purpose" => to_string(value(attempt, :purpose)),
      "operation_id" => value(attempt, :operation_id),
      "execution_id" => value(attempt, :execution_id),
      "callback_grant_id" => value(attempt, :grant_id),
      "controller_id" => value(attempt, :controller_id),
      "dispatch_agent_id" => value(attempt, :dispatch_agent_id),
      "dispatch_partition_id" => value(attempt, :dispatch_partition_id),
      "cleanup_only" => value(attempt, :cleanup_only) == true,
      "dispatch_id" => value(execution, :dispatch_id),
      "snapshot_digest" => value(execution, :snapshot_digest),
      "verb" => value(attempt, :command_type)
    }
  end

  @spec create_credential_request(map() | struct(), map(), binary()) ::
          {:ok, map()} | {:error, term()}
  def create_credential_request(execution, grant_scope, envelope_ref)
      when is_map(execution) and is_map(grant_scope) and is_binary(envelope_ref) do
    binding = %{
      envelope_ref: envelope_ref,
      child_execution_id: value(execution, :id),
      inventory_id: value(grant_scope, :inventory_id),
      job_template_id: value(grant_scope, :job_template_id),
      credential_type_id: value(grant_scope, :callback_credential_type_id),
      organization_id: value(grant_scope, :callback_credential_organization_id),
      credential_slot: "ssh_ca_callback",
      injector_sha256: value(grant_scope, :callback_credential_injector_digest)
    }

    if valid_create_binding?(binding),
      do: {:ok, %{binding: binding}},
      else: {:error, :invalid_callback_credential_request}
  end

  def create_credential_request(_execution, _grant_scope, _envelope_ref),
    do: {:error, :invalid_callback_credential_request}

  @spec credential_lookup_request(map() | struct(), map()) :: {:ok, map()} | {:error, term()}
  def credential_lookup_request(execution, grant_scope)
      when is_map(execution) and is_map(grant_scope) do
    request = %{
      credential_type_id: value(grant_scope, :callback_credential_type_id),
      organization_id: value(grant_scope, :callback_credential_organization_id),
      credential_name: "sr-callback-#{value(execution, :id)}"
    }

    if uuid?(value(execution, :id)) and
         positive_integer?(request.credential_type_id) and
         positive_integer?(request.organization_id),
       do: {:ok, request},
       else: {:error, :invalid_callback_credential_lookup_request}
  end

  def credential_lookup_request(_execution, _grant_scope),
    do: {:error, :invalid_callback_credential_lookup_request}

  @spec launch_request(map() | struct(), map() | struct(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def launch_request(operation, execution, credential_id)
      when is_map(operation) and is_map(execution) and is_integer(credential_id) and
             credential_id > 0 do
    credential_snapshot = value(execution, :credential_snapshot) || %{}
    base_credential_ids = List.wrap(value(credential_snapshot, :credential_ids))

    with true <- exact_positive_ids?(base_credential_ids),
         false <- credential_id in base_credential_ids,
         {:ok, extra_vars} <-
           Targeting.launch_extra_vars(
             value(operation, :declared_inputs) || %{},
             value(execution, :dispatch_id),
             value(execution, :snapshot_digest)
           ) do
      {:ok,
       %{
         template_id: value(execution, :job_template_id),
         launch_opts: %{
           inventory_id: value(execution, :inventory_id),
           host_limit: value(execution, :host_limit),
           extra_vars: extra_vars,
           credential_ids: base_credential_ids ++ [credential_id],
           execution_environment_id: value(execution, :execution_environment_id),
           job_type: if(value(execution, :check_mode), do: "check", else: "run"),
           job_slice_count: 1
         }
       }}
    else
      false -> {:error, :invalid_callback_launch_credentials}
      {:error, _reason} = error -> error
    end
  end

  def launch_request(_operation, _execution, _credential_id),
    do: {:error, :invalid_callback_launch_request}

  @spec fetch_job_request(pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_job_request(job_id) when is_integer(job_id) and job_id > 0,
    do: {:ok, %{job_id: job_id}}

  def fetch_job_request(_job_id), do: {:error, :invalid_callback_job_request}

  @spec host_summaries_request(pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def host_summaries_request(job_id, target_count)
      when is_integer(job_id) and job_id > 0 and is_integer(target_count) and
             target_count in 1..10_000 do
    {:ok, %{job_id: job_id, max_hosts: target_count}}
  end

  def host_summaries_request(_job_id, _target_count),
    do: {:error, :invalid_callback_host_summary_request}

  @spec cancel_job_request(pos_integer()) :: {:ok, map()} | {:error, term()}
  def cancel_job_request(job_id) when is_integer(job_id) and job_id > 0,
    do: {:ok, %{job_id: job_id}}

  def cancel_job_request(_job_id), do: {:error, :invalid_callback_cancel_job_request}

  @spec recent_jobs_request(map() | struct(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def recent_jobs_request(execution, %DateTime{} = reconcile_after) when is_map(execution) do
    created_by_id = execution |> value(:metadata) |> value(:awx_created_by_id)

    if positive_integer?(value(execution, :job_template_id)) and
         positive_integer?(value(execution, :inventory_id)) and positive_integer?(created_by_id) do
      {:ok,
       %{
         template_id: value(execution, :job_template_id),
         inventory_id: value(execution, :inventory_id),
         created_by_id: created_by_id,
         created_after: DateTime.to_iso8601(reconcile_after),
         page_size: 50,
         max_candidates: @max_recent_candidates
       }}
    else
      {:error, :invalid_callback_recent_jobs_request}
    end
  end

  def recent_jobs_request(_execution, _reconcile_after),
    do: {:error, :invalid_callback_recent_jobs_request}

  @spec request_matches?(attempt_source(), map()) :: boolean()
  def request_matches?(attempt, request) when is_map(request) do
    case CanonicalJSON.digest(request) do
      {:ok, digest} -> secure_equal?(digest, value(attempt, :request_digest))
      {:error, _reason} -> false
    end
  end

  @spec terminal_job_snapshot?(map()) :: boolean()
  def terminal_job_snapshot?(job) when is_map(job) do
    status = job |> value(:status) |> to_string() |> String.downcase()
    id = value(job, :job_id) || value(job, :id) || value(job, :job)
    status in @terminal_job_statuses and positive_integer?(id)
  end

  def terminal_job_snapshot?(_job), do: false

  defp validate_terminal_evidence(:terminal_confirmation, evidence, expected_job_id) do
    if terminal_job_snapshot?(evidence) and
         terminal_job_id(evidence) == expected_job_id,
       do: :ok,
       else: {:error, :invalid_callback_terminal_job_evidence}
  end

  defp validate_terminal_evidence(_purpose, nil, _expected_job_id), do: :ok

  defp validate_terminal_evidence(_purpose, _evidence, _expected_job_id),
    do: {:error, :invalid_callback_terminal_job_evidence}

  defp terminal_job_id(job), do: value(job, :job_id) || value(job, :id) || value(job, :job)

  defp validate_candidate_jobs(:cancel_job, expected_job_id, candidate_job_ids)
       when is_integer(expected_job_id) and expected_job_id > 0 and is_list(candidate_job_ids) and
              length(candidate_job_ids) <= 5_000 do
    if Enum.all?(candidate_job_ids, &positive_integer?/1) and
         Enum.uniq(candidate_job_ids) == candidate_job_ids and
         expected_job_id not in candidate_job_ids,
       do: :ok,
       else: {:error, :invalid_callback_candidate_job_ids}
  end

  defp validate_candidate_jobs(_stage, _expected_job_id, []), do: :ok

  defp validate_candidate_jobs(_stage, _expected_job_id, _candidate_job_ids),
    do: {:error, :invalid_callback_candidate_job_ids}

  @spec context_matches?(attempt_source(), map() | struct(), map()) :: boolean()
  def context_matches?(attempt, execution, actual) when is_map(actual) do
    expected = context(attempt, execution)

    with {:ok, digest} <- CanonicalJSON.digest(expected),
         true <- secure_equal?(digest, value(attempt, :context_digest)) do
      stringify(actual) == expected
    else
      _ -> false
    end
  end

  def context_matches?(_attempt, _execution, _actual), do: false

  @doc """
  Verifies the persisted AgentCommand payload against the rebuilt request.

  The short-lived credential-broker grant is intentionally excluded from the
  request digest, but its immutable consumer/agent/purpose boundary is still
  checked here. No result field can select a grant or alter command scope.
  """
  @spec persisted_payload_matches?(attempt_source(), map() | struct(), map(), map(), map()) ::
          boolean()
  def persisted_payload_matches?(attempt, execution, controller, request, payload)
      when is_map(execution) and is_map(controller) and is_map(request) and is_map(payload) do
    payload = stringify_deep(payload)
    expected_args = expected_awx_args(attempt, execution, request)
    expected_binding = expected_callback_binding(attempt, execution, controller, request)
    broker = payload["credential_broker"]

    case AwxClient.broker_scope(
           value(controller, :base_url),
           value(attempt, :command_type),
           expected_args
         ) do
      {:ok, scope} ->
        MapSet.new(Map.keys(payload)) ==
          common_payload_keys(expected_binding, scope.authorized_request_body_b64) and
          payload["schema"] == @awx_command_schema and
          payload["verb"] == value(attempt, :command_type) and
          to_string(payload["controller_id"]) == to_string(value(controller, :id)) and
          payload["controller_name"] == value(controller, :name) and
          payload["base_url"] == scope.base_url and
          payload["insecure_skip_verify"] == insecure_skip_verify?(controller) and
          payload["args"] == expected_args and
          payload["authorized_request_body_b64"] == scope.authorized_request_body_b64 and
          payload["callback_credential_binding"] == expected_binding and
          broker_matches?(broker, attempt, controller, scope)

      _ ->
        false
    end
  end

  def persisted_payload_matches?(_attempt, _execution, _controller, _request, _payload), do: false

  defp valid_create_binding?(binding) do
    uuid?(binding.child_execution_id) and nonempty?(binding.envelope_ref) and
      Enum.all?(
        [
          binding.inventory_id,
          binding.job_template_id,
          binding.credential_type_id,
          binding.organization_id
        ],
        &positive_integer?/1
      ) and binding.credential_slot == "ssh_ca_callback" and digest?(binding.injector_sha256)
  end

  defp exact_positive_ids?(ids) do
    ids != [] and Enum.all?(ids, &positive_integer?/1) and Enum.uniq(ids) == ids
  end

  defp expected_awx_args(attempt, execution, request) do
    case value(attempt, :stage) do
      :create_credential ->
        binding = stringify_deep(value(request, :binding) || %{})

        %{
          "credential_type_id" => binding["credential_type_id"],
          "organization_id" => binding["organization_id"],
          "credential_name" => "sr-callback-#{value(execution, :id)}",
          "injector_sha256" => binding["injector_sha256"]
        }

      :fetch_credential ->
        stringify_deep(request)

      :launch_job ->
        request
        |> value(:launch_opts)
        |> stringify_deep()
        |> Map.put("template_id", value(request, :template_id))

      :fetch_job ->
        %{"job_id" => value(request, :job_id)}

      :fetch_host_summaries ->
        %{
          "job_id" => value(request, :job_id),
          "max_hosts" => value(request, :max_hosts)
        }

      :list_recent_jobs ->
        stringify_deep(request)

      :cancel_job ->
        %{"job_id" => value(request, :job_id)}

      _ ->
        nil
    end
  end

  defp expected_callback_binding(attempt, execution, controller, request) do
    if value(attempt, :stage) == :create_credential do
      request
      |> value(:binding)
      |> stringify_deep()
      |> Map.put("schema", @callback_binding_schema)
      |> Map.put("credential_name", "sr-callback-#{value(execution, :id)}")
      |> Map.put("dispatch_agent_id", value(controller, :agent_id))
      |> Map.put("controller_id", value(controller, :id))
    end
  end

  defp common_payload_keys(nil, nil) do
    MapSet.new(
      ~w(schema verb args base_url controller_id controller_name insecure_skip_verify credential_broker)
    )
  end

  defp common_payload_keys(nil, _authorized_request_body_b64) do
    MapSet.put(common_payload_keys(nil, nil), "authorized_request_body_b64")
  end

  defp common_payload_keys(_binding, authorized_request_body_b64) do
    nil
    |> common_payload_keys(authorized_request_body_b64)
    |> MapSet.put("callback_credential_binding")
  end

  defp broker_matches?(broker, attempt, controller, scope) when is_map(broker) do
    broker = stringify_deep(broker)
    consumer = broker["consumer"] || %{}
    target = broker["target"] || %{}
    allow = broker["allow"] || %{}
    expected_inject = expected_broker_inject(controller)

    case AwxClient.credential_secret_id_for_verb(controller, value(attempt, :command_type)) do
      {:ok, secret_id} ->
        MapSet.new(Map.keys(broker)) ==
          MapSet.new(
            ~w(schema grant_id grant_type credential_secret_ref consumer target resolution_location inject allow ttl_seconds expires_at)
          ) and
          broker["schema"] == expected_broker_schema(scope.request_body_policy) and
          uuid?(broker["grant_id"]) and
          broker["grant_type"] == "awx_oauth2_token" and
          broker["credential_secret_ref"] == SecretRefs.network_credential_ref(secret_id) and
          MapSet.new(Map.keys(consumer)) == MapSet.new(~w(kind id purpose)) and
          consumer["kind"] == "ansible" and
          to_string(consumer["id"]) == to_string(value(controller, :id)) and
          consumer["purpose"] == value(attempt, :command_type) and
          MapSet.new(Map.keys(target)) == MapSet.new(~w(kind id agent_id)) and
          target["kind"] == "awx_controller" and
          to_string(target["id"]) == to_string(value(controller, :id)) and
          target["agent_id"] == value(attempt, :dispatch_agent_id) and
          broker["resolution_location"] == "agent" and
          broker["inject"] == expected_inject and
          allow == scope.allow and
          broker["ttl_seconds"] == 300 and
          valid_iso8601?(broker["expires_at"])

      _ ->
        false
    end
  end

  defp broker_matches?(_broker, _attempt, _controller, _scope), do: false

  defp expected_broker_schema(policy) when is_map(policy) and map_size(policy) > 0,
    do: CredentialBrokerGrant.body_bound_schema()

  defp expected_broker_schema(_policy), do: CredentialBrokerGrant.schema()

  defp expected_broker_inject(controller) do
    base = %{
      "type" => "http_header",
      "name" => "Authorization",
      "scheme" => "Bearer"
    }

    if insecure_skip_verify?(controller),
      do: Map.put(base, "allow_insecure_tls", "true"),
      else: base
  end

  defp insecure_skip_verify?(controller),
    do: value(value(controller, :metadata) || %{}, :insecure_skip_verify) == true

  defp valid_iso8601?(value) when is_binary(value),
    do: match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))

  defp valid_iso8601?(_value), do: false

  defp stringify(map), do: Map.new(map, fn {key, item} -> {to_string(key), item} end)

  defp stringify_deep(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify_deep(item)} end)
  end

  defp stringify_deep(value) when is_list(value), do: Enum.map(value, &stringify_deep/1)
  defp stringify_deep(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_deep(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_deep(value), do: value

  defp uuid?(value) do
    match?({:ok, _uuid}, uuid(value))
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_callback_command_id}
    end
  end

  defp uuid(_value), do: {:error, :invalid_callback_command_id}

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and value != "" and String.trim(value) == value
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
