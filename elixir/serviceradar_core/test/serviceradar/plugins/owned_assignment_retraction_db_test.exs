defmodule ServiceRadar.Plugins.OwnedAssignmentRetractionDbTest do
  @moduledoc """
  An owner's lifecycle retracts the plugin assignments it materialized.

  The periodic reconcilers only load enabled credential rules and target
  policies, so an owner that is disabled, deleted, or narrowed is never
  reconciled again. These cases drive the owner's own Ash actions and read the
  assignment rows back. Assignment rows are inserted directly: the case is about
  what the owner action does to rows that already exist, however they got there.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.PluginCredentialRuleReconcileWorker
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Plugins.OwnedAssignmentRetraction
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PluginTargetPolicyReconcileWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  @system SystemActor.system(:owned_assignment_retraction_test)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])

    credential_operator =
      operator("credential-operator-#{unique}", ["settings.credentials.manage"])

    plugin_operator = operator("plugin-operator-#{unique}", ["settings.plugins.manage"])

    {:ok,
     unique: unique,
     package: package!("example-retraction-#{unique}"),
     credential_operator: credential_operator,
     plugin_operator: plugin_operator}
  end

  describe "credential rule lifecycle" do
    test "disabling a rule retracts its enabled assignments and records who and why", ctx do
      rule = rule!(ctx, scope_type: :partition, scope_value: "SITE01-#{ctx.unique}")
      inventory = assignment!(ctx, rule_policy_id(rule), "SITE01-#{ctx.unique}")
      check = assignment!(ctx, rule_policy_id(rule, "config_check"), "SITE01-#{ctx.unique}")

      rule
      |> Ash.Changeset.for_update(:disable, %{}, actor: ctx.credential_operator)
      |> Ash.update!()

      for id <- [inventory, check] do
        assert %{
                 enabled: false,
                 disabled_reason: "owner_disabled",
                 disabled_by: by,
                 disabled_at: at
               } =
                 assignment(id)

        assert by == ctx.credential_operator.id
        assert at
      end
    end

    test "deleting a rule retracts the enabled assignments it still owns", ctx do
      rule = rule!(ctx, scope_type: :partition, scope_value: "SITE01-#{ctx.unique}")
      # Left enabled by a disable that happened before the lifecycle retraction.
      set_enabled!("network_credential_rules", rule.id, false)
      id = assignment!(ctx, rule_policy_id(rule), "SITE01-#{ctx.unique}")

      assert :ok =
               rule.id
               |> stored_rule()
               |> NetworkCredentialRule.destroy_rule(actor: ctx.credential_operator)

      assert %{enabled: false, disabled_reason: "owner_deleted", disabled_by: by} = assignment(id)
      assert by == ctx.credential_operator.id
    end

    test "narrowing a rule's scope retracts only the agents it no longer covers", ctx do
      partition = "SITE01-#{ctx.unique}"
      rule = rule!(ctx, scope_type: :partition, scope_value: partition)
      kept_agent = "agent-kept-#{ctx.unique}"
      kept = assignment!(ctx, rule_policy_id(rule), partition, agent_uid: kept_agent)
      dropped = assignment!(ctx, rule_policy_id(rule), partition)

      rule
      |> Ash.Changeset.for_update(:update, %{scope_type: :agent, scope_value: kept_agent},
        actor: ctx.credential_operator
      )
      |> Ash.update!()

      assert %{enabled: true, disabled_reason: nil} = assignment(kept)

      assert %{enabled: false, disabled_reason: "owner_scope_narrowed", disabled_by: by} =
               assignment(dropped)

      assert by == ctx.credential_operator.id
    end
  end

  describe "target policy lifecycle" do
    test "disabling a policy retracts its enabled assignments and records who and why", ctx do
      policy = policy!(ctx, [])
      id = assignment!(ctx, to_string(policy.id), "SITE02-#{ctx.unique}")

      policy
      |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: ctx.plugin_operator)
      |> Ash.update!()

      assert %{enabled: false, disabled_reason: "owner_disabled", disabled_by: by} =
               assignment(id)

      assert by == ctx.plugin_operator.id
    end

    test "deleting a policy retracts its enabled assignments", ctx do
      policy = policy!(ctx, [])
      id = assignment!(ctx, to_string(policy.id), "SITE02-#{ctx.unique}")

      policy
      |> Ash.Changeset.for_destroy(:destroy, %{}, actor: ctx.plugin_operator)
      |> Ash.destroy!()

      assert %{enabled: false, disabled_reason: "owner_deleted", disabled_by: by} = assignment(id)
      assert by == ctx.plugin_operator.id
    end

    test "narrowing a policy's inputs retracts only the agents it no longer resolves", ctx do
      kept_agent = "agent-kept-#{ctx.unique}"
      dropped_agent = "agent-dropped-#{ctx.unique}"
      device!(kept_agent, "192.0.2.#{rem(ctx.unique, 254) + 1}")
      device!(dropped_agent, "198.51.100.#{rem(ctx.unique, 254) + 1}")

      policy = policy!(ctx, [agent_input(kept_agent), agent_input(dropped_agent)])
      kept = assignment!(ctx, to_string(policy.id), "SITE02-#{ctx.unique}", agent_uid: kept_agent)

      dropped =
        assignment!(ctx, to_string(policy.id), "SITE02-#{ctx.unique}", agent_uid: dropped_agent)

      policy
      |> Ash.Changeset.for_update(:update, %{input_definitions: [agent_input(kept_agent)]},
        actor: ctx.plugin_operator
      )
      |> Ash.update!()

      assert %{enabled: true, disabled_reason: nil} = assignment(kept)

      assert %{enabled: false, disabled_reason: "owner_scope_narrowed", disabled_by: by} =
               assignment(dropped)

      assert by == ctx.plugin_operator.id
    end
  end

  describe "pre-existing orphans" do
    setup ctx do
      partition = "SITE03-#{ctx.unique}"

      covered_rule = rule!(ctx, scope_type: :partition, scope_value: partition)
      disabled_rule = rule!(ctx, scope_type: :partition, scope_value: partition)
      narrowed_rule = rule!(ctx, scope_type: :agent, scope_value: "agent-elsewhere-#{ctx.unique}")
      live_policy = policy!(ctx, [])
      disabled_policy = policy!(ctx, [])

      # Orphaned before the lifecycle retraction existed: written straight to
      # the owner rows so no owner action runs.
      set_enabled!("network_credential_rules", disabled_rule.id, false)
      set_enabled!("plugin_target_policies", disabled_policy.id, false)

      orphans = %{
        missing_rule: assignment!(ctx, rule_policy_id(%{id: Ecto.UUID.generate()}), partition),
        disabled_rule: assignment!(ctx, rule_policy_id(disabled_rule), partition),
        narrowed_rule: assignment!(ctx, rule_policy_id(narrowed_rule), partition),
        missing_policy: assignment!(ctx, Ecto.UUID.generate(), partition),
        disabled_policy: assignment!(ctx, to_string(disabled_policy.id), partition)
      }

      healthy = %{
        covered_rule: assignment!(ctx, rule_policy_id(covered_rule), partition),
        live_policy: assignment!(ctx, to_string(live_policy.id), partition),
        other_reconciler: assignment!(ctx, "ansible:awx-inventory-sync", partition)
      }

      {:ok, orphans: orphans, healthy: healthy}
    end

    test "the orphan listing names each orphan's owner and its state", ctx do
      assert {:ok, listed} = OwnedAssignmentRetraction.list_orphaned_assignments()
      by_id = Map.new(listed, &{&1.assignment_id, &1})

      expected = %{
        missing_rule: {:credential_rule, :missing},
        disabled_rule: {:credential_rule, :disabled},
        narrowed_rule: {:credential_rule, :out_of_scope},
        missing_policy: {:plugin_target_policy, :missing},
        disabled_policy: {:plugin_target_policy, :disabled}
      }

      for {name, {kind, state}} <- expected do
        id = Map.fetch!(ctx.orphans, name)
        assert %{owner_kind: ^kind, owner_state: ^state} = Map.fetch!(by_id, id), inspect(name)
        assert by_id[id].package_name == ctx.package.name
      end

      for {name, id} <- ctx.healthy, do: refute(Map.has_key?(by_id, id), inspect(name))
    end

    test "cleanup retracts the selected orphans and leaves everything else alone", ctx do
      selected = [ctx.orphans.missing_rule, ctx.orphans.disabled_policy, ctx.healthy.covered_rule]

      assert {:ok, %{retracted: 2}} =
               OwnedAssignmentRetraction.retract_orphaned_assignments(
                 selected,
                 ctx.plugin_operator
               )

      for id <- [ctx.orphans.missing_rule, ctx.orphans.disabled_policy] do
        assert %{enabled: false, disabled_reason: "orphaned_owner_cleanup", disabled_by: by} =
                 assignment(id)

        assert by == ctx.plugin_operator.id
      end

      assert %{enabled: true} = assignment(ctx.healthy.covered_rule)
      assert %{enabled: true} = assignment(ctx.orphans.disabled_rule)
    end

    test "cleanup needs permission to manage plugins", ctx do
      assert {:error, _forbidden} =
               OwnedAssignmentRetraction.retract_orphaned_assignments(
                 :all,
                 ctx.credential_operator
               )

      for {_name, id} <- ctx.orphans, do: assert(%{enabled: true} = assignment(id))
    end

    test "no periodic reconcile disables an orphan", ctx do
      assert :ok = PluginTargetPolicyReconcileWorker.perform(%Oban.Job{args: %{}})
      assert :ok = PluginCredentialRuleReconcileWorker.perform(%Oban.Job{args: %{}})

      for {name, id} <- ctx.orphans do
        assert %{enabled: true, disabled_reason: nil} = assignment(id), inspect(name)
      end
    end
  end

  defp operator(id_prefix, permissions) do
    %{
      id: "#{id_prefix}-#{Ecto.UUID.generate()}",
      email: "#{id_prefix}@example.com",
      role: :operator,
      permissions: MapSet.new(permissions)
    }
  end

  defp package!(plugin_id) do
    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example Retraction"},
      actor: @system
    )
    |> Ash.create!()

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Example Retraction",
        version: "1.0.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: %{
          "id" => plugin_id,
          "name" => "Example Retraction",
          "version" => "1.0.0",
          "entrypoint" => "run_check",
          "runtime" => "wasi-preview1",
          "outputs" => "serviceradar.plugin_result.v1",
          "capabilities" => ["submit_result"],
          "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 100}
        },
        config_schema: %{},
        display_contract: %{},
        content_hash: "sha256:#{plugin_id}:1.0.0",
        signature: %{},
        source_type: :upload
      },
      actor: @system
    )
    |> Ash.create!()
  end

  defp rule!(ctx, attrs) do
    secret = CredentialIntegrationFixtures.secret!(actor: @system)

    defaults = %{
      name: "example-rule-#{System.unique_integer([:positive])}",
      provider: "example-network",
      auth_method: "api_token",
      purpose: "inventory",
      target_query: "in:devices",
      secret_id: secret.id
    }

    {:ok, rule} =
      NetworkCredentialRule.create_rule(Map.merge(defaults, Map.new(attrs)),
        actor: ctx.credential_operator
      )

    rule
  end

  defp stored_rule(id) do
    {:ok, rule} = NetworkCredentialRule.get_by_id(id, actor: @system)
    rule
  end

  defp policy!(ctx, input_definitions) do
    PluginTargetPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "example-policy-#{System.unique_integer([:positive])}",
        plugin_package_id: ctx.package.id,
        input_definitions: input_definitions,
        params_template: %{},
        enabled: true
      },
      actor: ctx.plugin_operator
    )
    |> Ash.create!()
  end

  defp agent_input(agent_uid) do
    %{"name" => agent_uid, "entity" => "devices", "query" => "in:devices agent_id:#{agent_uid}"}
  end

  defp device!(agent_uid, ip) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "example-device-#{agent_uid}",
      hostname: "host-#{agent_uid}.example.com",
      ip: ip,
      agent_id: agent_uid
    })
    |> Ash.create!(actor: @system)
  end

  defp rule_policy_id(rule, purpose \\ nil)
  defp rule_policy_id(rule, nil), do: "network-credential-rule:#{rule.id}"
  defp rule_policy_id(rule, purpose), do: "network-credential-rule:#{rule.id}:#{purpose}"

  defp assignment!(ctx, policy_id, partition_id, opts \\ []) do
    agent_uid = Keyword.get(opts, :agent_uid, "agent-#{System.unique_integer([:positive])}")
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO platform.plugin_assignments
        (id, agent_uid, partition_id, plugin_package_id, plugin_id, source, source_key, policy_id, enabled)
      VALUES ($1::text::uuid, $2, $3, $4::text::uuid, $5, 'policy', $6, $7, true)
      """,
      [
        id,
        agent_uid,
        partition_id,
        to_string(ctx.package.id),
        ctx.package.plugin_id,
        "example-source-key-#{id}",
        policy_id
      ]
    )

    id
  end

  defp assignment(id) do
    %{rows: [[enabled, reason, by, at]]} =
      Repo.query!(
        """
        SELECT enabled, disabled_reason, disabled_by, disabled_at
        FROM platform.plugin_assignments WHERE id = $1::text::uuid
        """,
        [id]
      )

    %{enabled: enabled, disabled_reason: reason, disabled_by: by, disabled_at: at}
  end

  defp set_enabled!(table, id, enabled) do
    Repo.query!("UPDATE platform.#{table} SET enabled = $2 WHERE id = $1::text::uuid", [
      to_string(id),
      enabled
    ])
  end
end
