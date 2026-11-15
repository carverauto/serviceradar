defmodule ServiceRadar.Camera.ArchiveCredentialResolver do
  @moduledoc """
  Resolves `s3_compatible` archive storage credentials through `SecretBroker`.

  Camera archive credentials live exclusively in `platform.network_credential_secrets`
  under the `s3_compatible` native descriptor (`credential_kind: :opaque`) and
  resolve through scoped, endpoint-locked `CredentialBrokerGrant` records. No
  Kubernetes Secret, Helm value, OpenBao path, or process environment variable
  is accepted as an archive credential source.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.JSONDocument
  alias ServiceRadar.Plugins.SecretRefs

  @provider "s3_compatible"
  @grant_type "camera_archive_credential"
  @target_kind "camera_archive_binding"
  @control_plane_agent "control-plane"
  @default_ttl_seconds 900
  @max_generation 9_223_372_036_854_775_807

  @type role :: :writer | :reader

  @doc """
  Builds scoped `CredentialBrokerGrant` attributes locked to `binding`'s HTTPS host and bucket.
  """
  @spec grant_attrs(map() | struct(), role(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def grant_attrs(binding, role, secret_id_or_ref, opts \\ []) when is_list(opts) do
    with {:ok, normalized_binding} <- normalize_binding(binding),
         {:ok, purpose, methods} <- role_policy(role),
         {:ok, secret_id, secret_ref} <- normalize_secret_identity(secret_id_or_ref),
         {:ok, ttl_seconds} <-
           normalize_ttl(Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      attrs =
        CredentialBrokerGrant.issue_attrs(
          %{
            secret_id: secret_id,
            secret_ref: secret_ref,
            grant_type: @grant_type,
            consumer_kind: :service_monitoring,
            consumer_id: consumer_id(role, normalized_binding.id),
            purpose: purpose,
            target_kind: @target_kind,
            target_id: normalized_binding.id,
            agent_id: @control_plane_agent,
            resolution_location: :control_plane,
            allowed_schemes: ["https"],
            allowed_methods: methods,
            allowed_paths: [
              "/" <> normalized_binding.bucket <> "/" <> normalized_binding.namespace <> "/*"
            ],
            allowed_hosts: [normalized_binding.host],
            allowed_ports: [443],
            ttl_seconds: ttl_seconds,
            metadata: %{
              "provider" => @provider,
              "destination_sha256" => normalized_binding.destination_sha256,
              "role" => Atom.to_string(role)
            }
          },
          now
        )

      {:ok, attrs}
    end
  end

  @doc """
  Verifies the target `s3_compatible` secret and reuses or issues a scoped broker grant.
  """
  @spec issue_or_reuse_grant(map() | struct(), role(), String.t(), keyword()) ::
          {:ok, map() | struct()} | {:error, term()}
  def issue_or_reuse_grant(binding, role, secret_id_or_ref, opts \\ []) when is_list(opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_archive_credential_resolver))
    secret_loader = Keyword.get(opts, :secret_loader, &NetworkCredentialSecret.get_secret_by_id/2)
    grant_issuer = Keyword.get(opts, :grant_issuer, &CredentialBrokerGrant.reuse_or_issue/2)

    with {:ok, attrs} <- grant_attrs(binding, role, secret_id_or_ref, opts),
         {:ok, secret} <- secret_loader.(attrs.secret_id, actor: actor),
         :ok <- validate_secret_record(secret) do
      grant_issuer.(attrs, grant_issue_opts(actor, opts))
    end
  end

  @doc """
  Resolves an issued archive credential grant through `SecretBroker.resolve_with_grant/2`
  into the runtime credential document consumed by `CameraStorage`.
  """
  @spec resolve_runtime_credential(map() | struct(), role(), map() | struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_credential(binding, role, grant, opts \\ [])
      when is_map(grant) and is_list(opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_archive_credential_resolver))
    broker = Keyword.get(opts, :broker, &SecretBroker.resolve_with_grant/2)

    with {:ok, normalized_binding} <- normalize_binding(binding),
         {:ok, purpose, methods} <- role_policy(role),
         :ok <- validate_grant_egress(grant, normalized_binding, methods),
         broker_opts = broker_opts(normalized_binding, role, purpose, actor, opts),
         {:ok, resolved} <- broker.(grant, broker_opts),
         :ok <- validate_secret_record(resolved.secret),
         {:ok, generation} <- resolve_generation(resolved.secret, opts),
         {:ok, decoded} <- decode_secret_payload(resolved.value) do
      reference = SecretRefs.network_credential_ref(to_string(field(resolved.secret, :id)))
      {:ok, build_runtime_document(reference, generation, decoded)}
    end
  end

  @doc """
  Issues (or reuses) a scoped grant and resolves the runtime credential document for `binding`.
  """
  @spec resolve_for_binding(map() | struct(), role(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_for_binding(binding, role, secret_id_or_ref, opts \\ []) when is_list(opts) do
    with {:ok, grant} <- issue_or_reuse_grant(binding, role, secret_id_or_ref, opts) do
      resolve_runtime_credential(binding, role, grant, opts)
    end
  end

  defp normalize_binding(binding) when is_map(binding) do
    id = field(binding, :id)
    destination_input = destination_map(binding)

    with {:ok, uuid} <- Ecto.UUID.cast(to_string(id || "")),
         {:ok, parsed} <- ArchiveDestination.attributes(destination_input),
         %URI{scheme: "https", host: host, port: 443} when is_binary(host) <-
           URI.parse(parsed.endpoint) do
      expected_sha = field(binding, :destination_sha256)

      if is_nil(expected_sha) or expected_sha == parsed.destination_sha256 do
        {:ok,
         %{
           id: uuid,
           host: host,
           bucket: parsed.bucket,
           namespace: parsed.namespace,
           destination_sha256: parsed.destination_sha256
         }}
      else
        {:error, :archive_binding_destination_mismatch}
      end
    else
      _ -> {:error, :invalid_archive_binding}
    end
  end

  defp normalize_binding(_), do: {:error, :invalid_archive_binding}

  defp destination_map(binding) do
    %{
      "schema_version" => field(binding, :schema_version) || 1,
      "provisioning_ref" => field(binding, :provisioning_ref),
      "generation" => field(binding, :generation),
      "purpose" => field(binding, :purpose),
      "provider" => field(binding, :provider),
      "endpoint" => field(binding, :endpoint),
      "region" => field(binding, :region),
      "bucket" => field(binding, :bucket),
      "namespace" => field(binding, :namespace),
      "archive_format_version" => field(binding, :archive_format_version) || 1,
      "required_encryption" => field(binding, :required_encryption)
    }
  end

  defp role_policy(:writer), do: {:ok, "camera_archive_write", ["PUT", "HEAD", "GET"]}
  defp role_policy(:reader), do: {:ok, "camera_archive_read", ["HEAD", "GET"]}
  defp role_policy(_), do: {:error, :invalid_archive_credential_role}

  defp normalize_secret_identity(value) when is_binary(value) do
    trimmed = String.trim(value)

    case SecretRefs.network_credential_ref_id(trimmed) do
      {:ok, id} ->
        cast_secret_uuid(id)

      {:error, _} ->
        cast_secret_uuid(trimmed)
    end
  end

  defp normalize_secret_identity(_), do: {:error, :invalid_credential_secret_id}

  defp cast_secret_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid, SecretRefs.network_credential_ref(uuid)}
      :error -> {:error, :invalid_credential_secret_id}
    end
  end

  defp normalize_ttl(ttl) when is_integer(ttl) and ttl in 1..86_400, do: {:ok, ttl}
  defp normalize_ttl(_), do: {:error, :invalid_grant_ttl}

  defp validate_secret_record(secret) when is_map(secret) do
    provider = field(secret, :provider)
    kind = field(secret, :credential_kind)
    deleted_at = field(secret, :deleted_at)
    enabled = field(secret, :enabled)

    cond do
      not is_nil(deleted_at) or enabled == false ->
        {:error, :credential_secret_inactive}

      provider != @provider ->
        {:error, :credential_provider_mismatch}

      kind not in [:opaque, "opaque"] ->
        {:error, :credential_kind_mismatch}

      true ->
        :ok
    end
  end

  defp validate_secret_record(_), do: {:error, :invalid_credential_secret}

  defp validate_grant_egress(grant, binding, expected_methods) do
    schemes = field(grant, :allowed_schemes)
    hosts = field(grant, :allowed_hosts)
    ports = field(grant, :allowed_ports)
    paths = field(grant, :allowed_paths)
    methods = field(grant, :allowed_methods)
    expected_path = "/" <> binding.bucket <> "/" <> binding.namespace <> "/*"

    if schemes == ["https"] and hosts == [binding.host] and ports == [443] and
         paths == [expected_path] and methods == expected_methods do
      :ok
    else
      {:error, :grant_egress_scope_mismatch}
    end
  end

  defp resolve_generation(secret, opts) do
    candidate =
      Keyword.get(opts, :generation) ||
        field(secret, :generation) ||
        metadata_generation(field(secret, :metadata)) ||
        1

    if is_integer(candidate) and candidate in 1..@max_generation do
      {:ok, candidate}
    else
      {:error, :invalid_credential_generation}
    end
  end

  defp metadata_generation(%{"generation" => gen}) when is_integer(gen), do: gen
  defp metadata_generation(_), do: nil

  defp decode_secret_payload(raw) when is_binary(raw) do
    with {:ok, payload} <- JSONDocument.decode_object(raw, 4096),
         true <- Enum.sort(Map.keys(payload)) == ["access_key_id", "secret_access_key"],
         access_key when is_binary(access_key) <- payload["access_key_id"],
         secret_key when is_binary(secret_key) <- payload["secret_access_key"],
         true <- valid_secret_string?(access_key, 1, 256),
         true <- valid_secret_string?(secret_key, 1, 512) do
      {:ok,
       %{
         access_key_id: access_key,
         secret_access_key: secret_key
       }}
    else
      _ -> {:error, :invalid_s3_credential_payload}
    end
  end

  defp decode_secret_payload(_), do: {:error, :invalid_s3_credential_payload}

  defp valid_secret_string?(value, min_len, max_len) do
    byte_size(value) in min_len..max_len and String.valid?(value) and
      String.trim(value) == value and not String.contains?(value, [<<0>>, "\r", "\n"])
  end

  defp build_runtime_document(reference, generation, decoded) do
    %{
      "reference" => reference,
      "generation" => generation,
      "access_key_id" => decoded.access_key_id,
      "secret_access_key" => decoded.secret_access_key
    }
  end

  defp grant_issue_opts(actor, opts) do
    opts
    |> Keyword.take([:now, :min_remaining_seconds])
    |> Keyword.put(:actor, actor)
  end

  defp broker_opts(binding, role, purpose, actor, opts) do
    opts
    |> Keyword.take([:now, :audit_sink])
    |> Keyword.merge(
      actor: actor,
      audit?: Keyword.get(opts, :audit?, true),
      consumer_kind: :service_monitoring,
      consumer_id: consumer_id(role, binding.id),
      purpose: purpose,
      target_kind: @target_kind,
      target_id: binding.id,
      agent_id: @control_plane_agent,
      resolution_location: :control_plane
    )
  end

  defp consumer_id(role, binding_id), do: "camera-archive:#{role}:#{binding_id}"

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
