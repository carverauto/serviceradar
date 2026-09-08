defmodule ServiceRadar.Automation.LaunchEnvelopes do
  @moduledoc """
  Allocation-first coordinator for one-time automation callback bearers.

  The opaque reference and command UUID are allocated only in memory. Inside
  one outer store transaction, the supplied callback creates the pending grant
  using that reference and returns its freshly issued bearer; this service then
  seals and persists the envelope. A failure on either side rolls back both,
  so an empty or partially bound envelope is never resolvable.
  """

  alias ServiceRadar.Automation.LaunchEnvelopes.AshStore
  alias ServiceRadar.Automation.LaunchEnvelopes.Cipher
  alias ServiceRadar.Automation.LaunchEnvelopes.CommandPayload
  alias ServiceRadar.Automation.LaunchEnvelopes.Context

  @typedoc "In-memory allocation. It must never be persisted or logged as a whole."
  @type allocation :: %{
          reference: binary(),
          reference_verifier: binary(),
          command_id: binary(),
          issued_at: DateTime.t()
        }

  @type grant_issuer :: (binary(), binary() ->
                           {:ok,
                            %{
                              required(:grant) => map(),
                              required(:bearer) => binary(),
                              required(:idempotency_key) => binary()
                            }}
                           | {:error, term()})

  @doc "Atomically creates a pending grant and its sealed single-use envelope."
  @spec prepare_and_seal(map(), grant_issuer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare_and_seal(context_attrs, issue_grant, opts \\ [])

  def prepare_and_seal(context_attrs, issue_grant, opts)
      when is_map(context_attrs) and is_function(issue_grant, 2) and is_list(opts) do
    store = Keyword.get(opts, :store, AshStore)
    store_context = Keyword.get(opts, :store_context)

    with {:ok, allocation} <- allocation(opts) do
      store.transaction(
        fn ->
          with {:ok, issued} <- issue_grant.(allocation.reference, allocation.command_id),
               {:ok, grant_id, bearer, idempotency_key} <- issued_grant(issued),
               {:ok, context} <-
                 build_context(context_attrs, allocation, grant_id),
               {:ok, encrypted} <-
                 Cipher.encrypt(bearer, idempotency_key, context, cipher_opts(opts)),
               {:ok, _record} <-
                 store.create_sealed(
                   sealed_attrs(allocation, context, encrypted),
                   store_context
                 ),
               {:ok, command_payload} <- CommandPayload.build(allocation.reference) do
            {:ok,
             %{
               grant: Map.fetch!(issued, :grant),
               command_id: allocation.command_id,
               command_payload: command_payload,
               envelope_ref: allocation.reference,
               expires_at: context.expires_at
             }}
          end
        end,
        store_context
      )
    end
  end

  def prepare_and_seal(_context_attrs, _issue_grant, _opts),
    do: {:error, :invalid_launch_envelope_prepare}

  @doc "Resolves one envelope for the exact mTLS-authenticated agent and command."
  @spec resolve(binary(), map(), keyword()) :: {:ok, map()} | {:error, atom() | term()}
  def resolve(reference, request, opts \\ [])

  def resolve(reference, request, opts)
      when is_binary(reference) and is_map(request) and is_list(opts) do
    store = Keyword.get(opts, :store, AshStore)
    store_context = Keyword.get(opts, :store_context)
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    case Cipher.active_key_id(cipher_opts(opts)) do
      {:ok, key_id} ->
        resolve_with_key(reference, request, now, store, store_context, key_id, opts)

      {:error, _reason} ->
        {:error, :launch_envelope_denied}
    end
  end

  def resolve(_reference, _request, _opts), do: {:error, :launch_envelope_denied}

  defp resolve_with_key(reference, request, now, store, store_context, key_id, opts) do
    cipher = %{cipher_version: Cipher.cipher_version(), cipher_key_id: key_id}
    request = Map.put(request, :envelope_ref, reference)

    decrypt = fn sealed ->
      Cipher.decrypt(
        sealed.ciphertext,
        sealed.cipher_version,
        sealed.context,
        cipher_opts(opts)
      )
    end

    with {:ok, verifier} <- Cipher.reference_verifier(reference, cipher_opts(opts)),
         {:ok, resolved} <-
           store.consume(verifier, request, now, cipher, decrypt, store_context) do
      material = resolved.material

      {:ok,
       %{
         bearer: material.bearer,
         idempotency_key: material.idempotency_key,
         callback_grant_id: material.callback_grant_id,
         callback_url: resolved.context.callback_url,
         callback_allowed_origin: resolved.context.callback_allowed_origin,
         manifest_sha256: resolved.context.manifest_sha256,
         scm_revision: resolved.context.scm_revision,
         content_sha256: resolved.context.content_sha256,
         callback_phase: resolved.context.callback_phase,
         callback_operation: resolved.context.callback_operation,
         callback_state: resolved.context.callback_state,
         controller_id: resolved.context.controller_id,
         child_execution_id: resolved.context.child_execution_id,
         inventory_id: resolved.context.inventory_id,
         job_template_id: resolved.context.job_template_id,
         dispatch_agent_id: resolved.context.dispatch_agent_id,
         dispatch_partition_id: resolved.context.dispatch_partition_id,
         command_id: resolved.context.command_id,
         callback_credential_type_id: resolved.context.callback_credential_type_id,
         callback_credential_organization_id:
           resolved.context.callback_credential_organization_id,
         callback_credential_injector_sha256:
           resolved.context.callback_credential_injector_sha256,
         expires_at: resolved.expires_at
       }}
    else
      {:error, :launch_envelope_decrypt_failed} = error -> error
      {:error, _reason} -> {:error, :launch_envelope_denied}
    end
  end

  @doc false
  @spec allocate(keyword()) :: {:ok, allocation()} | {:error, term()}
  def allocate(opts) do
    issued_at = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
    command_id = Keyword.get_lazy(opts, :command_id, &Ecto.UUID.generate/0)

    with {:ok, command_id} <- canonical_uuid(command_id),
         {:ok, reference, verifier} <- Cipher.issue_reference(cipher_opts(opts)) do
      {:ok,
       %{
         reference: reference,
         reference_verifier: verifier,
         command_id: command_id,
         issued_at: issued_at
       }}
    end
  end

  defp allocation(opts) do
    case Keyword.fetch(opts, :allocation) do
      {:ok, supplied} -> validate_allocation(supplied, opts)
      :error -> allocate(opts)
    end
  end

  defp validate_allocation(allocation, opts) when is_map(allocation) do
    reference = value(allocation, :reference)
    supplied_verifier = value(allocation, :reference_verifier)
    issued_at = value(allocation, :issued_at)

    with {:ok, command_id} <- canonical_uuid(value(allocation, :command_id)),
         true <- match?(%DateTime{}, issued_at) || {:error, :invalid_launch_envelope_allocation},
         {:ok, expected_verifier} <- Cipher.reference_verifier(reference, cipher_opts(opts)),
         true <-
           secure_equal?(expected_verifier, supplied_verifier) ||
             {:error, :invalid_launch_envelope_allocation} do
      {:ok,
       %{
         reference: reference,
         reference_verifier: supplied_verifier,
         command_id: command_id,
         issued_at: DateTime.truncate(issued_at, :microsecond)
       }}
    else
      false -> {:error, :invalid_launch_envelope_allocation}
      {:error, _reason} -> {:error, :invalid_launch_envelope_allocation}
    end
  end

  defp validate_allocation(_allocation, _opts), do: {:error, :invalid_launch_envelope_allocation}

  defp issued_grant(%{grant: grant, bearer: bearer, idempotency_key: idempotency_key})
       when is_map(grant) and is_binary(bearer) and is_binary(idempotency_key) do
    case value(grant, :id) do
      grant_id when is_binary(grant_id) -> {:ok, grant_id, bearer, idempotency_key}
      _ -> {:error, :pending_callback_grant_id_missing}
    end
  end

  defp issued_grant(_issued), do: {:error, :invalid_pending_callback_grant_result}

  defp build_context(context_attrs, allocation, grant_id) do
    context_attrs
    |> Map.put(:command_id, allocation.command_id)
    |> Map.put(:callback_grant_id, grant_id)
    |> Context.new(issued_at: allocation.issued_at)
  end

  defp sealed_attrs(allocation, context, encrypted) do
    %{
      reference_verifier: allocation.reference_verifier,
      tenant_id: context.tenant_id,
      command_id: context.command_id,
      child_execution_id: context.child_execution_id,
      callback_grant_id: context.callback_grant_id,
      controller_id: context.controller_id,
      inventory_id: context.inventory_id,
      job_template_id: context.job_template_id,
      dispatch_agent_id: context.dispatch_agent_id,
      dispatch_partition_id: context.dispatch_partition_id,
      callback_url: context.callback_url,
      callback_allowed_origin: context.callback_allowed_origin,
      manifest_sha256: context.manifest_sha256,
      scm_revision: context.scm_revision,
      content_sha256: context.content_sha256,
      callback_phase: context.callback_phase,
      callback_operation: context.callback_operation,
      callback_state: context.callback_state,
      callback_credential_type_id: context.callback_credential_type_id,
      callback_credential_organization_id: context.callback_credential_organization_id,
      callback_credential_injector_sha256: context.callback_credential_injector_sha256,
      context_digest: Context.digest(context),
      ciphertext: encrypted.ciphertext,
      cipher_version: encrypted.cipher_version,
      cipher_key_id: encrypted.cipher_key_id,
      issued_at: allocation.issued_at,
      expires_at: context.expires_at
    }
  end

  defp cipher_opts(opts) do
    Keyword.take(opts, [:encryption_key, :key_id, :random_bytes])
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_launch_envelope_command_id}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_launch_envelope_command_id}

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
