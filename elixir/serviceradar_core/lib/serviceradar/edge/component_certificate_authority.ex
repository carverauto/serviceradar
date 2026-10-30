defmodule ServiceRadar.Edge.ComponentCertificateAuthority do
  @moduledoc """
  Durable authority for managed component certificates.

  Mutations serialize on the component row. Issuance records are immutable;
  re-enrollment advances the component generation, so old certificates cannot
  regain access. Recording a successor does not retire its predecessor.

  Snapshot expiry is a receiver authorization lease, not certificate expiry or
  spool retention. Receivers must refresh before `valid_until` and close affected
  sessions when policy changes or that lease expires. PubSub is only a wake-up
  hint: the database snapshot remains authoritative after restarts and missed
  notifications. These APIs record desired policy, not enforcement completion.
  """
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ManagedCertificatePolicyKey
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.RevokedComponentCertificate

  require Ash.Query

  @topic "serviceradar:cert_revocations"
  @snapshot_seconds 30
  @component_fields [
    :component_id,
    :component_type,
    :partition_id,
    :host_agent_id,
    :server_hosts,
    :generation,
    :blocked
  ]
  @certificate_fields [
    :fingerprint,
    :issuer_fingerprint,
    :serial_number,
    :component_id,
    :generation,
    :role,
    :not_before,
    :not_after
  ]
  @revocation_fields [:component_id, :generation, :fingerprint, :revoked_at, :reason]

  def topic, do: @topic

  def enroll_component(attrs, opts \\ []) do
    ManagedComponent
    |> Ash.Changeset.for_create(:enroll, attrs, opts)
    |> Ash.create(opts)
    |> notify()
  end

  @doc "Records an issued certificate, with mandatory expected_generation and host_agent_id binding."
  def record_issuance(component_id, metadata, opts \\ []) do
    changeset =
      Ash.Changeset.for_create(
        ComponentCertificate,
        :record_issuance,
        Map.put(metadata, :component_id, component_id),
        opts
      )

    if changeset.valid? do
      fn ->
        with {:ok, component} <- lock_component(component_id, opts),
             false <- component.blocked,
             true <-
               component.generation == Ash.Changeset.get_argument(changeset, :expected_generation),
             true <-
               component.host_agent_id == Ash.Changeset.get_argument(changeset, :host_agent_id) do
          create_or_reuse_certificate(changeset, opts)
        else
          result when is_boolean(result) -> {:error, :issuance_binding_unavailable}
          error -> error
        end
      end
      |> transaction()
      |> notify()
    else
      Ash.create(changeset, opts)
    end
  end

  def revoke_component(component_id, reason, opts \\ []) do
    fn ->
      with {:ok, component} <- lock_component(component_id, opts),
           {:ok, _decision} <- record_revocation(component, nil, reason, opts) do
        component |> Ash.Changeset.for_update(:block, %{}, opts) |> Ash.update(opts)
      end
    end
    |> transaction()
    |> notify()
  end

  def revoke_certificate(fingerprint, reason, opts \\ []) do
    fn ->
      with {:ok, certificate} <- find_certificate(fingerprint, opts),
           {:ok, component} <- lock_component(certificate.component_id, opts) do
        record_revocation(
          %{component | generation: certificate.generation},
          fingerprint,
          reason,
          opts
        )
      end
    end
    |> transaction()
    |> notify()
  end

  def reenroll_component(component_id, opts \\ []) do
    fn ->
      with {:ok, component} <- lock_component(component_id, opts),
           {:ok, _decision} <-
             record_revocation(component, nil, "superseded_by_reenrollment", opts) do
        component |> Ash.Changeset.for_update(:reenroll, %{}, opts) |> Ash.update(opts)
      end
    end
    |> transaction()
    |> notify()
  end

  @doc "Returns current, bounded-lived authorization state for trusted enforcement replicas."
  def snapshot do
    opts = [actor: SystemActor.system(:component_certificate_authority)]
    now = DateTime.utc_now()

    transaction(fn ->
      with {:ok, components} <-
             ManagedComponent
             |> Ash.Query.sort(:component_id)
             |> Ash.Query.lock("FOR SHARE")
             |> Ash.read(opts),
           {:ok, certificates} <-
             ComponentCertificate
             |> Ash.Query.filter(not_after > ^now and generation == component.generation)
             |> Ash.Query.sort(:fingerprint)
             |> Ash.read(opts),
           fingerprints = Enum.map(certificates, & &1.fingerprint),
           {:ok, revocations} <-
             RevokedComponentCertificate
             |> Ash.Query.filter(
               generation == component.generation and
                 (is_nil(fingerprint) or fingerprint in ^fingerprints)
             )
             |> Ash.Query.sort([:component_id, :fingerprint])
             |> Ash.read(opts) do
        payload = %{
          version: 1,
          generated_at: now,
          valid_until: DateTime.shift(now, second: @snapshot_seconds),
          components: Enum.map(components, &Map.take(&1, @component_fields)),
          certificates: Enum.map(certificates, &Map.take(&1, @certificate_fields)),
          revocations: Enum.map(revocations, &Map.take(&1, @revocation_fields))
        }

        allowed =
          certificates
          |> Enum.filter(&(authorize(payload, &1.component_id, &1.fingerprint, now) == :ok))
          |> Enum.map(& &1.fingerprint)

        payload =
          payload
          |> Map.put(:allowed_fingerprints, allowed)
          |> Map.put(
            :nats_permissions,
            ServiceRadar.Edge.ManagedComponentNatsPermissions.snapshot(
              components,
              certificates,
              allowed
            )
          )

        digest =
          :sha256
          |> :crypto.hash(:erlang.term_to_binary(payload, [:deterministic]))
          |> Base.encode16(case: :lower)

        {:ok, Map.put(payload, :digest, digest)}
      end
    end)
  end

  @doc "Public deployment key to pin during an authorized component enrollment."
  def policy_public_key do
    with {:ok, key} <- ensure_policy_key(), do: {:ok, key.public_key}
  end

  @doc "Signs authenticated receiver policy, including service-specific NATS permissions."
  def sign_snapshot, do: sign_policy(true)

  @doc "Signs public transport policy without deployment-specific NATS subjects."
  def sign_public_snapshot, do: sign_policy(false)

  defp sign_policy(include_permissions?) do
    opts = [actor: SystemActor.system(:component_certificate_authority)]

    with {:ok, snapshot} <- snapshot(),
         {:ok, key} <- ensure_policy_key(),
         {:ok, key} <- Ash.load(key, :seed, opts),
         {:ok, <<_::256>> = seed} <- Base.decode64(key.seed),
         {:ok, <<_::256>> = public_key} <- Base.decode64(key.public_key),
         {^public_key, _private} <- :crypto.generate_key(:eddsa, :ed25519, seed),
         {:ok, payload} <-
           snapshot
           |> Map.take(
             [:version, :generated_at, :valid_until, :allowed_fingerprints] ++
               if(include_permissions?, do: [:nats_permissions], else: [])
           )
           |> Jason.encode() do
      signature =
        :crypto.sign(:eddsa, :none, ["serviceradar.certificate-policy.v1", <<0>>, payload], [
          seed,
          :ed25519
        ])

      {:ok, %{payload: Base.encode64(payload), signature: Base.encode64(signature)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_policy_signing_key}
    end
  end

  defp ensure_policy_key do
    opts = [actor: SystemActor.system(:component_certificate_authority)]

    case Ash.read_one(ManagedCertificatePolicyKey, opts) do
      {:ok, nil} ->
        seed = :crypto.strong_rand_bytes(32)
        {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
        attrs = %{public_key: Base.encode64(public_key), seed: Base.encode64(seed)}

        with {:ok, _} <-
               ManagedCertificatePolicyKey
               |> Ash.Changeset.for_create(:configure, attrs, opts)
               |> Ash.create(opts) do
          # Re-read the persisted winner after an insert-only concurrent bootstrap.
          Ash.read_one(ManagedCertificatePolicyKey, opts)
        end

      result ->
        result
    end
  end

  @doc "Evaluates a managed peer against a fresh authority snapshot after normal TLS verification."
  def authorize(snapshot, component_id, fingerprint, now \\ DateTime.utc_now())

  def authorize(
        %{
          version: 1,
          generated_at: %DateTime{} = generated,
          valid_until: %DateTime{} = until,
          components: components,
          certificates: certificates,
          revocations: revocations
        },
        component_id,
        fingerprint,
        %DateTime{} = now
      )
      when is_list(components) and is_list(certificates) and is_list(revocations) do
    with :ok <- fresh(generated, until, now),
         %{} = component <-
           Enum.find(components, &(&1.component_id == component_id)) ||
             {:error, :unknown_component},
         true <- not component.blocked || {:error, :component_revoked},
         %{} = certificate <-
           Enum.find(
             certificates,
             &(&1.fingerprint == fingerprint and &1.component_id == component_id)
           ) ||
             {:error, :unknown_certificate},
         true <- certificate.generation == component.generation || {:error, :stale_generation},
         :ok <- certificate_validity(certificate, now),
         true <-
           not Enum.any?(revocations, &revoked?(&1, component, fingerprint)) ||
             {:error, :certificate_revoked} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  def authorize(_snapshot, _component_id, _fingerprint, _now), do: {:error, :invalid_snapshot}

  defp fresh(generated, until, now) do
    if DateTime.compare(now, generated) != :lt and DateTime.before?(now, until) and
         DateTime.diff(until, generated, :microsecond) in 1..(@snapshot_seconds * 1_000_000) do
      :ok
    else
      {:error, :stale_snapshot}
    end
  end

  defp certificate_validity(certificate, now) do
    if DateTime.compare(now, certificate.not_before) != :lt and
         DateTime.before?(now, certificate.not_after),
       do: :ok,
       else: {:error, :certificate_not_valid}
  end

  defp revoked?(entry, component, fingerprint) do
    entry.component_id == component.component_id and entry.generation == component.generation and
      (is_nil(entry.fingerprint) or entry.fingerprint == fingerprint)
  end

  defp create_or_reuse_certificate(changeset, opts) do
    case find_certificate(Ash.Changeset.get_attribute(changeset, :fingerprint), opts) do
      {:error, :unknown_certificate} ->
        Ash.create(changeset, opts)

      {:ok, certificate} ->
        if same_certificate?(certificate, changeset),
          do: reuse_certificate(certificate, opts),
          else: {:error, :certificate_metadata_conflict}

      error ->
        error
    end
  end

  defp same_certificate?(certificate, changeset) do
    Enum.all?(@certificate_fields, fn field ->
      expected = Ash.Changeset.get_attribute(changeset, field)
      stored = Map.fetch!(certificate, field)

      if field in [:not_before, :not_after],
        do: DateTime.compare(stored, expected) == :eq,
        else: stored == expected
    end)
  end

  defp reuse_certificate(certificate, opts) do
    query =
      RevokedComponentCertificate
      |> Ash.Query.filter(
        component_id == ^certificate.component_id and generation == ^certificate.generation and
          (is_nil(fingerprint) or fingerprint == ^certificate.fingerprint)
      )
      |> Ash.Query.limit(1)

    case Ash.read_one(query, opts) do
      {:ok, nil} -> {:ok, certificate}
      {:ok, _} -> {:error, :certificate_revoked}
      error -> error
    end
  end

  defp lock_component(component_id, opts) do
    case ManagedComponent
         |> Ash.Query.filter(component_id == ^component_id)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one(opts) do
      {:ok, %ManagedComponent{} = component} -> {:ok, component}
      {:ok, nil} -> {:error, :unknown_component}
      error -> error
    end
  end

  defp find_certificate(fingerprint, opts) do
    case ComponentCertificate
         |> Ash.Query.filter(fingerprint == ^fingerprint)
         |> Ash.read_one(opts) do
      {:ok, %ComponentCertificate{} = certificate} -> {:ok, certificate}
      {:ok, nil} -> {:error, :unknown_certificate}
      error -> error
    end
  end

  defp record_revocation(component, fingerprint, reason, opts) do
    query =
      Ash.Query.filter(
        RevokedComponentCertificate,
        component_id == ^component.component_id and generation == ^component.generation
      )

    query =
      if is_nil(fingerprint),
        do: Ash.Query.filter(query, is_nil(fingerprint)),
        else: Ash.Query.filter(query, fingerprint == ^fingerprint)

    case Ash.read_one(query, opts) do
      {:ok, nil} ->
        RevokedComponentCertificate
        |> Ash.Changeset.for_create(
          :revoke,
          %{
            component_id: component.component_id,
            generation: component.generation,
            fingerprint: fingerprint,
            reason: reason
          },
          opts
        )
        |> Ash.create(opts)

      result ->
        result
    end
  end

  defp notify({:ok, _} = result) do
    if Process.whereis(ServiceRadar.PubSub),
      do: Phoenix.PubSub.broadcast(ServiceRadar.PubSub, @topic, :certificate_policy_changed)

    result
  end

  defp notify(error), do: error

  defp transaction(fun) do
    [ManagedComponent, ComponentCertificate, RevokedComponentCertificate]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :component_certificate,
             value: reason,
             message: "certificate operation refused"
           )}

        result ->
          result
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, %InvalidArgument{field: :component_certificate, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{
         errors: [%InvalidArgument{field: :component_certificate, value: reason}]
       }} ->
        {:error, reason}

      error ->
        error
    end
  end
end
