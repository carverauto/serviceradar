defmodule ServiceRadar.Automation.LaunchEnvelopes.Context do
  @moduledoc """
  Canonical authenticated context for one automation launch envelope.

  The context is used as AES-GCM additional authenticated data. Changing any
  persisted binding therefore makes the ciphertext undecryptable instead of
  silently retargeting a callback bearer.
  """

  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @schema "serviceradar.automation_launch_envelope_context/v1"
  @max_ttl_seconds 600
  @max_tenant_bytes 128
  @max_agent_bytes 255

  @enforce_keys [
    :tenant_id,
    :command_id,
    :child_execution_id,
    :callback_grant_id,
    :controller_id,
    :inventory_id,
    :job_template_id,
    :dispatch_agent_id,
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
      "expires_at_unix_microsecond" => DateTime.to_unix(context.expires_at, :microsecond)
    })
  end

  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = context), do: :crypto.hash(:sha256, aad(context))

  @spec request_matches?(t(), map()) :: boolean()
  def request_matches?(%__MODULE__{} = context, request) when is_map(request) do
    with {:ok, command_id} <- canonical_uuid(value(request, :command_id)),
         {:ok, agent_id} <- bounded_string(value(request, :agent_id), @max_agent_bytes) do
      secure_equal?(context.command_id, command_id) and
        secure_equal?(context.dispatch_agent_id, agent_id)
    else
      _ -> false
    end
  end

  def request_matches?(_context, _request), do: false

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

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_launch_envelope_context}

  defp datetime(%DateTime{} = value), do: {:ok, normalize_datetime(value)}
  defp datetime(_value), do: {:error, :invalid_launch_envelope_expiry}

  defp normalize_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp normalize_datetime(_value), do: nil

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
