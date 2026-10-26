defmodule ServiceRadar.Camera.ArchiveUploads do
  @moduledoc """
  Retains immutable upload intent and one bounded dispatch observation record.

  Object keys, lengths and digests come only from the locked frozen descriptor
  and bound destination. An exact retry returns the retained intent, including
  after lease replacement. Preparation neither sends bytes nor authorizes a
  future request. Dispatch marking is committed before returning, and only the
  first caller receives `:marked`; a retry receives `:already_marked`. This is
  local coordination evidence, not provider qualification or permission to send.
  Only `authorize/6` adds a current, short-lived operation authority grant to
  that same marker. Ordinary bookkeeping markers never authorize provider I/O.

  Observation methods retain bounded facts from the original trusted internal
  actor and lease, even after that lease expires or is replaced. Unknown and a
  late response may coexist; neither publishes availability or retries a send.
  """
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Camera.ArchiveAuthorities
  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.ArchiveUploadDispatch
  alias ServiceRadar.Camera.ArchiveUploadIntent
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingControl
  alias ServiceRadar.Camera.RecordingDescriptor
  alias ServiceRadar.Repo

  require Ash.Query

  @operations [:put_object, :create_multipart_upload]
  @response_bounds %{
    "etag" => 256,
    "version_id" => 1024,
    "upload_id" => 1024,
    "request_id" => 256
  }

  def prepare(lease, role, opts \\ []) do
    cond do
      Repo.in_transaction?() -> {:error, :ambient_transaction}
      role not in [:init, :media] -> {:error, :invalid_object_role}
      true -> RecordingBlocks.with_current_upload(lease, &prepare_locked(&1, role, opts), opts)
    end
  end

  @media_fields %{
    init_authority_revision: :media_authority_revision,
    init_authority_sha256: :media_authority_sha256,
    init_storage_boot_id: :media_storage_boot_id,
    init_nonce_sha256: :media_nonce_sha256,
    init_principal_sha256: :media_principal_sha256,
    init_deadline_at: :media_deadline_at,
    init_verification: :media_verification,
    init_verification_sha256: :media_verification_sha256,
    init_verified_at: :media_verified_at,
    init_verification_conflict_at: :media_verification_conflict_at,
    init_verification_conflict_sha256: :media_verification_conflict_sha256
  }

  defp field(:init, field), do: field
  defp field(:media, field), do: Map.fetch!(@media_fields, field)
  defp value(dispatch, kind, name), do: Map.get(dispatch, field(kind, name))
  defp attributes(:init, attrs), do: attrs

  defp attributes(:media, attrs),
    do: Map.new(attrs, fn {key, value} -> {Map.get(@media_fields, key, key), value} end)

  defp action(:init, :grant), do: :grant_init
  defp action(:media, :grant), do: :grant_media
  defp action(:init, :verify), do: :verify_init
  defp action(:media, :verify), do: :verify_media
  defp action(:init, :conflict), do: :conflict_init_verification
  defp action(:media, :conflict), do: :conflict_media_verification

  @doc "Prepares one attempt per object, retaining its original actor, lease and deadline."
  def prepare_dispatch(lease, role, operation, ttl_ms, opts \\ []) do
    with :ok <- outside_transaction(),
         {:ok, actor_id} <- dispatcher(opts),
         :ok <- valid_role(role),
         :ok <- valid_operation(operation),
         :ok <- valid_ttl(ttl_ms) do
      RecordingBlocks.with_current_upload(
        lease,
        fn block ->
          with {:ok, intent} <- prepare_locked(block, role, opts) do
            prepare_dispatch_locked(block, intent, actor_id, operation, ttl_ms, opts)
          end
        end,
        opts
      )
    end
  end

  @doc "Commits a single marker within the retained deadline; never sends a request."
  def mark_dispatch(lease, dispatch_id, opts \\ []) do
    with :ok <- outside_transaction(),
         {:ok, actor_id} <- dispatcher(opts),
         {:ok, retained} <- get_dispatch(dispatch_id, opts) do
      RecordingControl.with_admission(
        fn ->
          RecordingBlocks.with_current_upload(
            lease,
            fn block ->
              with {:ok, dispatch, _intent} <-
                     current_dispatch(block, lease, dispatch_id, actor_id, opts) do
                mark_locked(dispatch, opts)
              end
            end,
            retained.deadline_at,
            opts
          )
        end,
        opts
      )
    end
  end

  @doc "Commits the existing first marker with current operation authority; only this fresh result grants I/O."
  def authorize(kind, lease, dispatch_id, principal, context, opts \\ []) do
    result =
      with :ok <- outside_transaction(),
           {:ok, actor_id} <- dispatcher(opts),
           {:ok, retained} <- get_dispatch(dispatch_id, opts),
           {:ok, intent} <- matching_origin(retained, lease, actor_id, opts) do
        RecordingControl.with_admission(
          fn ->
            ArchiveAuthorities.with_current(
              kind,
              intent.archive_binding_id,
              principal,
              context,
              fn authority ->
                deadline =
                  earliest([
                    retained.deadline_at,
                    authority.expires_at,
                    DateTime.add(
                      authority.database_now,
                      authority.desired_document["limits"]["max_operation_ms"],
                      :millisecond
                    )
                  ])

                RecordingBlocks.with_current_upload(
                  lease,
                  fn block ->
                    with {:ok, dispatch, frozen} <-
                           current_dispatch(block, lease, dispatch_id, actor_id, opts),
                         :ok <- operation_context(kind, dispatch, frozen, block, authority),
                         true <-
                           is_nil(dispatch.marked_at) || {:error, :init_dispatch_already_marked} do
                      grant(
                        kind,
                        dispatch,
                        frozen,
                        block,
                        authority,
                        context,
                        earliest([deadline, block.upload_expires_at]),
                        opts
                      )
                    end
                  end,
                  deadline,
                  opts
                )
              end,
              opts
            )
          end,
          opts
        )
      end

    bounded_result(kind, result)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      bounded_result(kind, {:error, :init_authority_storage_unavailable})
  end

  @doc "Retains exact operation verification under the original grant, including after revocation or expiry."
  def observe_verification(kind, lease, dispatch_id, principal, context, verification, opts \\ []) do
    result =
      with {:ok, fingerprint} <- ArchiveAuthorities.principal_sha256(kind, principal) do
        observe(lease, dispatch_id, opts, fn dispatch ->
          with :ok <- verification_origin(kind, dispatch, fingerprint, context),
               {:ok, intent} <-
                 Ash.get(ArchiveUploadIntent, dispatch.archive_upload_intent_id, opts),
               :ok <- valid_verification(kind, verification, intent) do
            retain_verification(kind, dispatch, verification, opts)
          end
        end)
      end

    bounded_result(kind, result)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      bounded_result(kind, {:error, :init_authority_storage_unavailable})
  end

  @media_errors %{
    init_authority_context_mismatch: :media_authority_context_mismatch,
    init_authority_storage_unavailable: :media_authority_storage_unavailable,
    init_dispatch_already_marked: :media_dispatch_already_marked,
    init_verification_origin_mismatch: :media_verification_origin_mismatch,
    invalid_init_verification: :invalid_media_verification,
    init_verification_conflict: :media_verification_conflict
  }

  defp bounded_result(:media, {:error, reason}) when is_atom(reason),
    do: {:error, Map.get(@media_errors, reason, reason)}

  defp bounded_result(_kind, {:ok, _} = result), do: result
  defp bounded_result(_kind, {:error, reason} = result) when is_atom(reason), do: result

  defp bounded_result(kind, _),
    do: bounded_result(kind, {:error, :init_authority_storage_unavailable})

  defp current_dispatch(block, lease, id, actor_id, opts) do
    with {:ok, dispatch} <- lock_dispatch(id, opts),
         {:ok, intent} <- matching_origin(dispatch, lease, actor_id, opts),
         {:ok, derived} <- prepare_locked(block, intent.object_role, opts),
         true <- derived.id == intent.id || {:error, :archive_upload_dispatch_conflict},
         :ok <- matching_request(dispatch, derived) do
      {:ok, dispatch, derived}
    end
  end

  defp operation_context(kind, dispatch, intent, block, authority) do
    if dispatch.operation == :put_object and intent.object_role == kind and
         block.storage_id == authority.desired_document["local_storage_id"] and
         intent.byte_length <=
           ArchiveAuthorityConfig.byte_limit(kind, authority.desired_document["limits"]),
       do: :ok,
       else: {:error, :init_authority_context_mismatch}
  end

  defp grant(kind, dispatch, intent, block, authority, context, deadline, opts) do
    attrs = %{
      marked_at: dispatch.database_now,
      init_authority_revision: authority.revision,
      init_authority_sha256: authority.desired_sha256,
      init_storage_boot_id: context.storage_boot_id,
      init_nonce_sha256: digest(context.nonce),
      init_principal_sha256: authority.principal_sha256,
      init_deadline_at: deadline
    }

    case ArchiveAuthorities.operation_budget(deadline, dispatch.database_now) do
      {:ok, remaining_ms} ->
        with {:ok, _} <- update(dispatch, action(kind, :grant), attributes(kind, attrs), opts) do
          {:ok,
           %{
             "schema_version" => 1,
             "status" => "granted",
             "dispatch_id" => dispatch.id,
             "binding_id" => authority.archive_binding_id,
             "revision" => Integer.to_string(authority.revision),
             "desired_sha256" => authority.desired_sha256,
             "storage_boot_id" => context.storage_boot_id,
             "nonce" => context.nonce,
             "remaining_ms" => remaining_ms,
             "request_sha256" => dispatch.request_sha256,
             "object_key" => intent.object_key,
             "byte_length" => intent.byte_length,
             "object_sha256" => intent.object_sha256,
             "descriptor_sha256" => intent.descriptor_sha256,
             "local_storage_id" => block.storage_id
           }}
        end

      :expired ->
        {:error, :upload_dispatch_expired}
    end
  end

  defp earliest(times), do: Enum.min_by(times, &DateTime.to_unix(&1, :microsecond))

  defp verification_origin(
         kind,
         dispatch,
         fingerprint,
         %{storage_boot_id: boot, desired_sha256: sha, nonce: nonce} = context
       )
       when map_size(context) == 3 and is_binary(nonce) do
    if value(dispatch, kind, :init_principal_sha256) == fingerprint and
         value(dispatch, kind, :init_storage_boot_id) == boot and
         value(dispatch, kind, :init_authority_sha256) == sha and
         value(dispatch, kind, :init_nonce_sha256) == digest(nonce),
       do: :ok,
       else: {:error, :init_verification_origin_mismatch}
  end

  defp verification_origin(_, _, _, _), do: {:error, :init_verification_origin_mismatch}

  defp valid_verification(
         kind,
         %{
           "schema_version" => 1,
           "put_request_sha256" => wire_sha,
           "etag" => etag,
           "version_id" => version,
           "byte_length" => length,
           "object_sha256" => sha,
           "encryption" => "AES256"
         } = value,
         intent
       )
       when map_size(value) == 7 do
    valid =
      is_binary(wire_sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, wire_sha) and
        is_binary(etag) and byte_size(etag) in 3..256 and Regex.match?(~r/\A"[!#-~]+"\z/, etag) and
        (is_nil(version) or bounded_text?(version, 1024)) and is_integer(length) and
        length in 1..if(kind == :init, do: 1_048_576, else: 16_777_216) and
        length == intent.byte_length and
        sha == intent.object_sha256

    if valid, do: :ok, else: {:error, :invalid_init_verification}
  end

  defp valid_verification(_, _, _), do: {:error, :invalid_init_verification}

  defp retain_verification(kind, dispatch, verification, opts) do
    sha = verification |> ArchiveCanonicalJSON.encode() |> digest()

    cond do
      value(dispatch, kind, :init_verification_conflict_at) ->
        {:error, :init_verification_conflict}

      is_nil(value(dispatch, kind, :init_verified_at)) ->
        update(
          dispatch,
          action(kind, :verify),
          attributes(kind, %{
            init_verification: verification,
            init_verification_sha256: sha,
            init_verified_at: dispatch.database_now
          }),
          opts
        )

      value(dispatch, kind, :init_verification) == verification and
          value(dispatch, kind, :init_verification_sha256) == sha ->
        {:ok, dispatch}

      true ->
        with {:ok, _} <-
               update(
                 dispatch,
                 action(kind, :conflict),
                 attributes(kind, %{
                   init_verification_conflict_at: dispatch.database_now,
                   init_verification_conflict_sha256: sha
                 }),
                 opts
               ),
             do: {:ok, :init_verification_conflict_committed}
    end
  end

  @doc "Retains lost/unknown transport outcome without discarding a late receipt."
  def observe_unknown(lease, dispatch_id, opts \\ []) do
    observe(lease, dispatch_id, opts, fn dispatch ->
      if dispatch.unknown_at,
        do: {:ok, dispatch},
        else: update(dispatch, :observe_unknown, %{unknown_at: dispatch.database_now}, opts)
    end)
  end

  @doc "Retains one bounded response and permanently records conflicting evidence."
  def observe_response(lease, dispatch_id, response, opts \\ []) do
    observe(lease, dispatch_id, opts, fn dispatch ->
      with :ok <- valid_response(response, dispatch.operation) do
        retain_response(dispatch, response, opts)
      end
    end)
  end

  defp prepare_dispatch_locked(block, intent, actor_id, operation, ttl_ms, opts) do
    identity = %{
      archive_upload_intent_id: intent.id,
      upload_epoch: block.upload_epoch,
      upload_token_sha256: digest(block.upload_token),
      dispatcher_actor_id: actor_id,
      operation: operation,
      request_sha256: request_digest(intent, operation)
    }

    case ArchiveUploadDispatch
         |> Ash.Query.filter(archive_upload_intent_id == ^intent.id)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one(opts) do
      {:ok, nil} ->
        deadline = DateTime.add(block.database_now, ttl_ms, :millisecond)

        deadline =
          if DateTime.before?(deadline, block.upload_expires_at),
            do: deadline,
            else: block.upload_expires_at

        ArchiveUploadDispatch
        |> Ash.Changeset.for_create(
          :prepare,
          Map.merge(identity, %{
            prepared_at: block.database_now,
            deadline_at: deadline
          })
        )
        |> Ash.create(opts)

      {:ok, retained} ->
        if Map.take(retained, Map.keys(identity)) == identity,
          do: {:ok, retained},
          else: {:error, :archive_upload_dispatch_conflict}

      {:error, _} = error ->
        error
    end
  end

  defp mark_locked(%{marked_at: nil} = dispatch, opts) do
    with {:ok, marked} <- update(dispatch, :mark, %{marked_at: dispatch.database_now}, opts),
         do: {:ok, {:marked, marked}}
  end

  defp mark_locked(dispatch, _opts), do: {:ok, {:already_marked, dispatch}}

  defp observe(lease, dispatch_id, opts, fun) do
    with :ok <- outside_transaction(),
         {:ok, actor_id} <- dispatcher(opts) do
      observation_transaction(fn ->
        with {:ok, dispatch} <- lock_dispatch(dispatch_id, opts),
             {:ok, _intent} <- matching_origin(dispatch, lease, actor_id, opts),
             true <- not is_nil(dispatch.marked_at) || {:error, :upload_dispatch_unmarked} do
          fun.(dispatch)
        end
      end)
    end
  end

  defp matching_origin(
         dispatch,
         %{upload_token: token, upload_epoch: epoch, id: block_id, descriptor_sha256: sha},
         actor_id,
         opts
       )
       when is_binary(token) do
    with {:ok, intent} <- Ash.get(ArchiveUploadIntent, dispatch.archive_upload_intent_id, opts) do
      if dispatch.dispatcher_actor_id == actor_id and
           dispatch.upload_epoch == epoch and
           dispatch.upload_token_sha256 == digest(token) and
           intent.recording_block_id == block_id and
           intent.descriptor_sha256 == sha,
         do: {:ok, intent},
         else: {:error, :archive_upload_dispatch_conflict}
    end
  end

  defp matching_origin(_, _, _, _), do: {:error, :archive_upload_dispatch_conflict}

  defp matching_request(dispatch, intent) do
    if dispatch.request_sha256 == request_digest(intent, dispatch.operation),
      do: :ok,
      else: {:error, :archive_upload_dispatch_conflict}
  end

  # Ordered values give this logical request a stable identity. These are not
  # signed HTTP bytes; a provider adapter must verify its own wire contract.
  defp request_digest(intent, operation) do
    digest(
      Jason.encode!([
        1,
        operation,
        intent.id,
        intent.recording_block_id,
        intent.archive_binding_id,
        intent.descriptor_sha256,
        intent.destination_sha256,
        intent.object_role,
        intent.object_key,
        intent.byte_length,
        intent.object_sha256
      ])
    )
  end

  defp retain_response(dispatch, response, opts) do
    sha =
      response |> Enum.sort() |> Enum.map(fn {k, v} -> [k, v] end) |> Jason.encode!() |> digest()

    cond do
      dispatch.conflict_at ->
        {:error, :archive_upload_response_conflict}

      is_nil(dispatch.response_at) ->
        update(
          dispatch,
          :observe_response,
          %{
            response: response,
            response_sha256: sha,
            response_at: dispatch.database_now
          },
          opts
        )

      dispatch.response == response and dispatch.response_sha256 == sha ->
        {:ok, dispatch}

      true ->
        with {:ok, _} <-
               update(
                 dispatch,
                 :record_conflict,
                 %{
                   conflict_at: dispatch.database_now,
                   first_conflict_sha256: sha
                 },
                 opts
               ),
             do: {:ok, :response_conflict_committed}
    end
  end

  defp valid_response(%{"status" => status} = response, operation)
       when is_integer(status) and status in 200..599 do
    fields_valid =
      Enum.all?(response, fn
        {"status", _} ->
          true

        {key, value} ->
          case Map.fetch(@response_bounds, key) do
            {:ok, bound} -> bounded_text?(value, bound)
            :error -> false
          end
      end)

    operation_valid =
      case operation do
        :put_object -> not Map.has_key?(response, "upload_id")
        :create_multipart_upload -> status not in 200..299 or Map.has_key?(response, "upload_id")
      end

    if fields_valid and operation_valid and byte_size(Jason.encode!(response)) <= 4096,
      do: :ok,
      else: {:error, :invalid_upload_response}
  end

  defp valid_response(_, _), do: {:error, :invalid_upload_response}

  defp get_dispatch(id, opts) do
    case Ash.get(ArchiveUploadDispatch, id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, nil} -> {:error, :upload_dispatch_not_found}
      result -> result
    end
  end

  defp lock_dispatch(id, opts) do
    case ArchiveUploadDispatch
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one(opts) do
      {:ok, nil} -> {:error, :upload_dispatch_not_found}
      {:ok, dispatch} -> Ash.load(dispatch, :database_now, opts)
      error -> error
    end
  end

  defp update(dispatch, action, attrs, opts) do
    dispatch |> Ash.Changeset.for_update(action, attrs) |> Ash.update(opts)
  end

  defp outside_transaction do
    if Repo.in_transaction?(), do: {:error, :ambient_transaction}, else: :ok
  end

  defp dispatcher(opts) do
    case Keyword.get(opts, :actor) do
      %{role: :system, id: id} ->
        if bounded_text?(id, 128) and String.trim(id) == id,
          do: {:ok, id},
          else: {:error, :invalid_dispatcher}

      _ ->
        {:error, :invalid_dispatcher}
    end
  end

  defp bounded_text?(text, max) when is_binary(text) do
    byte_size(text) in 1..max and String.valid?(text) and
      not String.contains?(text, [<<0>>, "\r", "\n"])
  end

  defp bounded_text?(_, _), do: false
  defp valid_role(role) when role in [:init, :media], do: :ok
  defp valid_role(_), do: {:error, :invalid_object_role}
  defp valid_operation(operation) when operation in @operations, do: :ok
  defp valid_operation(_), do: {:error, :invalid_upload_operation}
  defp valid_ttl(ms) when is_integer(ms) and ms in 1..300_000, do: :ok
  defp valid_ttl(_), do: {:error, :invalid_ttl}
  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp observation_transaction(fun) do
    [ArchiveUploadDispatch]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :archive_dispatch,
             value: reason,
             message: "dispatch observation refused"
           )}

        result ->
          result
      end
    end)
    |> case do
      {:ok, {:ok, :init_verification_conflict_committed}} ->
        {:error, :init_verification_conflict}

      {:ok, {:ok, :response_conflict_committed}} ->
        {:error, :archive_upload_response_conflict}

      {:ok, result} ->
        result

      {:error, %InvalidArgument{field: :archive_dispatch, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{errors: [%InvalidArgument{field: :archive_dispatch, value: reason}]}} ->
        {:error, reason}

      error ->
        error
    end
  end

  defp prepare_locked(%{archive_binding_id: nil}, _role, _opts),
    do: {:error, :archive_binding_required}

  defp prepare_locked(block, role, opts) do
    with {:ok, %ArchiveBinding{} = binding} <-
           Ash.get(ArchiveBinding, block.archive_binding_id, opts) do
      object = Map.fetch!(block.descriptor, Atom.to_string(role))

      attributes = %{
        recording_block_id: block.id,
        archive_binding_id: binding.id,
        descriptor_sha256: block.descriptor_sha256,
        destination_sha256: binding.destination_sha256,
        object_role: role,
        object_key: RecordingDescriptor.object_key(block.descriptor["identity"], role),
        byte_length: object["length"],
        object_sha256: object["sha256"]
      }

      case ArchiveUploadIntent
           |> Ash.Query.filter(recording_block_id == ^block.id and object_role == ^role)
           |> Ash.read_one(opts) do
        {:ok, nil} ->
          ArchiveUploadIntent
          |> Ash.Changeset.for_create(:prepare, attributes)
          |> Ash.create(opts)

        {:ok, retained} ->
          if Map.take(retained, Map.keys(attributes)) == attributes,
            do: {:ok, retained},
            else: {:error, :archive_upload_intent_conflict}

        {:error, _} = error ->
          error
      end
    end
  end
end
