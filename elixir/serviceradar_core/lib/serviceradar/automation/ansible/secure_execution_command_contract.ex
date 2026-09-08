defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandContract do
  @moduledoc """
  Canonical, secret-free command contract for hardened non-callback executions.

  The durable attempt stores only scalar bindings, bounded terminal evidence,
  and digests. Requests are rebuilt from the immutable operation/execution rows
  before dispatch. Callback commands use their separate contract and schema.
  """

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.SecretRefs

  @context_schema "serviceradar.automation_execution_command/v1"
  @awx_command_schema "serviceradar.awx_command.v1"
  @max_recent_candidates 5_000
  @type attempt_source :: map() | struct()

  @spec context_schema() :: String.t()
  def context_schema, do: @context_schema

  @spec build_attempt(map(), map() | struct(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_attempt(base, execution, request, opts)
      when is_map(base) and is_map(execution) and is_map(request) and is_list(opts) do
    stage = Keyword.fetch!(opts, :stage)
    purpose = Keyword.fetch!(opts, :purpose)
    command_type = Keyword.fetch!(opts, :command_type)
    command_id = Keyword.get_lazy(opts, :command_id, &Ecto.UUID.generate/0)

    attrs = %{
      operation_id: value(base, :operation_id),
      execution_id: value(base, :execution_id),
      controller_id: value(base, :controller_id),
      dispatch_agent_id: value(base, :dispatch_agent_id),
      dispatch_partition_id: value(base, :dispatch_partition_id),
      stage: stage,
      purpose: purpose,
      attempt: Keyword.get(opts, :attempt, 1),
      command_id: command_id,
      command_type: command_type,
      request_schema_version: @context_schema,
      expected_job_id: Keyword.get(opts, :expected_job_id),
      reconcile_after: Keyword.get(opts, :reconcile_after),
      terminal_job_snapshot: Keyword.get(opts, :terminal_job_snapshot),
      candidate_job_ids: Keyword.get(opts, :candidate_job_ids, []),
      deadline_at: Keyword.fetch!(opts, :deadline_at),
      next_attempt_at: Keyword.get(opts, :next_attempt_at)
    }

    with {:ok, command_id} <- uuid(command_id),
         :ok <- validate_attempt(attrs),
         attrs = Map.put(attrs, :command_id, command_id),
         context = context(attrs, execution),
         {:ok, request_digest} <- CanonicalJSON.digest(request),
         {:ok, context_digest} <- CanonicalJSON.digest(context) do
      {:ok,
       attrs
       |> Map.put(:request_digest, request_digest)
       |> Map.put(:context_digest, context_digest)}
    end
  end

  def build_attempt(_base, _execution, _request, _opts),
    do: {:error, :invalid_secure_execution_command_attempt}

  @spec context(attempt_source(), map() | struct()) :: map()
  def context(attempt, execution) do
    %{
      "schema" => @context_schema,
      "stage" => to_string(value(attempt, :stage)),
      "purpose" => to_string(value(attempt, :purpose)),
      "operation_id" => value(attempt, :operation_id),
      "execution_id" => value(attempt, :execution_id),
      "controller_id" => value(attempt, :controller_id),
      "dispatch_agent_id" => value(attempt, :dispatch_agent_id),
      "dispatch_partition_id" => value(attempt, :dispatch_partition_id),
      "dispatch_id" => value(execution, :dispatch_id),
      "snapshot_digest" => value(execution, :snapshot_digest),
      "verb" => value(attempt, :command_type)
    }
  end

  @spec launch_request(map() | struct(), map() | struct()) ::
          {:ok, map()} | {:error, term()}
  def launch_request(operation, execution) when is_map(operation) and is_map(execution) do
    credential_snapshot = value(execution, :credential_snapshot) || %{}
    credential_ids = List.wrap(value(credential_snapshot, :credential_ids))

    with true <- exact_positive_ids?(credential_ids),
         {:ok, extra_vars} <-
           Targeting.launch_extra_vars(
             value(operation, :declared_inputs) || %{},
             value(execution, :dispatch_id),
             value(execution, :snapshot_digest)
           ),
         true <- positive_integer?(value(execution, :job_template_id)),
         true <- positive_integer?(value(execution, :inventory_id)),
         true <- positive_integer?(value(execution, :execution_environment_id)),
         true <- nonempty?(value(execution, :host_limit)) do
      {:ok,
       %{
         template_id: value(execution, :job_template_id),
         launch_opts: %{
           inventory_id: value(execution, :inventory_id),
           host_limit: value(execution, :host_limit),
           extra_vars: extra_vars,
           credential_ids: credential_ids,
           execution_environment_id: value(execution, :execution_environment_id),
           job_type: if(value(execution, :check_mode), do: "check", else: "run"),
           job_slice_count: 1
         }
       }}
    else
      false -> {:error, :invalid_secure_execution_launch_request}
      {:error, _reason} = error -> error
    end
  end

  def launch_request(_operation, _execution),
    do: {:error, :invalid_secure_execution_launch_request}

  @spec fetch_job_request(pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_job_request(job_id) when is_integer(job_id) and job_id > 0,
    do: {:ok, %{job_id: job_id}}

  def fetch_job_request(_job_id), do: {:error, :invalid_secure_execution_job_request}

  @spec host_summaries_request(pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def host_summaries_request(job_id, target_count)
      when is_integer(job_id) and job_id > 0 and is_integer(target_count) and
             target_count in 1..10_000 do
    {:ok, %{job_id: job_id, max_hosts: target_count}}
  end

  def host_summaries_request(_job_id, _target_count),
    do: {:error, :invalid_secure_execution_host_summary_request}

  @spec recent_jobs_request(map() | struct(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def recent_jobs_request(execution, %DateTime{} = reconcile_after) when is_map(execution) do
    created_by_id = execution |> value(:metadata) |> value(:awx_created_by_id)

    if positive_integer?(value(execution, :job_template_id)) and
         positive_integer?(value(execution, :inventory_id)) and positive_integer?(created_by_id) do
      {:ok,
       %{
         template_id: value(execution, :job_template_id),
         inventory_id: value(execution, :inventory_id),
         created_by_id: created_by_id,
         created_after: rfc3339_nano(reconcile_after),
         page_size: 50,
         max_candidates: @max_recent_candidates
       }}
    else
      {:error, :invalid_secure_execution_recent_jobs_request}
    end
  end

  def recent_jobs_request(_execution, _reconcile_after),
    do: {:error, :invalid_secure_execution_recent_jobs_request}

  @spec cancel_job_request(pos_integer()) :: {:ok, map()} | {:error, term()}
  def cancel_job_request(job_id) when is_integer(job_id) and job_id > 0,
    do: {:ok, %{job_id: job_id}}

  def cancel_job_request(_job_id), do: {:error, :invalid_secure_execution_cancel_request}

  @spec request_matches?(attempt_source(), map()) :: boolean()
  def request_matches?(attempt, request) when is_map(request) do
    case CanonicalJSON.digest(request) do
      {:ok, digest} -> secure_equal?(digest, value(attempt, :request_digest))
      {:error, _reason} -> false
    end
  end

  def request_matches?(_attempt, _request), do: false

  @spec context_matches?(attempt_source(), map() | struct(), map()) :: boolean()
  def context_matches?(attempt, execution, actual) when is_map(actual) do
    expected = context(attempt, execution)

    with {:ok, digest} <- CanonicalJSON.digest(expected),
         true <- secure_equal?(digest, value(attempt, :context_digest)) do
      stringify_deep(actual) == expected
    else
      _ -> false
    end
  end

  def context_matches?(_attempt, _execution, _actual), do: false

  @doc "Verifies the immutable portion of the persisted AgentCommand payload."
  @spec persisted_payload_matches?(attempt_source(), map() | struct(), map(), map(), map()) ::
          boolean()
  def persisted_payload_matches?(attempt, execution, controller, request, payload)
      when is_map(execution) and is_map(controller) and is_map(request) and is_map(payload) do
    payload = stringify_deep(payload)
    broker = payload["credential_broker"]
    verb = value(attempt, :command_type)
    args = expected_awx_args(attempt, execution, request)

    with true <- is_map(args),
         {:ok, scope} <- AwxClient.broker_scope(value(controller, :base_url), verb, args) do
      MapSet.new(Map.keys(payload)) ==
        expected_payload_keys(scope.authorized_request_body_b64) and
        payload["schema"] == @awx_command_schema and
        payload["verb"] == verb and
        to_string(payload["controller_id"]) == to_string(value(controller, :id)) and
        payload["controller_name"] == value(controller, :name) and
        payload["base_url"] == scope.base_url and
        payload["insecure_skip_verify"] == insecure_skip_verify?(controller) and
        payload["args"] == args and
        payload["authorized_request_body_b64"] == scope.authorized_request_body_b64 and
        broker_matches?(broker, attempt, controller, scope)
    else
      _ -> false
    end
  end

  def persisted_payload_matches?(_attempt, _execution, _controller, _request, _payload), do: false

  @spec terminal_job_snapshot?(map()) :: boolean()
  def terminal_job_snapshot?(job) when is_map(job) do
    status = job |> value(:status) |> normalize_status()
    id = positive_integer(value(job, :job_id) || value(job, :id) || value(job, :job))
    status in ~w(successful failed error canceled) and is_integer(id)
  end

  def terminal_job_snapshot?(_job), do: false

  defp validate_attempt(attrs) do
    checks = [
      uuid?(attrs.operation_id),
      uuid?(attrs.execution_id),
      uuid?(attrs.controller_id),
      nonempty?(attrs.dispatch_agent_id),
      nonempty?(attrs.dispatch_partition_id),
      attrs.stage in [
        :launch_job,
        :fetch_job,
        :list_recent_jobs,
        :fetch_host_summaries,
        :cancel_job
      ],
      attrs.purpose in [
        :accepted_job_proof,
        :launch_reconciliation,
        :scope_poll,
        :host_scope_proof,
        :terminal_poll,
        :terminal_confirmation,
        :terminal_cleanup
      ],
      is_integer(attrs.attempt) and attrs.attempt in 1..1_000,
      is_struct(attrs.deadline_at, DateTime),
      is_nil(attrs.next_attempt_at) or is_struct(attrs.next_attempt_at, DateTime),
      valid_candidate_job_ids?(attrs.candidate_job_ids),
      valid_terminal_evidence?(attrs.purpose, attrs.terminal_job_snapshot)
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :invalid_secure_execution_command_attempt}
  end

  defp valid_terminal_evidence?(:terminal_confirmation, evidence),
    do: terminal_job_snapshot?(evidence)

  defp valid_terminal_evidence?(_purpose, evidence), do: is_nil(evidence)

  defp valid_candidate_job_ids?(ids) when is_list(ids),
    do: Enum.all?(ids, &positive_integer?/1) and Enum.uniq(ids) == ids and length(ids) <= 5000

  defp valid_candidate_job_ids?(_ids), do: false

  defp expected_awx_args(attempt, _execution, request) do
    case value(attempt, :stage) do
      :launch_job ->
        request
        |> value(:launch_opts)
        |> stringify_deep()
        |> Map.put("template_id", value(request, :template_id))

      :fetch_job ->
        %{"job_id" => value(request, :job_id)}

      :fetch_host_summaries ->
        %{"job_id" => value(request, :job_id), "max_hosts" => value(request, :max_hosts)}

      :list_recent_jobs ->
        stringify_deep(request)

      :cancel_job ->
        %{"job_id" => value(request, :job_id)}

      _ ->
        nil
    end
  end

  defp broker_matches?(broker, attempt, controller, scope) when is_map(broker) do
    broker = stringify_deep(broker)
    consumer = broker["consumer"] || %{}
    target = broker["target"] || %{}
    allow = broker["allow"] || %{}

    MapSet.new(Map.keys(broker)) ==
      MapSet.new(
        ~w(schema grant_id grant_type credential_secret_ref consumer target resolution_location inject allow ttl_seconds expires_at)
      ) and
      broker["schema"] == expected_broker_schema(scope.request_body_policy) and
      uuid?(broker["grant_id"]) and
      broker["grant_type"] == "awx_oauth2_token" and
      exact_credential_secret_ref?(
        broker["credential_secret_ref"],
        controller,
        value(attempt, :command_type)
      ) and
      consumer == %{
        "kind" => "ansible",
        "id" => to_string(value(controller, :id)),
        "purpose" => value(attempt, :command_type)
      } and
      target == %{
        "kind" => "awx_controller",
        "id" => to_string(value(controller, :id)),
        "agent_id" => value(attempt, :dispatch_agent_id)
      } and
      broker["resolution_location"] == "agent" and
      broker["inject"] == expected_broker_inject(controller) and
      allow == scope.allow and broker["ttl_seconds"] == 300 and
      valid_iso8601?(broker["expires_at"])
  end

  defp broker_matches?(_broker, _attempt, _controller, _request), do: false

  defp expected_payload_keys(nil) do
    MapSet.new(
      ~w(schema verb args base_url controller_id controller_name insecure_skip_verify credential_broker)
    )
  end

  defp expected_payload_keys(_authorized_request_body_b64) do
    MapSet.put(expected_payload_keys(nil), "authorized_request_body_b64")
  end

  defp expected_broker_schema(policy) when is_map(policy) and map_size(policy) > 0,
    do: CredentialBrokerGrant.body_bound_schema()

  defp expected_broker_schema(_policy), do: CredentialBrokerGrant.schema()

  defp exact_credential_secret_ref?(actual, controller, verb) do
    case AwxClient.credential_secret_id_for_verb(controller, verb) do
      {:ok, secret_id} -> actual == SecretRefs.network_credential_ref(to_string(secret_id))
      {:error, _reason} -> false
    end
  end

  defp expected_broker_inject(controller) do
    inject = %{"type" => "http_header", "name" => "Authorization", "scheme" => "Bearer"}

    if insecure_skip_verify?(controller),
      do: Map.put(inject, "allow_insecure_tls", "true"),
      else: inject
  end

  defp insecure_skip_verify?(controller),
    do: value(value(controller, :metadata) || %{}, :insecure_skip_verify) == true

  defp valid_iso8601?(value) when is_binary(value),
    do: match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))

  defp valid_iso8601?(_value), do: false

  defp exact_positive_ids?(ids),
    do: ids != [] and Enum.all?(ids, &positive_integer?/1) and Enum.uniq(ids) == ids

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
  defp nonempty?(value), do: is_binary(value) and value != "" and String.trim(value) == value

  defp uuid?(value), do: match?({:ok, _uuid}, uuid(value))

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_secure_execution_command_id}
    end
  end

  defp uuid(_value), do: {:error, :invalid_secure_execution_command_id}

  defp normalize_status(status), do: status |> to_string() |> String.trim() |> String.downcase()

  # Go's time.RFC3339Nano, used by the AWX plugin's echoed reconciliation
  # selector, removes trailing fractional zeroes. Produce the same canonical
  # wire value so the persisted request digest can be compared byte-for-byte.
  defp rfc3339_nano(%DateTime{} = datetime) do
    utc = DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
    {microsecond, _precision} = utc.microsecond

    fraction =
      microsecond
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")

    suffix = if fraction == "", do: "Z", else: ".#{fraction}Z"
    Calendar.strftime(utc, "%Y-%m-%dT%H:%M:%S") <> suffix
  end

  defp stringify_deep(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify_deep(item)} end)
  end

  defp stringify_deep(value) when is_list(value), do: Enum.map(value, &stringify_deep/1)
  defp stringify_deep(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_deep(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_deep(value), do: value

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
