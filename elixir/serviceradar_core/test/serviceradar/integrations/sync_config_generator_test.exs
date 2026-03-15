defmodule ServiceRadar.Integrations.SyncConfigGeneratorTest do
  @moduledoc """
  Integration tests for sync config generation.

  In single-deployment architecture, schema isolation is handled
  by PostgreSQL search_path. Tests run against the single schema.
  """

  use ExUnit.Case, async: false

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
    agent_a = create_agent!("agent-a")
    agent_b = create_agent!("agent-b")

    source_a = create_source!(agent_a.uid, "source-a")
    _source_b = create_source!(agent_b.uid, "source-b")

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

  defp create_source!(agent_id, name) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"
    actor = system_actor()

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        source_type: :armis,
        endpoint: endpoint,
        agent_id: agent_id
      },
      actor: actor
    )
    |> Ash.Changeset.set_argument(:credentials, %{token: "secret"})
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
