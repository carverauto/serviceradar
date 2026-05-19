defmodule ServiceRadar.Edge.RemoteAccessSSHCertificates do
  @moduledoc """
  Orchestrates policy and signing for generic SSH remote-access certificates.

  The signer is injected so CA key custody can move to a dedicated service,
  OpenBao/KMS-backed signer, or a native port without coupling web-ng or the
  agent gateway to CA private key material.
  """

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Security.RateLimiter

  @type sign_request :: %{
          public_key: String.t(),
          key_id: String.t(),
          principals: [String.t()],
          ttl_seconds: pos_integer(),
          audit: map()
        }

  @type sign_result :: %{
          certificate: String.t(),
          expires_at: DateTime.t() | nil,
          fingerprint: String.t() | nil,
          serial: String.t() | integer() | nil,
          ca_key_id: String.t() | nil
        }

  @callback sign_user_certificate(sign_request(), keyword()) ::
              {:ok, sign_result()} | {:error, term()}

  @spec issue(map() | struct(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(actor, attrs, opts \\ []) do
    opts = Keyword.merge(config(), opts)
    signer = Keyword.get(opts, :signer)

    with {:ok, signer} <- validate_signer(signer),
         {:ok, request} <- RemoteAccessSSHCertificatePolicy.authorize(actor, attrs, opts),
         :ok <- enforce_rate_limit(request, opts),
         {:ok, signed} <- signer.sign_user_certificate(sign_request(request), opts) do
      {:ok, issue_result(request, signed)}
    end
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp validate_signer(nil), do: {:error, :ssh_certificate_signer_unavailable}

  defp validate_signer(signer) when is_atom(signer) do
    if function_exported?(signer, :sign_user_certificate, 2) do
      {:ok, signer}
    else
      {:error, :ssh_certificate_signer_invalid}
    end
  end

  defp validate_signer(_signer), do: {:error, :ssh_certificate_signer_invalid}

  defp enforce_rate_limit(request, opts) do
    rate_limit_opts = Keyword.get(opts, :rate_limit, [])

    if Keyword.get(rate_limit_opts, :enabled, true) do
      case RateLimiter.check_and_record(
             :remote_access_ssh_certificate_issue,
             rate_limit_key(request),
             rate_limit_opts
           ) do
        :ok -> :ok
        {:error, retry_after} -> {:error, {:ssh_certificate_rate_limited, retry_after}}
      end
    else
      :ok
    end
  end

  defp rate_limit_key(request) do
    actor_id = get_in(request, [:audit, :actor_id]) || "unknown-actor"
    {actor_id, request.protocol}
  end

  defp sign_request(request) do
    %{
      public_key: request.public_key,
      key_id: request.key_id,
      principals: request.principals,
      ttl_seconds: request.ttl_seconds,
      audit: request.audit
    }
  end

  defp issue_result(request, signed) do
    %{
      session_id: request.session_id,
      agent_id: request.agent_id,
      gateway_id: request.gateway_id,
      protocol: request.protocol,
      credential_mode: request.credential_mode,
      ssh: %{
        "username" => request.ssh_username,
        "certificate" => Map.fetch!(signed, :certificate)
      },
      target: request.target,
      key_id: request.key_id,
      principals: request.principals,
      ttl_seconds: request.ttl_seconds,
      expires_at: Map.get(signed, :expires_at),
      fingerprint: Map.get(signed, :fingerprint),
      serial: Map.get(signed, :serial),
      ca_key_id: Map.get(signed, :ca_key_id),
      audit: Map.merge(request.audit, signer_audit(signed))
    }
  end

  defp signer_audit(signed) do
    %{
      certificate_fingerprint: Map.get(signed, :fingerprint),
      certificate_serial: Map.get(signed, :serial),
      ca_key_id: Map.get(signed, :ca_key_id),
      expires_at: Map.get(signed, :expires_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
