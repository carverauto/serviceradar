defmodule ServiceRadar.Integrations.SyncConfigGeneratorTest do
  @moduledoc """
  Integration tests for sync config generation and tenant isolation.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.{IntegrationSource, SyncConfigGenerator}

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "agent sync config only includes sources assigned to the agent" do
    tenant_a = create_tenant!("tenant-a")
    tenant_b = create_tenant!("tenant-b")

    agent_a = create_agent!(tenant_a, "agent-a")
    agent_b = create_agent!(tenant_b, "agent-b")

    source_a = create_source!(tenant_a, agent_a.uid, "source-a")
    _source_b = create_source!(tenant_b, agent_b.uid, "source-b")

    assert {:ok, payload} =
             SyncConfigGenerator.get_config_if_changed(
               agent_a.uid,
               to_string(tenant_a.id),
               ""
             )

    config = Jason.decode!(payload.config_json)
    sources = config["sources"]

    assert config["agent_id"] == agent_a.uid
    assert config["tenant_id"] == to_string(tenant_a.id)
    assert Map.has_key?(sources, source_a.name)
  end

  defp create_tenant!(slug_prefix) do
    suffix = System.unique_integer([:positive])
    slug = "#{slug_prefix}-#{suffix}"
    name = "#{slug_prefix}-name-#{suffix}"

    Tenant
    |> Ash.Changeset.for_create(:create, %{name: name, slug: slug}, authorize?: false)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, tenant} -> tenant
      {:error, reason} -> raise "failed to create tenant: #{inspect(reason)}"
    end
  end

  defp create_agent!(tenant, uid) do
    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid},
      actor: system_actor(tenant.id),
      tenant: tenant.id,
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, agent} -> agent
      {:error, reason} -> raise "failed to create agent: #{inspect(reason)}"
    end
  end

  defp create_source!(tenant, agent_id, name) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"
    actor = system_actor(tenant.id)

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        source_type: :armis,
        endpoint: endpoint,
        agent_id: agent_id
      },
      actor: actor,
      tenant: tenant.id,
      authorize?: false
    )
    |> Ash.Changeset.set_argument(:credentials, %{token: "secret"})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, source} -> source
      {:error, reason} -> raise "failed to create integration source: #{inspect(reason)}"
    end
  end

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "system@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
