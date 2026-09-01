defmodule ServiceRadar.Credentials.CredentialBrokerGrantDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.RequestBodyPolicy
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "request-body policy round-trips and the database default is an empty object" do
    actor = SystemActor.system(:credential_broker_request_body_policy_db_test)
    body = ~s({"limit":"node-1"})
    policy = RequestBodyPolicy.bound_bytes(body, max_bytes: 256 * 1024)

    # Supply secret_id and let issue_attrs/1 derive the ref, which is what every
    # production caller does. Passing a literal ref left secret_id nil, and the
    # database now rejects that pair: a ref naming a secret must agree with the
    # secret it names.
    secret = CredentialIntegrationFixtures.secret!()

    attrs =
      CredentialBrokerGrant.issue_attrs(%{
        secret_id: secret.id,
        grant_type: "awx_oauth2_token",
        consumer_kind: :test,
        consumer_id: "request-body-policy-db-test",
        purpose: "awx.launch_job",
        resolution_location: :agent,
        allowed_methods: ["POST"],
        allowed_paths: ["=/api/v2/job_templates/42/launch/"],
        request_body_policy: policy,
        ttl_seconds: 60
      })

    assert {:ok, issued} = CredentialBrokerGrant.issue_grant(attrs, actor: actor)
    assert issued.request_body_policy == policy

    assert {:ok, reloaded} = CredentialBrokerGrant.get_by_id(issued.id, actor: actor)
    assert reloaded.request_body_policy == policy

    result =
      Repo.query!(
        """
        INSERT INTO platform.credential_broker_grants
          (secret_id, secret_ref, grant_type, consumer_kind, purpose, expires_at)
        VALUES
          (($1::text)::uuid, $2, $3, $4, $5, now() + interval '5 minutes')
        RETURNING request_body_policy
        """,
        [
          # A ref naming a secret has to agree with secret_id, so both come from
          # the same row rather than a literal that names nothing.
          secret.id,
          "credentialref:network-credential-secret:#{secret.id}",
          "awx_oauth2_token",
          "test",
          "request-body-policy-default-test"
        ]
      )

    assert result.rows == [[%{}]]
  end
end
