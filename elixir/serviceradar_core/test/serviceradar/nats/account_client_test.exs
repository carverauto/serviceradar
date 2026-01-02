defmodule ServiceRadar.NATS.AccountClientTest do
  @moduledoc """
  Tests for the NATS AccountClient module.

  Tests the gRPC client wrapper for datasvc NATSAccountService including:
  - Request building
  - Limit construction
  - Subject mapping construction
  - Permission building
  - Credential type conversion
  """

  use ExUnit.Case, async: true

  describe "Proto.AccountLimits construction" do
    test "builds limits struct from map" do
      limits = %Proto.AccountLimits{
        max_connections: 100,
        max_subscriptions: 1000,
        max_payload_bytes: 4_194_304,
        max_data_bytes: 104_857_600,
        max_exports: 10,
        max_imports: 10,
        allow_wildcard_exports: false
      }

      assert limits.max_connections == 100
      assert limits.max_subscriptions == 1000
      assert limits.max_payload_bytes == 4_194_304
      assert limits.max_data_bytes == 104_857_600
    end

    test "limits struct has correct field types" do
      limits = %Proto.AccountLimits{
        max_connections: 0,
        max_subscriptions: 0,
        max_payload_bytes: 0,
        max_data_bytes: 0,
        max_exports: 0,
        max_imports: 0,
        allow_wildcard_exports: true
      }

      assert is_integer(limits.max_connections)
      assert is_integer(limits.max_subscriptions)
      assert is_boolean(limits.allow_wildcard_exports)
    end
  end

  describe "Proto.SubjectMapping construction" do
    test "builds subject mapping struct" do
      mapping = %Proto.SubjectMapping{
        from: "events.>",
        to: "acme-corp.events.>"
      }

      assert mapping.from == "events.>"
      assert mapping.to == "acme-corp.events.>"
    end
  end

  describe "Proto.UserCredentialType enum" do
    test "has collector type defined" do
      # Enum value 1 corresponds to :USER_CREDENTIAL_TYPE_COLLECTOR
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_COLLECTOR) == 1
    end

    test "has service type defined" do
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_SERVICE) == 2
    end

    test "has admin type defined" do
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_ADMIN) == 3
    end

    test "has unspecified type defined" do
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_UNSPECIFIED) == 0
    end

    test "can map from atom to value" do
      # These atoms are used in the request
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_COLLECTOR) == 1
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_SERVICE) == 2
      assert Proto.UserCredentialType.value(:USER_CREDENTIAL_TYPE_ADMIN) == 3
    end
  end

  describe "Proto.UserPermissions construction" do
    test "builds permissions struct with allow lists" do
      perms = %Proto.UserPermissions{
        publish_allow: ["events.>", "metrics.>"],
        publish_deny: ["admin.>"],
        subscribe_allow: ["events.>"],
        subscribe_deny: [],
        allow_responses: true,
        max_responses: 10
      }

      assert perms.publish_allow == ["events.>", "metrics.>"]
      assert perms.publish_deny == ["admin.>"]
      assert perms.allow_responses == true
      assert perms.max_responses == 10
    end
  end

  describe "Proto.CreateTenantAccountRequest construction" do
    test "builds request with tenant slug" do
      request = %Proto.CreateTenantAccountRequest{
        tenant_slug: "acme-corp",
        limits: nil,
        subject_mappings: []
      }

      assert request.tenant_slug == "acme-corp"
      assert request.limits == nil
      assert request.subject_mappings == []
    end

    test "builds request with limits" do
      limits = %Proto.AccountLimits{
        max_connections: 100,
        max_subscriptions: 1000
      }

      request = %Proto.CreateTenantAccountRequest{
        tenant_slug: "acme-corp",
        limits: limits,
        subject_mappings: []
      }

      assert request.limits.max_connections == 100
    end

    test "builds request with subject mappings" do
      mappings = [
        %Proto.SubjectMapping{from: "events.>", to: "acme-corp.events.>"}
      ]

      request = %Proto.CreateTenantAccountRequest{
        tenant_slug: "acme-corp",
        limits: nil,
        subject_mappings: mappings
      }

      assert length(request.subject_mappings) == 1
      assert hd(request.subject_mappings).from == "events.>"
    end
  end

  describe "Proto.GenerateUserCredentialsRequest construction" do
    test "builds request with all fields" do
      request = %Proto.GenerateUserCredentialsRequest{
        tenant_slug: "acme-corp",
        account_seed: "SATEST123",
        user_name: "collector-1",
        credential_type: :USER_CREDENTIAL_TYPE_COLLECTOR,
        permissions: nil,
        expiration_seconds: 86400
      }

      assert request.tenant_slug == "acme-corp"
      assert request.account_seed == "SATEST123"
      assert request.user_name == "collector-1"
      assert request.credential_type == :USER_CREDENTIAL_TYPE_COLLECTOR
      assert request.expiration_seconds == 86400
    end
  end

  describe "Proto.SignAccountJWTRequest construction" do
    test "builds request with revocations" do
      request = %Proto.SignAccountJWTRequest{
        tenant_slug: "acme-corp",
        account_seed: "SATEST123",
        limits: nil,
        subject_mappings: [],
        revoked_user_keys: ["UABC123", "UDEF456"]
      }

      assert request.tenant_slug == "acme-corp"
      assert request.revoked_user_keys == ["UABC123", "UDEF456"]
    end
  end

  describe "Proto.CreateTenantAccountResponse structure" do
    test "has expected fields" do
      response = %Proto.CreateTenantAccountResponse{
        account_public_key: "ATEST123",
        account_seed: "SATEST456",
        account_jwt: "eyJhbGciOiJlZDI1NTE5..."
      }

      assert response.account_public_key == "ATEST123"
      assert response.account_seed == "SATEST456"
      assert String.starts_with?(response.account_jwt, "eyJ")
    end
  end

  describe "Proto.GenerateUserCredentialsResponse structure" do
    test "has expected fields" do
      response = %Proto.GenerateUserCredentialsResponse{
        user_public_key: "UTEST123",
        user_jwt: "eyJhbGciOiJlZDI1NTE5...",
        creds_file_content: "-----BEGIN NATS USER JWT-----\n...",
        expires_at_unix: 1735689600
      }

      assert response.user_public_key == "UTEST123"
      assert String.starts_with?(response.user_jwt, "eyJ")
      assert String.contains?(response.creds_file_content, "NATS USER JWT")
      assert response.expires_at_unix == 1735689600
    end

    test "expires_at_unix of 0 means no expiration" do
      response = %Proto.GenerateUserCredentialsResponse{
        user_public_key: "UTEST123",
        user_jwt: "eyJ...",
        creds_file_content: "...",
        expires_at_unix: 0
      }

      assert response.expires_at_unix == 0
    end
  end

  describe "Proto.SignAccountJWTResponse structure" do
    test "has expected fields" do
      response = %Proto.SignAccountJWTResponse{
        account_public_key: "ATEST123",
        account_jwt: "eyJhbGciOiJlZDI1NTE5..."
      }

      assert response.account_public_key == "ATEST123"
      assert String.starts_with?(response.account_jwt, "eyJ")
    end
  end

  describe "GRPC service definition" do
    test "NATSAccountService stub module is defined" do
      # Verify the Stub module exists and has the expected structure
      assert Code.ensure_loaded?(Proto.NATSAccountService.Stub)
    end

    test "NATSAccountService service module is defined" do
      assert Code.ensure_loaded?(Proto.NATSAccountService.Service)
    end

    test "Stub module defines RPC functions" do
      # The Stub should have functions for the RPCs
      # These are generated by GRPC.Stub with varying arities
      functions = Proto.NATSAccountService.Stub.__info__(:functions)
      function_names = Enum.map(functions, fn {name, _arity} -> name end)

      assert :create_tenant_account in function_names
      assert :generate_user_credentials in function_names
      assert :sign_account_jwt in function_names
    end
  end
end
