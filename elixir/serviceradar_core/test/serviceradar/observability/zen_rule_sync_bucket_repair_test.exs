defmodule ServiceRadar.Observability.ZenRuleSyncBucketRepairTest do
  @moduledoc """
  Reconcile rewrites the rule bucket bundle of a subject that has lost its last
  enabled rule, so a bundle left behind by a failed bucket write does not keep
  the removed rule in force for collectors. Runs against a real database and a
  disposable nats-server.
  """
  use ServiceRadar.DataCase, async: false

  alias Gnat.Jetstream.API.KV
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.Zen.RuleBucket
  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.ZenRuleSync
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @subject "logs.syslog"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    original = Application.get_env(:serviceradar_core, RuleBucket)
    Application.put_env(:serviceradar_core, RuleBucket, max_bytes: 1_048_576, replicas: 1)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:serviceradar_core, RuleBucket),
        else: Application.put_env(:serviceradar_core, RuleBucket, original)
    end)

    stream = "repair-#{System.unique_integer([:positive])}"

    {:ok,
     actor: SystemActor.system(:test),
     stream: stream,
     key: "zen/rulesets/#{stream}/#{@subject}.json"}
  end

  test "a subject whose only rule was disabled gets the bundle without it", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      rule = create_rule!(ctx)
      leave_stale_bundle(conn, ctx, rule)

      {:ok, _disabled} =
        rule
        |> Ash.Changeset.for_update(:update, %{enabled: false},
          actor: ctx.actor,
          context: %{skip_zen_sync: true}
        )
        |> Ash.update()

      assert :ok = ZenRuleSync.reconcile_stores(actor: ctx.actor)

      assert_empty_bundle(conn, ctx)
    end)
  end

  test "a subject whose only rule was destroyed gets the bundle without it", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      rule = create_rule!(ctx)
      leave_stale_bundle(conn, ctx, rule)

      :ok =
        rule
        |> Ash.Changeset.for_destroy(:destroy, %{},
          actor: ctx.actor,
          context: %{skip_zen_sync: true}
        )
        |> Ash.destroy()

      assert :ok = ZenRuleSync.reconcile_stores(actor: ctx.actor)

      assert_empty_bundle(conn, ctx)
    end)
  end

  defp create_rule!(ctx) do
    ZenRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "repair-" <> Ash.UUID.generate(),
        stream_name: ctx.stream,
        subject: @subject,
        template: "passthrough"
      },
      actor: ctx.actor,
      context: %{skip_zen_sync: true}
    )
    |> Ash.create!()
  end

  # The bundle an earlier sync published while the rule was enabled; the write
  # that should have replaced it never reached the bucket.
  defp leave_stale_bundle(conn, ctx, rule) do
    assert :ok = RuleBucket.ensure()

    stale =
      Jason.encode!(%{
        "schema" => "serviceradar.zen.ruleset.v1",
        "stream_name" => ctx.stream,
        "subject" => @subject,
        "rules" => [%{"key" => rule.name, "jdm" => ~s({"nodes":[],"edges":[]})}],
        "digest" => "sha256:stale"
      })

    assert :ok = RuleBucket.put(ctx.key, stale)
    assert KV.get_value(conn, RuleBucket.bucket(), ctx.key) == stale
  end

  defp assert_empty_bundle(conn, ctx) do
    bundle = conn |> KV.get_value(RuleBucket.bucket(), ctx.key) |> Jason.decode!()

    assert bundle["stream_name"] == ctx.stream
    assert bundle["subject"] == @subject
    assert bundle["rules"] == []
    refute bundle["digest"] == "sha256:stale"
  end
end
