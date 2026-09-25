defmodule ServiceRadar.Credentials.CredentialErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Credentials.CredentialErrorClassifier
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit

  # SecretBroker drops an audit row silently when create_audit rejects it, so a
  # class outside the audit resource's constraint loses the row without a trace.
  test "every broker and adapter failure reason classifies into its accepted audit class" do
    accepted =
      CredentialSecretResolutionAudit
      |> Info.attribute(:error_class)
      |> Map.fetch!(:constraints)
      |> Keyword.fetch!(:one_of)

    for {reason, expected} <- [
          {:not_found, :not_found},
          {:unauthorized, :unauthorized},
          {:rate_limited, :rate_limited},
          {:bad_field_mapping, :bad_field_mapping},
          {:invalid_reference, :invalid_reference},
          {:adapter_unavailable, :adapter_unavailable},
          {:missing_endpoint_url, :invalid_reference},
          {:missing_provider, :invalid_reference},
          {:missing_secret_provider, :invalid_reference},
          {:missing_provider_token, :invalid_reference},
          {:missing_kubernetes_auth_role, :invalid_reference},
          {:missing_kubernetes_jwt, :invalid_reference},
          {:provider_disabled, :provider_policy_denied},
          {:provider_lease_expired, :provider_policy_denied},
          {:invalid_lease_expiration, :provider_policy_denied},
          {:external_secret_requires_broker_grant, :provider_policy_denied},
          {:provider_http_error, :unreachable},
          {{:provider_http_error, 503}, :unreachable},
          {{:unreachable, :transport_error}, :unreachable},
          {{:resolution_location_not_allowed, :agent}, :provider_policy_denied},
          {{:grant_scope_mismatch, :target_id}, :provider_policy_denied},
          {:unrecognized_failure, :internal_error}
        ] do
      assert CredentialErrorClassifier.audit_error_class(reason) == expected, inspect(reason)

      assert expected in accepted,
             "#{inspect(expected)} is outside the audit error_class constraint"
    end
  end
end
