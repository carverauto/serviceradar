defmodule ServiceRadar.Edge.InfrastructureCertificateAdoption do
  @moduledoc """
  Prepares one existing public infrastructure certificate for adoption.

  The permission block is a static NATS user block. An empty allow list is
  projected to `[">"]` and the deny list is kept. A non-empty allow list is
  copied unchanged. The PEM may contain only certificates. The first is the
  component certificate. The next certificate is its issuer, and the last
  must validate that chain. A self-signed certificate is its own issuer.
  A private key is refused here, before any record is written.
  `prepare/1` is the first adoption and binds generation 1.
  `prepare_certificate/1` reads a public certificate for a component that
  already exists. That result has no generation. The authority binds the
  locked component generation before recording.
  """

  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.StaticNatsPermissionProjection
  alias ServiceRadar.NATS.StaticIdentityGrants

  @private_key_types [
    :RSAPrivateKey,
    :DSAPrivateKey,
    :ECPrivateKey,
    :PrivateKeyInfo,
    :EncryptedPrivateKeyInfo
  ]

  @type prepared :: %{component: map(), issuance: map()}

  @spec prepare(map()) ::
          {:ok, prepared()}
          | {:error,
             :invalid_adoption
             | :not_infrastructure
             | :invalid_permissions
             | :invalid_subject
             | :invalid_certificate
             | :private_key
             | :certificate_not_valid
             | :issuer_certificate_required
             | :untrusted_issuer}
  def prepare(attrs) do
    with {:ok, component, presented} <- read_adoption(attrs) do
      verify_adoption(component, presented)
    end
  end

  @doc false
  def read_adoption(attrs) when is_map(attrs) do
    with {:ok, presented} <- read_certificate(attrs),
         {:ok, permissions} <- project(fetch(attrs, :permissions)),
         {:ok, identity} <- identity(attrs) do
      {:ok, Map.put(identity, :permissions, permissions), presented}
    end
  end

  def read_adoption(_attrs), do: {:error, :invalid_adoption}

  @doc false
  def verify_adoption(component, presented) do
    with {:ok, issuance} <- verify_certificate(presented) do
      {:ok, %{component: component, issuance: Map.put(issuance, :expected_generation, 1)}}
    end
  end

  @doc """
  Reads one public certificate for an infrastructure component that already exists.

  The returned issuance has no `expected_generation`. The caller binds the
  locked component generation. A private key is refused before any record is written.
  """
  @spec prepare_certificate(map()) ::
          {:ok, map()}
          | {:error,
             :invalid_certificate
             | :private_key
             | :certificate_not_valid
             | :issuer_certificate_required
             | :untrusted_issuer}
  def prepare_certificate(attrs) do
    with {:ok, presented} <- read_certificate(attrs) do
      verify_certificate(presented)
    end
  end

  @doc "Reads the leaf and its metadata before checking validity and issuer trust."
  def read_certificate(attrs) when is_map(attrs) do
    with {:ok, [leaf | chain]} <- certificates(fetch(attrs, :certificate_pem)),
         {:ok, fields} <- describe(leaf),
         :ok <- validate_chain_encoding(chain) do
      {:ok, %{leaf: leaf, chain: chain, fields: fields}}
    end
  end

  def read_certificate(_attrs), do: {:error, :invalid_certificate}

  defp validate_chain_encoding(chain) do
    Enum.each(chain, &:public_key.pkix_decode_cert(&1, :plain))
    :ok
  rescue
    _ -> {:error, :invalid_certificate}
  end

  @doc false
  def verify_certificate(%{leaf: leaf, chain: chain, fields: fields}) do
    with :ok <- current?(fields) do
      bind_issuer(leaf, fields, chain)
    end
  end

  defp project(permissions) when is_map(permissions),
    do: StaticNatsPermissionProjection.project(permissions)

  defp project(_permissions), do: {:error, :invalid_permissions}

  defp identity(attrs) do
    component_type = fetch(attrs, :component_type)
    server_hosts =
      case fetch(attrs, :server_hosts) do
        nil -> []
        hosts -> hosts
      end

    with {:ok, component_id} <- cast_component_id(fetch(attrs, :component_id)),
         {:ok, partition_id} <-
           cast_id(ManagedComponent, :partition_id, fetch(attrs, :partition_id), :invalid_adoption) do
      cond do
        not valid_hosts?(server_hosts) ->
          {:error, :invalid_adoption}

        not ManagedComponent.infrastructure_type?(component_type) ->
          {:error, :not_infrastructure}

        true ->
          {:ok,
           %{
             component_id: component_id,
             component_type: component_type,
             partition_id: partition_id,
             server_hosts: server_hosts
           }}
      end
    end
  end

  @doc false
  def cast_component_id(value),
    do: cast_id(ManagedComponent, :component_id, value, :invalid_adoption)

  @doc false
  def cast_fingerprint(value),
    do: cast_id(ComponentCertificate, :fingerprint, value, :unknown_certificate)

  defp cast_id(resource, field, value, error) when is_binary(value) do
    with true <- String.valid?(value) and not String.contains?(value, <<0>>),
         %{valid?: true} = changeset <-
           resource |> Ash.Changeset.new() |> Ash.Changeset.change_attribute(field, value),
         id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, field) do
      {:ok, id}
    else
      _ -> {:error, error}
    end
  end

  defp cast_id(_resource, _field, _value, error), do: {:error, error}

  defp valid_hosts?(hosts), do: is_list(hosts) and Enum.all?(hosts, &is_binary/1)

  defp certificates(pem) when is_binary(pem) do
    if String.contains?(pem, "PRIVATE KEY") do
      {:error, :private_key}
    else
      case decode_entries(pem) do
        {:ok, entries} -> classify(entries)
        :error -> {:error, :invalid_certificate}
      end
    end
  end

  defp certificates(_pem), do: {:error, :invalid_certificate}

  defp decode_entries(pem) do
    {:ok, :public_key.pem_decode(pem)}
  rescue
    _ -> :error
  end

  defp classify([]), do: {:error, :invalid_certificate}

  defp classify(entries) do
    cond do
      Enum.any?(entries, &private_key_entry?/1) ->
        {:error, :private_key}

      Enum.all?(entries, &certificate_entry?/1) ->
        {:ok, Enum.map(entries, fn {:Certificate, der, :not_encrypted} -> der end)}

      true ->
        {:error, :invalid_certificate}
    end
  end

  defp certificate_entry?({:Certificate, der, :not_encrypted}) when is_binary(der), do: true
  defp certificate_entry?(_entry), do: false

  defp private_key_entry?({type, _der, _cipher}), do: type in @private_key_types
  defp private_key_entry?(_entry), do: false

  defp bind_issuer(leaf, fields, []) do
    cond do
      not fields.self_signed? ->
        {:error, :issuer_certificate_required}

      verify_self_signed?(leaf) ->
        {:ok, issuance(fields, fields.fingerprint)}

      true ->
        {:error, :untrusted_issuer}
    end
  end

  defp bind_issuer(leaf, fields, [issuer | _] = chain) do
    anchor = List.last(chain)
    path = [leaf | Enum.drop(chain, -1)]

    if path_valid?(anchor, path) do
      {:ok, issuance(fields, fingerprint(issuer))}
    else
      {:error, :untrusted_issuer}
    end
  end

  defp issuance(fields, issuer_fingerprint) do
    %{
      fingerprint: fields.fingerprint,
      issuer_fingerprint: issuer_fingerprint,
      serial_number: fields.serial_number,
      not_before: fields.not_before,
      not_after: fields.not_after,
      subject: fields.subject,
      role: "client",
      host_agent_id: nil
    }
  end

  defp describe(der) do
    {:Certificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :plain)
    {:Validity, not_before, not_after} = elem(tbs, 5)

    with {:ok, not_before} <- asn1_time(not_before),
         {:ok, not_after} <- asn1_time(not_after),
         serial when is_integer(serial) <- elem(tbs, 2) do
      {:ok,
       %{
         fingerprint: fingerprint(der),
         subject: stored_subject(der, elem(tbs, 6)),
         serial_number: serial |> Integer.to_string(16) |> String.downcase(),
         not_before: not_before,
         not_after: not_after,
         self_signed?: elem(tbs, 4) == elem(tbs, 6)
       }}
    else
      _ -> {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  defp stored_subject(der, name) do
    case StaticIdentityGrants.certificate_subject(der) do
      {:ok, subject} -> subject
      :error -> "#" <> Base.encode16(:public_key.der_encode(:Name, name), case: :lower)
    end
  end

  defp current?(fields) do
    now = DateTime.utc_now()

    if DateTime.compare(now, fields.not_before) != :lt and
         DateTime.after?(fields.not_after, now) do
      :ok
    else
      {:error, :certificate_not_valid}
    end
  end

  defp path_valid?(anchor, path) do
    match?({:ok, _}, :public_key.pkix_path_validation(anchor, path, []))
  rescue
    _ -> false
  end

  defp verify_self_signed?(der) do
    {:Certificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :plain)
    spki = elem(tbs, 7)
    encoded = :public_key.der_encode(:SubjectPublicKeyInfo, spki)

    key =
      :public_key.pem_entry_decode({:SubjectPublicKeyInfo, encoded, :not_encrypted})

    :public_key.pkix_verify(der, key)
  rescue
    _ -> false
  end

  defp fingerprint(der), do: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)

  # RFC 5280: UTCTime is YYMMDDHHMMSSZ. Years 50-99 mean 19xx.
  # GeneralizedTime is YYYYMMDDHHMMSSZ.
  defp asn1_time({:utcTime, time}) do
    <<yy::binary-2, rest::binary>> = to_string(time)
    century = if String.to_integer(yy) >= 50, do: "19", else: "20"
    asn1_time({:generalTime, century <> yy <> rest})
  end

  defp asn1_time({:generalTime, time}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      to_string(time)

    with {:ok, naive} <- NaiveDateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}") do
      DateTime.from_naive(naive, "Etc/UTC")
    end
  end

  defp asn1_time(_time), do: :error

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
