defmodule ServiceRadar.Credentials.SecretBrokerTest.EchoingTestAdapter do
  @moduledoc false

  # An adapter whose test result echoes the secret it read, so the broker's own
  # redaction is the only thing keeping it out of the returned result.
  def resolve(reference, _provider, _opts) do
    {:ok, %{value: get_in(reference, [:metadata, "stub_secret_value"]), cache_status: :miss}}
  end

  def test(reference, _provider, _opts) do
    {:ok, %{status: :success, password: get_in(reference, [:metadata, "stub_secret_value"])}}
  end
end

defmodule ServiceRadar.Credentials.SecretBrokerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Credentials.SecretBrokerTest.EchoingTestAdapter

  test "resolves internally encrypted credential payloads through shared broker API" do
    secret = %{
      id: "secret-1",
      source_type: :internal_encrypted,
      provider: "proxmox",
      credential_kind: :api_token,
      secret_payload: "root@pam!sr=test-token",
      metadata: %{}
    }

    assert {:ok, resolved} = SecretBroker.resolve_loaded_secret(secret)
    assert resolved.source_type == :internal_encrypted
    assert resolved.value == "root@pam!sr=test-token"
    assert resolved.provider == nil
    assert resolved.cache_status == :disabled
  end

  test "discards a caller-supplied grant and refuses the external reference" do
    provider = %{
      id: "provider-1",
      provider_type: :stub,
      enabled: true,
      resolution_locations: [:agent]
    }

    secret = %{
      id: "secret-1",
      source_type: :external_reference,
      secret_provider_id: "provider-1",
      external_secret_ref: "secret/data/example/db-password",
      credential_kind: :username_password,
      metadata: %{"stub_secret_value" => "example-db-password"},
      external_secret_fields: %{"password" => "password"},
      resolution_location: :agent
    }

    assert {:error, :external_secret_requires_broker_grant} =
             SecretBroker.resolve_loaded_secret(secret,
               provider: provider,
               grant: grant_for(secret, "grant-1", resolution_location: :agent),
               resolution_location: :agent,
               consumer_kind: :plugin,
               target_id: "svc-db"
             )
  end

  test "blocks external reference resolution by default without a broker grant" do
    secret = %{
      id: "secret-1",
      source_type: :external_reference,
      external_secret_ref: "folders/prod/http-token"
    }

    assert {:error, :external_secret_requires_broker_grant} =
             SecretBroker.resolve_loaded_secret(secret)
  end

  test "blocks external reference resolution with only a grant id" do
    provider = %{
      id: "provider-1",
      provider_type: :stub,
      enabled: true,
      resolution_locations: [:agent]
    }

    secret = %{
      id: "secret-1",
      source_type: :external_reference,
      secret_provider_id: "provider-1",
      external_secret_ref: "folders/prod/http-token",
      resolution_location: :agent
    }

    assert {:error, :external_secret_requires_broker_grant} =
             SecretBroker.resolve_loaded_secret(secret,
               provider: provider,
               grant_id: "grant-1",
               resolution_location: :agent
             )
  end

  test "provider test results are redacted before leaving the broker" do
    provider = %{
      id: "provider-1",
      provider_type: :stub,
      enabled: false,
      resolution_locations: [:control_plane]
    }

    reference = %{
      external_secret_ref: "folders/prod/healthcheck",
      metadata: %{"stub_secret_value" => "healthcheck-secret"}
    }

    assert {:ok, result} =
             SecretBroker.test_provider_reference(provider, reference,
               adapter: EchoingTestAdapter,
               record_provider_state?: false
             )

    assert result.status == :success
    refute inspect(result) =~ "healthcheck-secret"
  end

  test "provider test errors stay behind the broker boundary" do
    provider = %{
      id: "provider-1",
      provider_type: :stub,
      enabled: false,
      resolution_locations: [:control_plane]
    }

    assert {:error, :not_found} =
             SecretBroker.test_provider_reference(provider, %{external_secret_ref: "missing"},
               record_provider_state?: false
             )
  end

  defp grant_for(secret, id, opts) do
    expires_at =
      opts
      |> Keyword.get(:expires_at, DateTime.add(DateTime.utc_now(), 300, :second))
      |> DateTime.truncate(:second)

    %{
      id: id,
      secret_id: to_string(secret.id),
      status: :active,
      resolution_location: Keyword.fetch!(opts, :resolution_location),
      expires_at: expires_at
    }
  end
end
