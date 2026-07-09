defmodule ServiceRadar.Integrations.SyncConfigGeneratorTest do
  @moduledoc """
  Integration tests for sync config generation.

  In single-deployment architecture, schema isolation is handled
  by PostgreSQL search_path. Tests run against the single schema.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Credentials.NetworkCredentialSecret
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
        nil,
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

  defp system_actor do
    # DB connection's search_path determines the schema
    %{
      id: "system",
      email: "system@serviceradar",
      role: :admin
    }
  end
end
