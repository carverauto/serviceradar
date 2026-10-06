defmodule ServiceRadar.Integrations.ArmisNorthboundCredentialResolutionIntegrationTest do
  @moduledoc false
  # A source bound to a reusable network credential secret (the unified CNPG
  # credential model) must run northbound without anyone re-entering the
  # secret: the runner resolves the bound secret through the credential broker,
  # the same control-plane path the inbound SyncConfigGenerator uses.
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:armis_northbound_credential_resolution_test)
    {:ok, actor: actor}
  end

  test "a broker-bound source is northbound ready and resolves its secret", %{actor: actor} do
    unique = System.unique_integer([:positive])
    secret_key = "synthetic-armis-secret-#{unique}"

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "armis-northbound-#{unique}",
          provider: "armis",
          credential_kind: :api_token,
          source_type: :internal_encrypted,
          secret_payload: Jason.encode!(%{"secret_key" => secret_key}),
          metadata: %{"test" => "armis_northbound_credential_resolution"}
        },
        actor: actor
      )

    # The regression shape: the credential lives only in the unified model
    # (credential_secret_id), with no legacy credentials on the source row.
    source = create_source!(actor, credential_secret_id: secret.id)

    assert :ok = ArmisNorthboundRunner.northbound_ready?(source)

    assert {:ok, %{"secret_key" => ^secret_key}} =
             ArmisNorthboundRunner.resolve_run_credentials(source)
  end

  test "an unbound source with no legacy credentials names what is missing", %{actor: actor} do
    source = create_source!(actor, [])

    assert {:error, {:missing_credentials, detail}} =
             ArmisNorthboundRunner.northbound_ready?(source)

    assert detail =~ to_string(source.id)
    assert detail =~ "credential_secret_id"
  end

  test "a secret that fails to resolve names the secret and reason" do
    # No source row needed: the runner accepts the binding directly, and the
    # broker refuses an id no secret row has. The error must name the secret
    # that failed and carry the broker's reason.
    missing_id = Ecto.UUID.generate()

    assert {:error, {:credential_resolution_failed, ^missing_id, _reason}} =
             ArmisNorthboundRunner.resolve_run_credentials(%{
               id: "7b1e9a2c-0000-4000-8000-000000000005",
               credential_secret_id: missing_id
             })
  end

  defp create_source!(actor, opts) do
    unique = System.unique_integer([:positive])
    agent_uid = "agent-armis-nb-#{unique}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register_connected, %{uid: agent_uid, name: agent_uid},
        actor: actor
      )
      |> Ash.create(actor: actor)

    defaults = %{
      name: "armis-nb-#{unique}",
      source_type: :armis,
      endpoint: "https://armis.example.test/#{unique}",
      agent_id: agent_uid,
      northbound_enabled: true,
      custom_fields: ["availability"]
    }

    attrs = Map.merge(defaults, Map.new(opts))

    IntegrationSource
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, source} -> source
      {:error, reason} -> raise "failed to create integration source: #{inspect(reason)}"
    end
  end
end
