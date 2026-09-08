defmodule ServiceRadar.Automation.LaunchEnvelopes.AshStore do
  @moduledoc """
  Ash/Postgres implementation of the single-resolution envelope store.

  The row is locked, the pending grant is re-correlated, the envelope is
  decrypted and validated in memory, transitioned, and committed with a
  secret-free audit row in one transaction. Ciphertext and plaintext never
  leave this locked boundary together.
  """

  @behaviour ServiceRadar.Automation.LaunchEnvelopes.Store

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Callbacks.AuditEvent
  alias ServiceRadar.Automation.Callbacks.Grant
  alias ServiceRadar.Automation.Callbacks.LaunchEnvelope
  alias ServiceRadar.Automation.LaunchEnvelopes.CommandPayload
  alias ServiceRadar.Automation.LaunchEnvelopes.Context
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo

  require Ash.Query

  @actor SystemActor.system(:automation_launch_envelope_store)

  @impl true
  def transaction(fun, _context) when is_function(fun, 0) do
    transaction_result =
      Repo.transaction(fn ->
        case fun.() do
          {:ok, value} -> {:ok, value}
          {:commit_error, reason} -> {:commit_error, reason}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:commit_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_sealed(attrs, _context) when is_map(attrs) do
    case LaunchEnvelope.create_sealed(attrs, actor: @actor) do
      {:ok, %LaunchEnvelope{} = envelope} -> {:ok, envelope}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_sealed(_attrs, _context), do: {:error, :invalid_launch_envelope}

  @impl true
  def consume(reference_verifier, request, now, cipher, decrypt, _context)
      when is_binary(reference_verifier) and is_map(request) and is_map(cipher) and
             is_function(decrypt, 1) do
    transaction(
      fn ->
        consume_locked(
          reference_verifier,
          request,
          DateTime.truncate(now, :microsecond),
          cipher,
          decrypt
        )
      end,
      nil
    )
  end

  def consume(_reference_verifier, _request, _now, _cipher, _decrypt, _context),
    do: {:error, :launch_envelope_denied}

  defp consume_locked(reference_verifier, request, now, cipher, decrypt) do
    with {:ok, envelope} <- lock_by_reference(reference_verifier),
         {:ok, context} <- Context.from_record(envelope),
         :ok <- validate_sealed(envelope, context, request, now, cipher),
         {:ok, command} <- lock_command(context.command_id),
         :ok <- validate_command_binding(command, context, request, now),
         {:ok, grant} <- lock_grant(context.callback_grant_id),
         :ok <- validate_grant_binding(grant, context, request, now),
         {:ok, material} <- decrypt_locked(envelope, context, decrypt),
         {:ok, resolved} <-
           LaunchEnvelope.mark_resolved(
             envelope,
             %{
               resolved_at: now,
               resolved_by_agent_id: context.dispatch_agent_id,
               resolved_by_partition_id: context.dispatch_partition_id
             },
             actor: @actor
           ),
         {:ok, _audit} <- record_resolution_audit(grant, now) do
      {:ok,
       %{
         id: resolved.id,
         material: material,
         context: context,
         expires_at: resolved.expires_at
       }}
    else
      {:error, :launch_envelope_expired} -> expire_locked(reference_verifier, now)
      {:error, :launch_envelope_decrypt_failed} = error -> error
      {:error, _reason} -> {:error, :launch_envelope_denied}
    end
  end

  defp decrypt_locked(envelope, context, decrypt) do
    case decrypt.(%{
           ciphertext: envelope.ciphertext,
           cipher_version: envelope.cipher_version,
           context: context,
           expires_at: envelope.expires_at
         }) do
      {:ok, material} when is_map(material) -> {:ok, material}
      _ -> {:error, :launch_envelope_decrypt_failed}
    end
  rescue
    _ -> {:error, :launch_envelope_decrypt_failed}
  catch
    _, _ -> {:error, :launch_envelope_decrypt_failed}
  end

  defp lock_grant(grant_id) do
    Grant
    |> Ash.Query.for_read(:by_id, %{id: grant_id}, actor: @actor)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %Grant{} = grant} -> {:ok, grant}
      {:ok, nil} -> {:error, :callback_grant_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_command(command_id) do
    AgentCommand
    |> Ash.Query.for_read(:by_id, %{id: command_id}, actor: @actor)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %AgentCommand{} = command} -> {:ok, command}
      {:ok, nil} -> {:error, :launch_envelope_command_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_by_reference(reference_verifier) do
    LaunchEnvelope
    |> Ash.Query.for_read(
      :by_reference_verifier,
      %{reference_verifier: reference_verifier},
      actor: @actor
    )
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %LaunchEnvelope{} = envelope} -> {:ok, envelope}
      {:ok, nil} -> {:error, :launch_envelope_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_sealed(envelope, context, request, now, cipher) do
    cond do
      envelope.state != :sealed ->
        {:error, :launch_envelope_already_resolved}

      Context.expired?(context, now) ->
        {:error, :launch_envelope_expired}

      not Context.request_matches?(context, request) ->
        {:error, :launch_envelope_context_mismatch}

      not secure_equal?(Context.digest(context), envelope.context_digest) ->
        {:error, :launch_envelope_context_mismatch}

      envelope.cipher_version != Map.get(cipher, :cipher_version) ->
        {:error, :launch_envelope_cipher_mismatch}

      envelope.cipher_key_id != Map.get(cipher, :cipher_key_id) ->
        {:error, :launch_envelope_key_mismatch}

      true ->
        :ok
    end
  end

  defp validate_grant_binding(grant, context, request, now) do
    cond do
      grant.state != :pending ->
        {:error, :callback_grant_not_pending}

      DateTime.compare(grant.expires_at, now) != :gt ->
        {:error, :launch_envelope_expired}

      not Context.grant_matches?(context, grant) ->
        {:error, :launch_envelope_context_mismatch}

      not secure_equal?(grant.launch_envelope_ref, Map.get(request, :envelope_ref)) ->
        {:error, :launch_envelope_context_mismatch}

      true ->
        :ok
    end
  end

  defp validate_command_binding(command, context, request, now) do
    with true <- command.command_type == "awx.create_callback_credential",
         true <- command.status in [:queued, :sent, :acknowledged, :running],
         true <- secure_equal?(to_string(command.id), context.command_id),
         true <- secure_equal?(command.agent_id, context.dispatch_agent_id),
         true <- secure_equal?(command.partition_id, context.dispatch_partition_id),
         %DateTime{} = expires_at <- command.expires_at,
         true <- DateTime.after?(expires_at, now),
         {:ok, command_reference} <- CommandPayload.parse(command.payload || %{}),
         request_reference when is_binary(request_reference) <- Map.get(request, :envelope_ref),
         true <- secure_equal?(command_reference, request_reference) do
      :ok
    else
      _ -> {:error, :launch_envelope_command_mismatch}
    end
  end

  defp record_resolution_audit(grant, now) do
    remaining_budget = max(grant.budget_limit - grant.budget_used, 0)

    AuditEvent.record(
      %{
        grant_id: grant.id,
        event_key: Ecto.UUID.generate(),
        event_type: :envelope_resolved,
        outcome: :succeeded,
        tenant_id: grant.tenant_id,
        operation_id: grant.operation_id,
        execution_id: grant.execution_id,
        controller_id: grant.controller_id,
        inventory_id: grant.inventory_id,
        job_template_id: grant.job_template_id,
        awx_job_id: grant.awx_job_id,
        action: grant.action,
        action_version: grant.action_version,
        audience: grant.audience,
        principal_type: grant.initiator_principal_type,
        principal_id: grant.initiator_principal_id,
        reason_code: :success,
        policy_version: grant.policy_version,
        budget_before: remaining_budget,
        budget_after: remaining_budget,
        grant_state: grant.state,
        credential_cleanup_state: grant.credential_cleanup_state,
        occurred_at: now
      },
      actor: @actor
    )
  end

  defp expire_locked(reference_verifier, now) do
    with {:ok, envelope} <- lock_by_reference(reference_verifier),
         true <- envelope.state == :sealed,
         {:ok, _expired} <-
           LaunchEnvelope.mark_expired(envelope, %{expired_at: now}, actor: @actor) do
      {:commit_error, :launch_envelope_expired}
    else
      _ -> {:error, :launch_envelope_denied}
    end
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
