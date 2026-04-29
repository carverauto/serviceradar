defmodule ServiceRadar.Observability.ZenRuleTest do
  use ExUnit.Case, async: false

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.ZenRuleSync
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    # Schema determined by DB connection's search_path
    actor = SystemActor.system(:test)

    {:ok, actor: actor}
  end

  test "compiles rule and derives format from subject", %{actor: actor} do
    syslog_name = "syslog-pass-" <> Ash.UUID.generate()
    otel_name = "otel-pass-" <> Ash.UUID.generate()

    {:ok, rule} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: syslog_name,
          subject: "logs.syslog",
          template: "passthrough"
        },
        actor: actor,
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
          name: otel_name,
          subject: "logs.otel",
          template: "passthrough"
        },
        actor: actor,
        context: %{skip_zen_sync: true}
      )
      |> Ash.create()

    assert otel_rule.format == :protobuf
  end

  test "rejects invalid name or subject", %{actor: actor} do
    {:error, %Invalid{errors: errors}} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Bad Name",
          subject: "logs.syslog",
          template: "passthrough"
        },
        actor: actor,
        context: %{skip_zen_sync: true}
      )
      |> Ash.create()

    assert Enum.any?(errors, &(&1.field == :name))

    {:error, %Invalid{errors: errors}} =
      ZenRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "valid-name-" <> Ash.UUID.generate(),
          subject: "logs.bad",
          template: "passthrough"
        },
        actor: actor,
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
