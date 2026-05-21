defmodule ServiceRadar.Credentials.CredentialErrorClassifierTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialErrorClassifier

  test "maps broker policy failures into allowed audit error classes" do
    assert CredentialErrorClassifier.audit_error_class(:provider_disabled) ==
             :provider_policy_denied

    assert CredentialErrorClassifier.audit_error_class({:resolution_location_not_allowed, :agent}) ==
             :provider_policy_denied

    assert CredentialErrorClassifier.audit_error_class(:external_secret_requires_broker_grant) ==
             :provider_policy_denied

    assert CredentialErrorClassifier.audit_error_class(:provider_lease_expired) ==
             :provider_policy_denied
  end

  test "maps missing provider references into invalid reference audit class" do
    assert CredentialErrorClassifier.audit_error_class(:missing_secret_provider) ==
             :invalid_reference

    assert CredentialErrorClassifier.audit_error_class(:missing_provider_token) ==
             :invalid_reference
  end

  test "preserves allowed adapter audit classes" do
    assert CredentialErrorClassifier.audit_error_class(:adapter_unavailable) ==
             :adapter_unavailable

    assert CredentialErrorClassifier.audit_error_class(:bad_field_mapping) ==
             :bad_field_mapping
  end
end
