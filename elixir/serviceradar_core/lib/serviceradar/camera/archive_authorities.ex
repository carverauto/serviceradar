defmodule ServiceRadar.Camera.ArchiveAuthorities do
  @moduledoc """
  Installs one origin-bound, nonrenewable thirty-second operation authority window.

  Transport authentication supplies the principal; no payload supplies it.
  Binding locks serialize first issuance. Grant admission instead locks recording
  control, authority, block and dispatch, without acquiring a binding lock.
  Installation/revocation never acquires block or recording-control locks.
  The callbacks below are short database work; no network or credential I/O.
  """

  import Kernel, except: [apply: 3]

  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.ArchiveInitAuthority
  alias ServiceRadar.Camera.ArchiveMediaAuthority
  alias ServiceRadar.Repo

  require Ash.Query

  @maximum 9_223_372_036_854_775_807

  def challenge(kind, principal, document, opts \\ []),
    do: for_operation(kind, opts, &do_challenge(principal, document, &1))

  def apply(kind, installation, envelope, opts \\ []),
    do: for_operation(kind, opts, &do_apply(installation, envelope, &1))

  def revoke(kind, installation, document, opts \\ []),
    do: for_operation(kind, opts, &do_revoke(installation, document, &1))

  def status(kind, installation, id, opts \\ []),
    do: for_operation(kind, opts, &do_status(installation, id, &1))

  def with_current(kind, id, principal, context, fun, opts),
    do: for_operation(kind, opts, &do_with_current(id, principal, context, fun, &1))

  @media_errors %{
    init_authority: :media_authority,
    init_authority_challenge_mismatch: :media_authority_challenge_mismatch,
    init_authority_context_mismatch: :media_authority_context_mismatch,
    init_authority_expired: :media_authority_expired,
    init_authority_generation_stale: :media_authority_generation_stale,
    init_authority_not_applied: :media_authority_not_applied,
    init_authority_not_found: :media_authority_not_found,
    init_authority_origin_mismatch: :media_authority_origin_mismatch,
    init_authority_report_unqualified: :media_authority_report_unqualified,
    init_authority_revision_conflict: :media_authority_revision_conflict,
    init_authority_revision_stale: :media_authority_revision_stale,
    init_authority_storage_unavailable: :media_authority_storage_unavailable,
    init_authority_transaction_required: :media_authority_transaction_required,
    invalid_init_application: :invalid_media_application,
    invalid_init_challenge: :invalid_media_challenge,
    invalid_init_grant: :invalid_media_grant,
    invalid_init_principal: :invalid_media_principal,
    invalid_init_revocation: :invalid_media_revocation
  }

  defp for_operation(kind, opts, fun) when kind in [:init, :media] do
    resource = if kind == :init, do: ArchiveInitAuthority, else: ArchiveMediaAuthority

    case fun.(%{kind: kind, resource: resource, ash: opts}) do
      {:error, reason} when kind == :media and is_atom(reason) ->
        {:error, Map.get(@media_errors, reason, reason)}

      result ->
        result
    end
  end

  defp do_challenge(principal, document, opts) do
    with :ok <- actor(opts),
         {:ok, fingerprint} <- principal_sha256(opts.kind, principal),
         {:ok, input} <- challenge_input(document),
         :ok <- outside_transaction() do
      transaction(opts, fn ->
        with {:ok, binding} <- binding(input.binding_id, opts, true),
             {:ok, current} <- current(input.binding_id, opts, true),
             :ok <- origin(current, principal),
             {:ok, result} <- issue(current, binding, principal, fingerprint, input, opts) do
          projected(result, opts)
        end
      end)
    end
  end

  defp do_apply(installation, envelope, opts) do
    with :ok <- actor(opts),
         :ok <- installation(installation),
         {:ok, config, nonce} <- application(installation, envelope, opts),
         :ok <- outside_transaction() do
      transaction(opts, fn ->
        with {:ok, binding} <- binding(config.binding_id, opts, true),
             {:ok, current} <- required_current(config.binding_id, opts),
             :ok <- origin(current, installation),
             true <-
               current.generation == installation.generation ||
                 {:error, :init_authority_context_mismatch},
             :ok <- exact_revision(current, config.revision),
             :ok <- application_context(current, binding, config, nonce),
             :ok <- live(current),
             {:ok, result} <- install(current, config, opts) do
          projected(result, opts)
        end
      end)
    end
  end

  defp do_revoke(installation, document, opts) do
    with :ok <- actor(opts),
         :ok <- installation(installation),
         {:ok, id, revision} <- revocation(document),
         :ok <- outside_transaction() do
      transaction(opts, fn ->
        with {:ok, _} <- binding(id, opts, true),
             {:ok, current} <- current(id, opts, true),
             :ok <- origin(current, installation) do
          attrs =
            Map.merge(Map.take(installation, [:deployment_ref, :generation]), %{
              revision: revision,
              desired_sha256:
                digest([
                  "#{opts.kind}-authority-revoke-v1",
                  installation.deployment_ref,
                  Integer.to_string(installation.generation),
                  document
                ])
            })

          cond do
            current && revision < current.revision ->
              {:error, :init_authority_revision_stale}

            current && revision == current.revision && current.state == :revoked &&
                current.desired_sha256 == attrs.desired_sha256 ->
              projected(current, opts)

            current && revision == current.revision ->
              {:error, :init_authority_revision_conflict}

            true ->
              with {:ok, result} <- persist(current, id, :revoke, attrs, opts),
                   do: projected(result, opts)
          end
        end
      end)
    end
  end

  defp do_status(installation, id, opts) do
    with :ok <- actor(opts),
         :ok <- installation(installation),
         true <- uuid?(id) || {:error, :invalid_archive_binding_id},
         {:ok, _} <- binding(id, opts, false),
         {:ok, current} <- current(id, opts, false),
         :ok <- origin(current, installation) do
      if current, do: {:ok, projection(current, opts)}, else: {:ok, absent(id, opts)}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :init_authority_storage_unavailable}
  end

  defp do_with_current(id, principal, context, fun, opts) when is_function(fun, 1) do
    with :ok <- actor(opts),
         true <- Repo.in_transaction?() || {:error, :init_authority_transaction_required},
         {:ok, fingerprint} <- principal_sha256(opts.kind, principal),
         :ok <- grant_context(context),
         {:ok, authority} <- required_current(id, opts),
         :ok <- origin(authority, principal),
         true <- authority.state == :applied || {:error, :init_authority_not_applied},
         true <-
           (authority.principal_sha256 == fingerprint and
              authority.storage_boot_id == context.storage_boot_id and
              authority.desired_sha256 == context.desired_sha256 and
              authority.nonce != context.nonce) || {:error, :init_authority_context_mismatch},
         :ok <- live(authority) do
      fun.(authority)
    end
  end

  @doc "Whole milliseconds remaining before a deadline. Zero or less admits no write."
  def operation_budget(%DateTime{} = deadline, %DateTime{} = now) do
    case DateTime.diff(deadline, now, :millisecond) do
      remaining when remaining >= 1 -> {:ok, remaining}
      _ -> :expired
    end
  end

  @doc "Identity fingerprint used by retained grants, including their late evidence."
  def principal_sha256(kind, principal) do
    with :ok <- installation(principal),
         %{
           storage_service_id: service,
           credential_reference: reference,
           credential_generation: generation
         } <- principal,
         true <-
           reference?(service) and reference?(reference) and
             is_integer(generation) and generation in 1..@maximum do
      {:ok,
       digest([
         "#{kind}-storage-principal-v1",
         principal.deployment_ref,
         Integer.to_string(principal.generation),
         service,
         reference,
         Integer.to_string(generation)
       ])}
    else
      _ -> {:error, :invalid_init_principal}
    end
  end

  defp issue(current, binding, principal, fingerprint, input, opts) do
    identity = %{
      deployment_ref: principal.deployment_ref,
      generation: principal.generation,
      revision: input.revision,
      desired_sha256: input.desired_sha256,
      storage_service_id: principal.storage_service_id,
      credential_reference: principal.credential_reference,
      credential_generation: principal.credential_generation,
      principal_sha256: fingerprint,
      storage_boot_id: input.storage_boot_id,
      nonce: input.nonce
    }

    cond do
      current && input.revision < current.revision ->
        {:error, :init_authority_revision_stale}

      current && input.revision == current.revision &&
          Map.take(current, Map.keys(identity)) != identity ->
        {:error, :init_authority_revision_conflict}

      current && input.revision == current.revision && current.state == :revoked ->
        {:error, :init_authority_revision_conflict}

      current && input.revision == current.revision ->
        with :ok <- live(current), do: {:ok, current}

      true ->
        persist(
          current,
          binding.id,
          :challenge,
          Map.merge(identity, %{
            issued_at: binding.database_now,
            expires_at: DateTime.add(binding.database_now, 30_000, :millisecond)
          }),
          opts
        )
    end
  end

  defp application_context(current, binding, config, nonce) do
    credential = config.report["credential"]
    now_ms = DateTime.to_unix(current.database_now, :millisecond)

    cond do
      current.state not in [:pending, :applied] ->
        {:error, :init_authority_not_applied}

      current.nonce != nonce ->
        {:error, :init_authority_challenge_mismatch}

      current.desired_sha256 != config.desired_sha256 or
        binding.destination_sha256 != config.destination_sha256 or
        current.storage_service_id != credential["storage_service_id"] or
        current.credential_reference != credential["reference"] or
          current.credential_generation != credential["generation"] ->
        {:error, :init_authority_context_mismatch}

      config.report["issued_at_ms"] > now_ms or config.report["expires_at_ms"] <= now_ms ->
        {:error, :init_authority_expired}

      not Enum.all?(config.report["checks"], fn {_, status} -> status == "passed" end) ->
        {:error, :init_authority_report_unqualified}

      true ->
        :ok
    end
  end

  defp install(%{state: :applied} = current, _config, _opts), do: {:ok, current}

  defp install(current, config, opts) do
    expires_at =
      [DateTime.to_unix(current.expires_at, :millisecond), config.report["expires_at_ms"]]
      |> Enum.min()
      |> DateTime.from_unix!(:millisecond)

    case operation_budget(expires_at, current.database_now) do
      {:ok, _remaining} ->
        current
        |> Ash.Changeset.for_update(:apply, %{
          desired_document: config.document,
          report_sha256: config.report_sha256,
          applied_at: current.database_now,
          expires_at: expires_at
        })
        |> Ash.update(opts.ash)

      :expired ->
        {:error, :init_authority_expired}
    end
  end

  defp persist(nil, id, action, attrs, opts) do
    action = if action == :challenge, do: :initial_challenge, else: :initial_revoke

    opts.resource
    |> Ash.Changeset.for_create(action, Map.put(attrs, :archive_binding_id, id))
    |> Ash.create(opts.ash)
  end

  defp persist(current, _id, action, attrs, opts),
    do: current |> Ash.Changeset.for_update(action, attrs) |> Ash.update(opts.ash)

  defp projected(authority, opts) do
    with {:ok, current} <- Ash.load(authority, :database_now, opts.ash),
         :ok <- if(current.state == :revoked, do: :ok, else: live(current)) do
      {:ok, projection(current, opts)}
    end
  end

  defp projection(current, opts) do
    Map.merge(absent(current.archive_binding_id, opts), %{
      "revision" => Integer.to_string(current.revision),
      "desired_sha256" => current.desired_sha256,
      "state" => Atom.to_string(current.state),
      "storage_boot_id" => current.storage_boot_id,
      "nonce" => current.nonce,
      "issued_at_ms" => milliseconds(current.issued_at),
      "expires_at_ms" => milliseconds(current.expires_at),
      "remaining_ms" =>
        if(current.expires_at,
          do: max(0, DateTime.diff(current.expires_at, current.database_now, :millisecond)),
          else: 0
        ),
      "applied_revision" => if(current.state == :applied, do: Integer.to_string(current.revision))
    })
  end

  defp absent(id, opts),
    do: %{
      "schema_version" => 1,
      "binding_id" => id,
      "revision" => nil,
      "desired_sha256" => nil,
      "state" => "not_configured",
      "storage_boot_id" => nil,
      "nonce" => nil,
      "issued_at_ms" => nil,
      "expires_at_ms" => nil,
      "remaining_ms" => 0,
      "applied_revision" => nil,
      "recording_readiness" => "unavailable",
      "archive_readiness" => "unavailable",
      "reason" => "#{opts.kind}_authority_only"
    }

  defp milliseconds(nil), do: nil
  defp milliseconds(time), do: time |> DateTime.to_unix(:millisecond) |> Integer.to_string()

  defp binding(id, opts, lock?) do
    query = Ash.Query.filter(ArchiveBinding, id == ^id)
    query = if lock?, do: Ash.Query.lock(query, :for_update), else: query

    case Ash.read_one(query, opts.ash) do
      {:ok, nil} -> {:error, :archive_binding_not_found}
      {:ok, value} -> value |> Ash.load(:database_now, opts.ash) |> bounded()
      result -> bounded(result)
    end
  end

  defp current(id, opts, lock?) do
    query = Ash.Query.filter(opts.resource, archive_binding_id == ^id)
    query = if lock?, do: Ash.Query.lock(query, :for_update), else: query

    with {:ok, value} <- query |> Ash.read_one(opts.ash) |> bounded() do
      if value, do: value |> Ash.load(:database_now, opts.ash) |> bounded(), else: {:ok, nil}
    end
  end

  defp required_current(id, opts) do
    case current(id, opts, true) do
      {:ok, nil} -> {:error, :init_authority_not_found}
      other -> other
    end
  end

  defp origin(nil, _), do: :ok

  defp origin(current, installation) do
    cond do
      current.deployment_ref != installation.deployment_ref ->
        {:error, :init_authority_origin_mismatch}

      installation.generation < current.generation ->
        {:error, :init_authority_generation_stale}

      true ->
        :ok
    end
  end

  defp exact_revision(current, revision) do
    cond do
      revision < current.revision -> {:error, :init_authority_revision_stale}
      revision != current.revision -> {:error, :init_authority_revision_conflict}
      true -> :ok
    end
  end

  defp live(%{issued_at: issued, expires_at: %DateTime{} = expiry, database_now: now}) do
    if not DateTime.before?(now, issued) and DateTime.after?(expiry, now),
      do: :ok,
      else: {:error, :init_authority_expired}
  end

  defp live(_), do: {:error, :init_authority_expired}

  defp challenge_input(
         %{
           "schema_version" => 1,
           "revision" => revision,
           "binding_id" => id,
           "desired_sha256" => sha,
           "storage_boot_id" => boot,
           "nonce" => nonce
         } = document
       )
       when map_size(document) == 6 do
    with {:ok, number} <- revision(revision),
         true <- uuid?(id) and uuid?(boot) and sha?(sha) and sha?(nonce) do
      {:ok,
       %{
         binding_id: id,
         revision: number,
         desired_sha256: sha,
         storage_boot_id: boot,
         nonce: nonce
       }}
    else
      _ -> {:error, :invalid_init_challenge}
    end
  end

  defp challenge_input(_), do: {:error, :invalid_init_challenge}

  defp application(
         installation,
         %{"schema_version" => 1, "desired" => document, "nonce" => nonce} = envelope,
         opts
       )
       when map_size(envelope) == 3 do
    with true <- sha?(nonce),
         {:ok, config} <- ArchiveAuthorityConfig.parse(opts.kind, installation, document),
         do: {:ok, config, nonce},
         else: (_ -> {:error, :invalid_init_application})
  end

  defp application(_, _, _), do: {:error, :invalid_init_application}

  defp revocation(%{"schema_version" => 1, "binding_id" => id, "revision" => revision} = document)
       when map_size(document) == 3 do
    with true <- uuid?(id),
         {:ok, number} <- revision(revision),
         do: {:ok, id, number},
         else: (_ -> {:error, :invalid_init_revocation})
  end

  defp revocation(_), do: {:error, :invalid_init_revocation}

  defp grant_context(%{storage_boot_id: boot, desired_sha256: sha, nonce: nonce} = context)
       when map_size(context) == 3 do
    if uuid?(boot) and sha?(sha) and sha?(nonce), do: :ok, else: {:error, :invalid_init_grant}
  end

  defp grant_context(_), do: {:error, :invalid_init_grant}

  defp installation(%{deployment_ref: id, generation: generation})
       when is_integer(generation) and generation in 1..@maximum do
    if uuid?(id), do: :ok, else: {:error, :invalid_init_principal}
  end

  defp installation(_), do: {:error, :invalid_init_principal}

  defp actor(opts) do
    case Keyword.get(opts.ash, :actor) do
      %{role: :system, id: id} when is_binary(id) and byte_size(id) in 1..128 ->
        if reference?(id), do: :ok, else: {:error, :invalid_init_principal}

      _ ->
        {:error, :invalid_init_principal}
    end
  end

  defp revision(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {n, ""} when n in 1..@maximum ->
        if Integer.to_string(n) == value, do: {:ok, n}, else: :error

      _ ->
        :error
    end
  end

  defp revision(_), do: :error

  defp uuid?(v) when is_binary(v),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, v)

  defp uuid?(_), do: false
  defp sha?(v) when is_binary(v), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
  defp sha?(_), do: false

  defp reference?(v) when is_binary(v) and byte_size(v) in 1..256,
    do: Regex.match?(~r/\A[!-~]+\z/, v)

  defp reference?(_), do: false

  defp digest(value),
    do: :sha256 |> :crypto.hash(ArchiveCanonicalJSON.encode(value)) |> Base.encode16(case: :lower)

  defp outside_transaction,
    do: if(Repo.in_transaction?(), do: {:error, :ambient_transaction}, else: :ok)

  defp transaction(opts, fun) do
    [ArchiveBinding, opts.resource]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :init_authority,
             value: reason,
             message: "init authority refused"
           )}

        result ->
          result
      end
    end)
    |> transaction_result()
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :init_authority_storage_unavailable}
  end

  defp transaction_result({:ok, result}), do: bounded(result)

  defp transaction_result({:error, %Ash.Error.Invalid{errors: [error]}}),
    do: transaction_result({:error, error})

  defp transaction_result({:error, %InvalidArgument{field: :init_authority, value: reason}}),
    do: {:error, reason}

  defp transaction_result(_), do: {:error, :init_authority_storage_unavailable}
  defp bounded({:ok, _} = result), do: result
  defp bounded(_), do: {:error, :init_authority_storage_unavailable}
end
