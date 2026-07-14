defmodule ServiceRadar.Automation.LaunchEnvelopes.Context do
  @moduledoc """
  Canonical authenticated context for one automation launch envelope.

  The context is used as AES-GCM additional authenticated data. Changing any
  persisted binding therefore makes the ciphertext undecryptable instead of
  silently retargeting a callback bearer.
  """

  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig

  @schema "serviceradar.automation_launch_envelope_context/v1"
  @max_ttl_seconds 600
  @max_tenant_bytes 128
  @max_agent_bytes 255
  @max_partition_bytes 128
  @max_callback_url_bytes 2_048
  @max_callback_origin_bytes 512
  @callback_action "remote_access.ssh_ca.bundle.read"
  @callback_path_prefix "/api/v1/automation/callback-grants/"
  @callback_path_suffix "/actions/" <> @callback_action
  @callback_phases ~w(preflight stage verify commit)
  @callback_operations ~w(enroll overlap retire remove)
  @callback_states ~w(present absent)

  @enforce_keys [
    :tenant_id,
    :command_id,
    :child_execution_id,
    :callback_grant_id,
    :controller_id,
    :inventory_id,
    :job_template_id,
    :dispatch_agent_id,
    :dispatch_partition_id,
    :callback_url,
    :callback_allowed_origin,
    :manifest_sha256,
    :scm_revision,
    :content_sha256,
    :callback_phase,
    :callback_operation,
    :callback_state,
    :callback_credential_type_id,
    :callback_credential_organization_id,
    :callback_credential_injector_sha256,
    :expires_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tenant_id: binary(),
          command_id: binary(),
          child_execution_id: binary(),
          callback_grant_id: binary(),
          controller_id: binary(),
          inventory_id: pos_integer(),
          job_template_id: pos_integer(),
          dispatch_agent_id: binary(),
          dispatch_partition_id: binary(),
          callback_url: binary(),
          callback_allowed_origin: binary(),
          manifest_sha256: binary(),
          scm_revision: binary(),
          content_sha256: binary(),
          callback_phase: binary(),
          callback_operation: binary(),
          callback_state: binary(),
          callback_credential_type_id: pos_integer(),
          callback_credential_organization_id: pos_integer(),
          callback_credential_injector_sha256: binary(),
          expires_at: DateTime.t()
        }

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(attrs, opts \\ [])

  def new(attrs, opts) when is_map(attrs) do
    issued_at = opts |> Keyword.get(:issued_at, DateTime.utc_now()) |> normalize_datetime()

    with {:ok, tenant_id} <- bounded_string(value(attrs, :tenant_id), @max_tenant_bytes),
         {:ok, command_id} <- canonical_uuid(value(attrs, :command_id)),
         {:ok, child_execution_id} <- canonical_uuid(value(attrs, :child_execution_id)),
         {:ok, callback_grant_id} <- canonical_uuid(value(attrs, :callback_grant_id)),
         {:ok, controller_id} <- canonical_uuid(value(attrs, :controller_id)),
         {:ok, inventory_id} <- positive_integer(value(attrs, :inventory_id)),
         {:ok, job_template_id} <- positive_integer(value(attrs, :job_template_id)),
         {:ok, dispatch_agent_id} <-
           bounded_string(value(attrs, :dispatch_agent_id), @max_agent_bytes),
         {:ok, dispatch_partition_id} <-
           bounded_string(value(attrs, :dispatch_partition_id), @max_partition_bytes),
         {:ok, callback_allowed_origin} <-
           callback_origin(value(attrs, :callback_allowed_origin)),
         {:ok, callback_url} <-
           callback_url(
             value(attrs, :callback_url),
             callback_allowed_origin,
             callback_grant_id
           ),
         {:ok, manifest_sha256} <- lower_hex(value(attrs, :manifest_sha256), 64..64),
         {:ok, scm_revision} <- lower_hex(value(attrs, :scm_revision), 40..64),
         {:ok, content_sha256} <- lower_hex(value(attrs, :content_sha256), 64..64),
         {:ok, callback_phase} <-
           one_of(value(attrs, :callback_phase), @callback_phases),
         {:ok, callback_operation} <-
           one_of(value(attrs, :callback_operation), @callback_operations),
         {:ok, callback_state} <- one_of(value(attrs, :callback_state), @callback_states),
         :ok <- operation_state_match(callback_operation, callback_state),
         {:ok, callback_credential_type_id} <-
           positive_integer(value(attrs, :callback_credential_type_id)),
         {:ok, callback_credential_organization_id} <-
           positive_integer(value(attrs, :callback_credential_organization_id)),
         {:ok, callback_credential_injector_sha256} <-
           lower_hex(value(attrs, :callback_credential_injector_sha256), 64..64),
         {:ok, expires_at} <- datetime(value(attrs, :expires_at)),
         :ok <- bounded_expiry(issued_at, expires_at) do
      {:ok,
       %__MODULE__{
         tenant_id: tenant_id,
         command_id: command_id,
         child_execution_id: child_execution_id,
         callback_grant_id: callback_grant_id,
         controller_id: controller_id,
         inventory_id: inventory_id,
         job_template_id: job_template_id,
         dispatch_agent_id: dispatch_agent_id,
         dispatch_partition_id: dispatch_partition_id,
         callback_url: callback_url,
         callback_allowed_origin: callback_allowed_origin,
         manifest_sha256: manifest_sha256,
         scm_revision: scm_revision,
         content_sha256: content_sha256,
         callback_phase: callback_phase,
         callback_operation: callback_operation,
         callback_state: callback_state,
         callback_credential_type_id: callback_credential_type_id,
         callback_credential_organization_id: callback_credential_organization_id,
         callback_credential_injector_sha256: callback_credential_injector_sha256,
         expires_at: expires_at
       }}
    end
  end

  def new(_attrs, _opts), do: {:error, :invalid_launch_envelope_context}

  @spec from_record(map()) :: {:ok, t()} | {:error, atom()}
  def from_record(record) when is_map(record) do
    new(
      %{
        tenant_id: value(record, :tenant_id),
        command_id: value(record, :command_id),
        child_execution_id: value(record, :child_execution_id),
        callback_grant_id: value(record, :callback_grant_id),
        controller_id: value(record, :controller_id),
        inventory_id: value(record, :inventory_id),
        job_template_id: value(record, :job_template_id),
        dispatch_agent_id: value(record, :dispatch_agent_id),
        dispatch_partition_id: value(record, :dispatch_partition_id),
        callback_url: value(record, :callback_url),
        callback_allowed_origin: value(record, :callback_allowed_origin),
        manifest_sha256: value(record, :manifest_sha256),
        scm_revision: value(record, :scm_revision),
        content_sha256: value(record, :content_sha256),
        callback_phase: value(record, :callback_phase),
        callback_operation: value(record, :callback_operation),
        callback_state: value(record, :callback_state),
        callback_credential_type_id: value(record, :callback_credential_type_id),
        callback_credential_organization_id: value(record, :callback_credential_organization_id),
        callback_credential_injector_sha256: value(record, :callback_credential_injector_sha256),
        expires_at: value(record, :expires_at)
      },
      issued_at: value(record, :issued_at)
    )
  end

  def from_record(_record), do: {:error, :invalid_launch_envelope_context}

  @spec aad(t()) :: binary()
  def aad(%__MODULE__{} = context) do
    CanonicalJSON.encode!(%{
      "schema" => @schema,
      "tenant_id" => context.tenant_id,
      "command_id" => context.command_id,
      "child_execution_id" => context.child_execution_id,
      "callback_grant_id" => context.callback_grant_id,
      "controller_id" => context.controller_id,
      "inventory_id" => context.inventory_id,
      "job_template_id" => context.job_template_id,
      "dispatch_agent_id" => context.dispatch_agent_id,
      "dispatch_partition_id" => context.dispatch_partition_id,
      "callback_url" => context.callback_url,
      "callback_allowed_origin" => context.callback_allowed_origin,
      "manifest_sha256" => context.manifest_sha256,
      "scm_revision" => context.scm_revision,
      "content_sha256" => context.content_sha256,
      "callback_phase" => context.callback_phase,
      "callback_operation" => context.callback_operation,
      "callback_state" => context.callback_state,
      "callback_credential_type_id" => context.callback_credential_type_id,
      "callback_credential_organization_id" => context.callback_credential_organization_id,
      "callback_credential_injector_sha256" => context.callback_credential_injector_sha256,
      "expires_at_unix_microsecond" => DateTime.to_unix(context.expires_at, :microsecond)
    })
  end

  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = context), do: :crypto.hash(:sha256, aad(context))

  @spec request_matches?(t(), map()) :: boolean()
  def request_matches?(%__MODULE__{} = context, request) when is_map(request) do
    with {:ok, command_id} <- canonical_uuid(value(request, :command_id)),
         {:ok, agent_id} <- bounded_string(value(request, :agent_id), @max_agent_bytes),
         {:ok, partition_id} <-
           bounded_string(value(request, :partition_id), @max_partition_bytes) do
      secure_equal?(context.command_id, command_id) and
        secure_equal?(context.dispatch_agent_id, agent_id) and
        secure_equal?(context.dispatch_partition_id, partition_id)
    else
      _ -> false
    end
  end

  def request_matches?(_context, _request), do: false

  @doc "Checks every callback input against the locked grant and its immutable snapshots."
  @spec grant_matches?(t(), map()) :: boolean()
  def grant_matches?(%__MODULE__{} = context, grant) when is_map(grant) do
    snapshot = value(grant, :target_snapshot) || %{}
    scope = value(grant, :awx_scope_snapshot) || value(snapshot, :awx_scope) || %{}
    response = value(grant, :response_snapshot) || value(snapshot, :response) || %{}

    same_string?(value(grant, :id), context.callback_grant_id) and
      same_string?(value(grant, :tenant_id), context.tenant_id) and
      same_string?(value(grant, :execution_id), context.child_execution_id) and
      same_string?(value(grant, :controller_id), context.controller_id) and
      value(grant, :inventory_id) == context.inventory_id and
      value(grant, :job_template_id) == context.job_template_id and
      same_string?(value(grant, :dispatch_agent_id), context.dispatch_agent_id) and
      same_string?(value(grant, :dispatch_partition_id), context.dispatch_partition_id) and
      datetime_equal?(value(grant, :expires_at), context.expires_at) and
      same_string?(value(grant, :action), @callback_action) and
      same_string?(value(grant, :scm_revision), context.scm_revision) and
      same_string?(value(scope, :scm_revision), context.scm_revision) and
      same_string?(value(grant, :content_sha256), context.content_sha256) and
      same_string?(value(scope, :content_sha256), context.content_sha256) and
      same_string?(value(grant, :manifest_sha256), context.manifest_sha256) and
      same_string?(value(response, :manifest_sha256), context.manifest_sha256) and
      same_string?(value(grant, :callback_phase), context.callback_phase) and
      same_string?(value(response, :phase), context.callback_phase) and
      same_string?(value(grant, :remote_access_operation), context.callback_operation) and
      same_string?(value(response, :operation), context.callback_operation) and
      same_string?(value(grant, :desired_state), context.callback_state) and
      same_string?(value(response, :state), context.callback_state) and
      same_string?(value(scope, :controller_id), context.controller_id) and
      value(scope, :inventory_id) == context.inventory_id and
      value(scope, :job_template_id) == context.job_template_id and
      value(scope, :callback_credential_type_id) == context.callback_credential_type_id and
      value(scope, :callback_credential_organization_id) ==
        context.callback_credential_organization_id and
      same_string?(
        value(scope, :callback_credential_injector_digest),
        context.callback_credential_injector_sha256
      ) and
      callback_url_matches?(context)
  end

  def grant_matches?(_context, _grant), do: false

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{} = context, now) do
    DateTime.compare(context.expires_at, normalize_datetime(now)) != :gt
  end

  defp bounded_expiry(%DateTime{} = issued_at, %DateTime{} = expires_at) do
    latest = DateTime.add(issued_at, @max_ttl_seconds, :second)

    if DateTime.after?(expires_at, issued_at) and
         DateTime.compare(expires_at, latest) in [:lt, :eq] do
      :ok
    else
      {:error, :invalid_launch_envelope_expiry}
    end
  end

  defp bounded_expiry(_issued_at, _expires_at), do: {:error, :invalid_launch_envelope_expiry}

  defp bounded_string(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= max_bytes and String.valid?(value),
      do: {:ok, value},
      else: {:error, :invalid_launch_envelope_context}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_launch_envelope_context}

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_launch_envelope_context}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_launch_envelope_context}

  defp positive_integer(value) when is_integer(value) and value > 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp positive_integer(_value), do: {:error, :invalid_launch_envelope_context}

  defp callback_origin(value) when is_binary(value) do
    origin = String.trim(value)

    with {:ok, canonical} <- RuntimeConfig.canonical_callback_origin(origin),
         true <- canonical == origin,
         true <- byte_size(canonical) <= @max_callback_origin_bytes do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_launch_envelope_callback_origin}
    end
  end

  defp callback_origin(_value), do: {:error, :invalid_launch_envelope_callback_origin}

  defp callback_url(value, origin, callback_grant_id) do
    expected = expected_callback_url(origin, callback_grant_id)
    callback_url = value || expected

    if callback_url == expected and byte_size(expected) <= @max_callback_url_bytes,
      do: {:ok, expected},
      else: {:error, :invalid_launch_envelope_callback_url}
  end

  defp callback_url_matches?(context) do
    expected = expected_callback_url(context.callback_allowed_origin, context.callback_grant_id)
    secure_equal?(context.callback_url, expected)
  end

  defp expected_callback_url(origin, callback_grant_id),
    do: origin <> @callback_path_prefix <> callback_grant_id <> @callback_path_suffix

  defp lower_hex(value, range) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in range and
         Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9 or &1 in ?a..?f)),
       do: {:ok, value},
       else: {:error, :invalid_launch_envelope_callback_metadata}
  end

  defp lower_hex(_value, _range), do: {:error, :invalid_launch_envelope_callback_metadata}

  defp one_of(value, allowed) when is_atom(value), do: one_of(Atom.to_string(value), allowed)

  defp one_of(value, allowed) when is_binary(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, :invalid_launch_envelope_callback_metadata}
  end

  defp one_of(_value, _allowed), do: {:error, :invalid_launch_envelope_callback_metadata}

  defp operation_state_match("remove", "absent"), do: :ok
  defp operation_state_match(operation, "present") when operation != "remove", do: :ok

  defp operation_state_match(_operation, _state),
    do: {:error, :invalid_launch_envelope_callback_metadata}

  defp datetime(%DateTime{} = value), do: {:ok, normalize_datetime(value)}
  defp datetime(_value), do: {:error, :invalid_launch_envelope_expiry}

  defp normalize_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp normalize_datetime(_value), do: nil

  defp datetime_equal?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(normalize_datetime(left), normalize_datetime(right)) == :eq

  defp datetime_equal?(_left, _right), do: false

  defp same_string?(left, right) do
    case {string_value(left), string_value(right)} do
      {left, right} when is_binary(left) and is_binary(right) -> secure_equal?(left, right)
      _ -> false
    end
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(_value), do: nil

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
