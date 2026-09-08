defmodule ServiceRadar.Integrations.SyncConfigGeneratorTest do
  @moduledoc """
  Integration tests for sync config generation.

  In single-deployment architecture, schema isolation is handled
  by PostgreSQL search_path. Tests run against the single schema.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.SyncConfigGenerator

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "agent sync config only includes sources assigned to the agent" do
    # In single-deployment mode, schema context is implicit from DB connection's search_path
    suffix = System.unique_integer([:positive])
    agent_a = create_agent!("agent-a-#{suffix}")
    agent_b = create_agent!("agent-b-#{suffix}")

    source_a = create_source!(agent_a.uid, "source-a-#{suffix}")
    _source_b = create_source!(agent_b.uid, "source-b-#{suffix}")

    assert {:ok, payload} =
             SyncConfigGenerator.get_config_if_changed(
               agent_a.uid,
               ""
             )

    config = Jason.decode!(payload.config_json)
    sources = config["sources"]

    assert config["agent_id"] == agent_a.uid
    assert Map.has_key?(sources, source_a.name)
  end

  test "armis sync config emits secret_key from stored api_secret" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-secret-key-#{suffix}")

    source =
      create_source!(agent.uid, "source-armis-secret-key-#{suffix}", %{
        api_key: "api-key",
        api_secret: "api-secret"
      })

    assert {:ok, payload} = SyncConfigGenerator.get_config_if_changed(agent.uid, "")

    credentials =
      payload.config_json
      |> Jason.decode!()
      |> get_in(["sources", source.name, "credentials"])

    assert credentials["api_key"] == "api-key"
    assert credentials["api_secret"] == "api-secret"
    assert credentials["secret_key"] == "api-secret"
  end

  test "armis sync config resolves structured credentials through broker reference" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-broker-#{suffix}")

    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "armis-broker-secret-#{suffix}",
          provider: "armis",
          credential_kind: :opaque,
          secret_payload:
            Jason.encode!(%{"api_key" => "broker-key", "api_secret" => "broker-secret"})
        },
        actor: system_actor()
      )
      |> Ash.create(actor: system_actor())

    source =
      create_source!(
        agent.uid,
        "source-armis-broker-#{suffix}",
        %{api_key: "legacy-key", api_secret: "legacy-secret"},
        %{credential_secret_id: secret.id}
      )

    assert {:ok, payload} = SyncConfigGenerator.get_config_if_changed(agent.uid, "")

    credentials =
      payload.config_json
      |> Jason.decode!()
      |> get_in(["sources", source.name, "credentials"])

    assert credentials["api_key"] == "broker-key"
    assert credentials["api_secret"] == "broker-secret"
    assert credentials["secret_key"] == "broker-secret"
  end

  test "armis sync config rejects external references instead of falling back to plaintext" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-external-broker-#{suffix}")
    provider = create_stub_provider!(suffix)

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "armis-external-broker-secret-#{suffix}",
          provider: "stub",
          credential_kind: :opaque,
          source_type: :external_reference,
          secret_provider_id: provider.id,
          external_secret_ref: "stub/armis/#{suffix}",
          resolution_location: :control_plane,
          metadata: %{
            "stub_secret_value" =>
              Jason.encode!(%{
                "api_key" => "external-key",
                "api_secret" => "external-secret"
              })
          }
        },
        actor: SystemActor.system(:sync_config_generator_test)
      )

    source =
      create_source!(
        agent.uid,
        "source-armis-external-broker-#{suffix}",
        %{api_key: "legacy-key", api_secret: "legacy-secret"},
        %{credential_secret_id: secret.id}
      )

    assert {:error,
            {:credential_resolution_failed, source_id, :external_secret_requires_broker_grant}} =
             SyncConfigGenerator.build_payload(agent.uid)

    assert source_id == to_string(source.id)

    assert {:error, {:database_error, %RuntimeError{message: message}}} =
             AgentConfigGenerator.generate_config(agent.uid, "default")

    assert message =~ "failed to load integration config"
    assert message =~ to_string(source.id)
  end

  test "broker credentials must decode to a nonempty JSON object" do
    suffix = System.unique_integer([:positive])

    for {label, secret_payload} <- [malformed: "not-json", list: "[]", empty_object: "{}"] do
      agent = create_agent!("agent-armis-invalid-#{label}-#{suffix}")

      {:ok, secret} =
        NetworkCredentialSecret.create_secret(
          %{
            name: "armis-invalid-#{label}-#{suffix}",
            provider: "armis",
            credential_kind: :opaque,
            secret_payload: secret_payload
          },
          actor: SystemActor.system(:sync_config_generator_test)
        )

      source =
        create_source!(
          agent.uid,
          "source-armis-invalid-#{label}-#{suffix}",
          %{api_key: "legacy-key"},
          %{credential_secret_id: secret.id}
        )

      assert {:error, {:credential_resolution_failed, source_id, :invalid_credentials_payload}} =
               SyncConfigGenerator.build_payload(agent.uid)

      assert source_id == to_string(source.id)
    end
  end

  test "missing encrypted broker payload fails closed" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-missing-broker-#{suffix}")

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "armis-missing-broker-secret-#{suffix}",
          provider: "armis",
          credential_kind: :opaque
        },
        actor: SystemActor.system(:sync_config_generator_test)
      )

    source =
      create_source!(
        agent.uid,
        "source-armis-missing-broker-#{suffix}",
        %{api_key: "legacy-key"},
        %{credential_secret_id: secret.id}
      )

    assert {:error, {:credential_resolution_failed, source_id, :missing_internal_secret_payload}} =
             SyncConfigGenerator.build_payload(agent.uid)

    assert source_id == to_string(source.id)
  end

  test "broker audit uses discovery scope and the requesting agent" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-audit-#{suffix}")

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "armis-audit-secret-#{suffix}",
          provider: "armis",
          credential_kind: :opaque,
          secret_payload: Jason.encode!(%{"api_key" => "broker-key"})
        },
        actor: SystemActor.system(:sync_config_generator_test)
      )

    source =
      create_source!(agent.uid, "source-armis-audit-#{suffix}", nil, %{
        credential_secret_id: secret.id
      })

    test_pid = self()
    audit_sink = fn attrs -> send(test_pid, {:credential_audit, attrs}) end

    assert {:ok, _payload} =
             SyncConfigGenerator.build_payload(agent.uid, audit_sink: audit_sink)

    assert_receive {:credential_audit, audit}
    assert audit.consumer_kind == :discovery
    assert audit.consumer_id == "integration_source:#{source.id}"
    assert audit.agent_id == agent.uid
    assert audit.target_id == to_string(source.id)
    assert audit.outcome == :success
  end

  test "armis sync config emits discovery cadence without poll or sweep cadence" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-discovery-interval-#{suffix}")

    source =
      create_source!(
        agent.uid,
        "source-armis-discovery-interval-#{suffix}",
        %{secret_key: "secret"},
        %{
          discovery_interval_seconds: 7200,
          poll_interval_seconds: 300,
          sweep_interval_seconds: 600
        }
      )

    assert {:ok, payload} = SyncConfigGenerator.get_config_if_changed(agent.uid, "")

    source_config =
      payload.config_json
      |> Jason.decode!()
      |> get_in(["sources", source.name])

    assert source_config["discovery_interval"] == "2h"
    refute Map.has_key?(source_config, "poll_interval")
    refute Map.has_key?(source_config, "sweep_interval")
  end

  test "armis sync config emits non-secret source settings for asset metadata" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-settings-#{suffix}")

    source =
      create_source!(
        agent.uid,
        "source-armis-settings-#{suffix}",
        %{secret_key: "secret", client_id: "client", client_secret: "client-secret"},
        %{
          settings: %{
            "asset_fields" => ["accessSwitch", "VLAN"],
            "extra_metadata_fields" => ["customAccessPort"],
            "v3_endpoint" => "https://api.armis.example",
            "batch_size" => 500,
            "secret_like_value" => "do-not-emit"
          }
        }
      )

    assert {:ok, payload} = SyncConfigGenerator.get_config_if_changed(agent.uid, "")

    source_config =
      payload.config_json
      |> Jason.decode!()
      |> get_in(["sources", source.name])

    assert source_config["settings"] == %{
             "asset_fields" => ["accessSwitch", "VLAN"],
             "extra_metadata_fields" => ["customAccessPort"],
             "v3_endpoint" => "https://api.armis.example"
           }

    assert source_config["batch_size"] == 500
    refute Map.has_key?(source_config["settings"], "secret_like_value")
    refute Map.has_key?(source_config["settings"], "batch_size")
    assert source_config["credentials"]["client_secret"] == "client-secret"
  end

  test "armis sync config emits configured queries with normalized string keys" do
    suffix = System.unique_integer([:positive])
    agent = create_agent!("agent-armis-queries-#{suffix}")

    source =
      create_source!(
        agent.uid,
        "source-armis-queries-#{suffix}",
        %{secret_key: "secret"},
        %{
          queries: [
            %{
              label: "network",
              query: " in:devices and ipAddress:10.0.0.0/8 ",
              sweep_modes: [:icmp]
            },
            %{
              "label" => "ot",
              "query" => "in:devices and category:OT",
              "sweep_modes" => ["tcp"]
            },
            %{"label" => "blank", "query" => "   "}
          ]
        }
      )

    assert {:ok, payload} = SyncConfigGenerator.get_config_if_changed(agent.uid, "")

    queries =
      payload.config_json
      |> Jason.decode!()
      |> get_in(["sources", source.name, "queries"])

    assert queries == [
             %{
               "label" => "network",
               "query" => "in:devices and ipAddress:10.0.0.0/8",
               "sweep_modes" => ["icmp"]
             },
             %{
               "label" => "ot",
               "query" => "in:devices and category:OT",
               "sweep_modes" => ["tcp"]
             }
           ]
  end

  defp create_agent!(uid) do
    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid},
      actor: system_actor()
    )
    |> Ash.create(actor: system_actor())
    |> case do
      {:ok, agent} -> agent
      {:error, reason} -> raise "failed to create agent: #{inspect(reason)}"
    end
  end

  defp create_source!(agent_id, name, credentials \\ %{token: "secret"}, overrides \\ %{}) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"
    actor = system_actor()

    attrs =
      Map.merge(
        %{
          name: name,
          source_type: :armis,
          endpoint: endpoint,
          agent_id: agent_id,
          credentials: credentials
        },
        overrides
      )

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      attrs,
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, source} -> source
      {:error, reason} -> raise "failed to create integration source: #{inspect(reason)}"
    end
  end

  defp create_stub_provider!(suffix) do
    actor = SystemActor.system(:sync_config_generator_test)

    {:ok, provider} =
      CredentialSecretProvider.create_provider(
        %{
          name: "sync-config-stub-provider-#{suffix}",
          provider_type: :stub,
          resolution_locations: [:control_plane]
        },
        actor: actor
      )

    {:ok, provider} = CredentialSecretProvider.enable(provider, actor: actor)
    provider
  end

  defp system_actor do
    # DB connection's search_path determines the schema
    %{
      id: "system",
      email: "system@serviceradar",
      role: :admin
    }
  end
end
