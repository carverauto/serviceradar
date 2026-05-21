defmodule ServiceRadar.Credentials.CredentialErrorClassifier do
  @moduledoc false

  @allowed_error_classes [
    :not_found,
    :unauthorized,
    :unreachable,
    :rate_limited,
    :bad_field_mapping,
    :provider_policy_denied,
    :adapter_unavailable,
    :invalid_reference,
    :internal_error
  ]

  @invalid_reference_errors [
    :missing_endpoint_url,
    :missing_provider,
    :missing_secret_provider,
    :missing_provider_token,
    :missing_kubernetes_auth_role,
    :missing_kubernetes_jwt
  ]

  @provider_policy_errors [
    :provider_disabled,
    :provider_lease_expired,
    :invalid_lease_expiration,
    :resolution_location_not_allowed,
    :external_secret_requires_broker_grant,
    :grant_scope_mismatch
  ]

  @doc false
  def audit_error_class({error_class, _detail}) when is_atom(error_class),
    do: audit_error_class(error_class)

  def audit_error_class(error_class) when error_class in @allowed_error_classes, do: error_class

  def audit_error_class(error_class) when error_class in @invalid_reference_errors,
    do: :invalid_reference

  def audit_error_class(error_class) when error_class in @provider_policy_errors,
    do: :provider_policy_denied

  def audit_error_class(:provider_http_error), do: :unreachable
  def audit_error_class(_error_class), do: :internal_error
end
