defmodule ServiceRadar.Inventory.AdvisoryFeeds.CredentialResolver do
  @moduledoc """
  Resolves the reusable VulnCheck API credential through the credential broker.

  Feed definitions persist a `NetworkCredentialSecret` ID, never the plaintext
  token. Legacy `credentialref:network-credential-secret:<uuid>` values are
  accepted so upgrades can retain references created by the retired advisory
  producer.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.SecretBroker

  @legacy_prefix "credentialref:network-credential-secret:"
  @consumer_id "advisory-feeds:vulncheck"

  @type error_reason ::
          :invalid_vulncheck_credential_ref
          | :invalid_vulncheck_credential
          | :empty_vulncheck_credential
          | {:grant_issue_failed, term()}
          | {:secret_resolution_failed, term()}

  @doc "Resolve a stored credential-secret ID to the VulnCheck bearer token."
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def resolve(ref, opts \\ [])

  def resolve(ref, opts) when is_binary(ref) do
    resolve_feed(ref, opts, "vulncheck", "api.vulncheck.com", "vulnerability_feed_download")
  end

  def resolve(_ref, _opts), do: {:error, :invalid_vulncheck_credential_ref}

  @doc "Resolve the canonical core OTX credential through a persisted, audited broker grant."
  def resolve_otx(ref, opts \\ [])

  def resolve_otx(ref, opts) when is_binary(ref) do
    resolve_feed(ref, opts, "alienvault-otx-core", "otx.alienvault.com", "threat_intel_sync")
  end

  def resolve_otx(_ref, _opts), do: {:error, :invalid_otx_credential_ref}

  defp resolve_feed(ref, opts, provider, host, purpose) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:advisory_feed_credential))
    grant_issuer = Keyword.get(opts, :grant_issuer, &default_grant_issuer/2)
    secret_resolver = Keyword.get(opts, :secret_resolver, &default_secret_resolver/2)

    with {:ok, secret_id} <- credential_secret_id(ref),
         {:ok, grant} <- issue_grant(grant_issuer, secret_id, actor, provider, host, purpose),
         {:ok, resolved} <- resolve_secret(secret_resolver, grant, actor),
         :ok <- validate_secret(resolved, provider) do
      present_token(Map.get(resolved, :value))
    end
  end

  @doc false
  @spec credential_secret_id(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_vulncheck_credential_ref}
  def credential_secret_id(ref) when is_binary(ref) do
    candidate =
      ref
      |> String.trim()
      |> String.replace_prefix(@legacy_prefix, "")

    case Ecto.UUID.cast(candidate) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_vulncheck_credential_ref}
    end
  end

  defp issue_grant(issuer, secret_id, actor, provider, host, purpose) do
    attrs = %{
      secret_id: secret_id,
      grant_type: "advisory_feed_credential",
      consumer_kind: :service_monitoring,
      consumer_id: if(provider == "vulncheck", do: @consumer_id, else: "threat-intel:otx"),
      purpose: purpose,
      target_kind: if(provider == "vulncheck", do: "vulnerability_feed", else: "threat_intel_feed"),
      target_id: provider,
      resolution_location: :control_plane,
      allowed_methods: ["GET"],
      allowed_hosts: [host],
      allowed_ports: [443],
      metadata: %{"provider" => provider, "source" => "core-scheduled"},
      ttl_seconds: 1_800
    }

    case issuer.(attrs, actor) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, {:grant_issue_failed, reason}}
      other -> {:error, {:grant_issue_failed, {:invalid_result, other}}}
    end
  end

  defp resolve_secret(resolver, grant, actor) do
    opts = [actor: actor, audit?: true]

    case resolver.(grant, opts) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:secret_resolution_failed, reason}}
      other -> {:error, {:secret_resolution_failed, {:invalid_result, other}}}
    end
  end

  defp validate_secret(%{secret: secret}, expected_provider) when is_map(secret) do
    provider = Map.get(secret, :provider) || Map.get(secret, "provider")
    kind = Map.get(secret, :credential_kind) || Map.get(secret, "credential_kind")

    allowed_kinds = if expected_provider == "vulncheck", do: [:api_token, :opaque, "api_token", "opaque"], else: [:api_token, "api_token"]

    if provider == expected_provider and kind in allowed_kinds do
      :ok
    else
      {:error, :invalid_vulncheck_credential}
    end
  end

  defp validate_secret(_resolved, _provider), do: {:error, :invalid_vulncheck_credential}

  defp present_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> {:error, :empty_vulncheck_credential}
      value -> {:ok, value}
    end
  end

  defp present_token(_token), do: {:error, :empty_vulncheck_credential}

  defp default_grant_issuer(attrs, actor) do
    attrs
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(actor: actor)
  end

  defp default_secret_resolver(grant, opts), do: SecretBroker.resolve_with_grant(grant, opts)
end
