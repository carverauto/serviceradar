defmodule ServiceRadar.Observability.ZenRuleTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Observability.{ZenRule, ZenRuleSync}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    tenant = TestSupport.create_tenant_schema!("zen-rule")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    schema = TenantSchemas.schema_for_id(tenant.tenant_id)
    actor = %{id: "system", role: :admin, tenant_id: tenant.tenant_id}

    {:ok, tenant: tenant, schema: schema, actor: actor}
  end

  test "compiles rule and derives format from subject", %{schema: schema, actor: actor} do
    {:ok, rule} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "syslog-pass",
          subject: "logs.syslog",
          template: :passthrough
        },
        actor: actor,
        tenant: schema,
        context: %{skip_zen_sync: true}
      )
      |> Ash.create()

    assert rule.format == :json
    assert Map.has_key?(rule.compiled_jdm, "nodes")

    {:ok, otel_rule} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "otel-pass",
          subject: "logs.otel",
          template: :passthrough
        },
        actor: actor,
        tenant: schema,
        context: %{skip_zen_sync: true}
      )
      |> Ash.create()

    assert otel_rule.format == :protobuf
  end

  test "rejects invalid name or subject", %{schema: schema, actor: actor} do
    {:error, %Ash.Error.Invalid{errors: errors}} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Bad Name",
          subject: "logs.syslog",
          template: :passthrough
        },
        actor: actor,
        tenant: schema,
        context: %{skip_zen_sync: true}
      )
      |> Ash.create()

    assert Enum.any?(errors, &(&1.field == :name))

    {:error, %Ash.Error.Invalid{errors: errors}} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "valid-name",
          subject: "logs.bad",
          template: :passthrough
        },
        actor: actor,
        tenant: schema,
        context: %{skip_zen_sync: true}
      )
      |> Ash.create()

    assert Enum.any?(errors, &(&1.field == :subject))
  end

  test "builds KV key for sync" do
    rule = %ZenRule{
      agent_id: "agent-1",
      stream_name: "events",
      subject: "logs.syslog",
      name: "syslog-clean"
    }

    assert ZenRuleSync.kv_key(rule) == "agents/agent-1/events/logs.syslog/syslog-clean.json"
  end
end
