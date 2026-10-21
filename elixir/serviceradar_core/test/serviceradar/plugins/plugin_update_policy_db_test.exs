defmodule ServiceRadar.Plugins.PluginUpdatePolicyDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PluginUpdatePolicyBackfillWorker
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  @partition_id "default"
  @third_party_repo_url "https://github.com/example-publisher/example-plugins"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    agent_uid = "update-policy-agent-#{unique}"
    register_control_session!(agent_uid)

    {:ok, unique: unique, agent_uid: agent_uid, builtin_repo_url: builtin_repo_url!(unique)}
  end

  test "a new owner defaults by package provenance", ctx do
    trusted = approved_package!(ctx, "trusted", :trusted)
    third_party = approved_package!(ctx, "third-party", :third_party)
    upload = approved_package!(ctx, "upload", :upload)

    assert %{update_policy: :track_latest_approved, update_policy_source: :operator} =
             manual_assignment!(ctx, trusted)

    assert %{update_policy: :pinned, update_policy_source: :operator} =
             manual_assignment!(ctx, upload)

    assert %{update_policy: :track_latest_approved, update_policy_source: :operator} =
             target_policy!(trusted)

    # Every catalog repository imports as source_type :first_party; only the
    # built-in repository is the first-party trust anchor.
    assert %{update_policy: :pinned, update_policy_source: :operator} =
             target_policy!(third_party)

    assert %{update_policy: :pinned, update_policy_source: :operator} =
             manual_assignment!(ctx, trusted, update_policy: :pinned, agent_suffix: "explicit")
  end

  test "an operator choosing a version or a policy is recorded as the operator's", ctx do
    current = approved_package!(ctx, "versions", :trusted, version: "1.0.0")
    newer = approved_package!(ctx, "versions", :trusted, version: "1.1.0", plugin?: false)

    assignment = manual_assignment!(ctx, current)
    policy = target_policy!(current)
    mark_migration_default!("plugin_assignments", assignment.id, "track_latest_approved")
    mark_migration_default!("plugin_target_policies", policy.id, "track_latest_approved")
    assignment = reload(PluginAssignment, assignment.id)
    policy = reload(PluginTargetPolicy, policy.id)

    # Re-submitting the current package is not a version choice.
    assert %{update_policy: :track_latest_approved, update_policy_source: :migration_default} =
             update!(policy, %{plugin_package_id: current.id, name: "Renamed"})

    newer_id = newer.id

    assert %{
             plugin_package_id: ^newer_id,
             update_policy: :pinned,
             update_policy_source: :operator
           } = update!(assignment, %{plugin_package_id: newer.id})

    assert %{update_policy: :pinned, update_policy_source: :operator} =
             update!(reload(PluginTargetPolicy, policy.id), %{plugin_package_id: newer.id})

    mark_migration_default!("plugin_target_policies", policy.id, "pinned")

    assert %{update_policy: :track_latest_approved, update_policy_source: :operator} =
             update!(reload(PluginTargetPolicy, policy.id), %{
               update_policy: :track_latest_approved
             })

    # The backfill commits after the operator's form loaded the row.
    stale = manual_assignment!(ctx, current, agent_suffix: "stale")
    mark_migration_default!("plugin_assignments", stale.id, "pinned")
    stale = reload(PluginAssignment, stale.id)
    mark_migration_default!("plugin_assignments", stale.id, "track_latest_approved")

    update!(stale, %{plugin_package_id: newer.id})

    assert policy_of(PluginAssignment, stale) == {:pinned, :operator}
  end

  test "a reconciler moving a policy-owned assignment records no operator choice", ctx do
    current = approved_package!(ctx, "policy-owned", :trusted, version: "1.0.0")
    newer = approved_package!(ctx, "policy-owned", :trusted, version: "1.1.0", plugin?: false)

    assignment =
      manual_assignment!(ctx, current,
        source: :policy,
        policy_id: "plugin-target-policy:#{ctx.unique}",
        source_key: "update-policy-#{ctx.unique}"
      )

    mark_migration_default!("plugin_assignments", assignment.id, "pinned")

    assert %{update_policy: :pinned, update_policy_source: :migration_default} =
             update!(reload(PluginAssignment, assignment.id), %{
               source: :policy,
               plugin_package_id: newer.id
             })
  end

  test "the backfill converts only first-party owners still on the migration default", ctx do
    trusted = approved_package!(ctx, "backfill-trusted", :trusted)
    upload = approved_package!(ctx, "backfill-upload", :upload)
    third_party = approved_package!(ctx, "backfill-third-party", :third_party)

    legacy_trusted = manual_assignment!(ctx, trusted)
    legacy_upload = manual_assignment!(ctx, upload)
    legacy_third_party = manual_assignment!(ctx, third_party)

    operator_pinned =
      manual_assignment!(ctx, trusted, update_policy: :pinned, agent_suffix: "pin")

    legacy_policy = target_policy!(trusted)
    operator_policy = target_policy!(trusted, update_policy: :pinned)

    for assignment <- [legacy_trusted, legacy_upload, legacy_third_party] do
      mark_migration_default!("plugin_assignments", assignment.id, "pinned")
    end

    mark_migration_default!("plugin_target_policies", legacy_policy.id, "pinned")

    PluginUpdatePolicyBackfillWorker.backfill_batch(Repo, 100)

    assert policy_of(PluginAssignment, legacy_trusted) ==
             {:track_latest_approved, :migration_default}

    assert policy_of(PluginAssignment, legacy_upload) == {:pinned, :migration_default}
    assert policy_of(PluginAssignment, legacy_third_party) == {:pinned, :migration_default}
    assert policy_of(PluginAssignment, operator_pinned) == {:pinned, :operator}

    assert policy_of(PluginTargetPolicy, legacy_policy) ==
             {:track_latest_approved, :migration_default}

    assert policy_of(PluginTargetPolicy, operator_policy) == {:pinned, :operator}

    # Converted rows are no longer candidates, so a second pass changes nothing.
    assert %{assignments: 0, target_policies: 0} =
             PluginUpdatePolicyBackfillWorker.backfill_batch(Repo, 100)
  end

  defp approved_package!(ctx, label, provenance, opts \\ []) do
    plugin_id = "update-policy-#{label}-#{ctx.unique}"
    version = Keyword.get(opts, :version, "1.0.0")

    if Keyword.get(opts, :plugin?, true) do
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Update Policy"},
        actor: admin()
      )
      |> Ash.create!()
    end

    manifest = %{
      "id" => plugin_id,
      "name" => "Update Policy",
      "version" => version,
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      }
    }

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          plugin_id: plugin_id,
          name: "Update Policy",
          version: version,
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}:#{version}"
        },
        provenance_attrs(provenance, ctx)
      ),
      actor: admin()
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: admin())
    |> Ash.update!()
  end

  defp provenance_attrs(:upload, _ctx), do: %{source_type: :upload, signature: %{}}

  defp provenance_attrs(:trusted, ctx), do: first_party_attrs(ctx.builtin_repo_url)
  defp provenance_attrs(:third_party, _ctx), do: first_party_attrs(@third_party_repo_url)

  defp first_party_attrs(repo_url) do
    %{
      source_type: :first_party,
      source_repo_url: repo_url,
      signature: %{"key_id" => "example-key", "signature" => "example-signature"},
      verification_status: "verified"
    }
  end

  defp manual_assignment!(ctx, package, opts \\ []) do
    {agent_suffix, opts} = Keyword.pop(opts, :agent_suffix)

    agent_uid =
      if agent_suffix do
        uid = "#{ctx.agent_uid}-#{agent_suffix}"
        register_control_session!(uid)
        uid
      else
        ctx.agent_uid
      end

    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{agent_uid: agent_uid, plugin_package_id: package.id}, Map.new(opts)),
      actor: admin()
    )
    |> Ash.create!()
  end

  defp target_policy!(package, opts \\ []) do
    PluginTargetPolicy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: "Update policy #{System.unique_integer([:positive])}",
          plugin_package_id: package.id
        },
        Map.new(opts)
      ),
      actor: admin()
    )
    |> Ash.create!()
  end

  defp update!(record, attrs) do
    record
    |> Ash.Changeset.for_update(:update, attrs, actor: admin())
    |> Ash.update!()
  end

  defp reload(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: admin())
  end

  defp policy_of(resource, record) do
    reloaded = reload(resource, record.id)
    {reloaded.update_policy, reloaded.update_policy_source}
  end

  # The state the migration leaves on rows that existed before it ran.
  defp mark_migration_default!(table, id, update_policy) do
    Repo.query!(
      """
      UPDATE platform.#{table}
      SET update_policy = $2, update_policy_source = 'migration_default'
      WHERE id = ($1::text)::uuid
      """,
      [id, update_policy]
    )
  end

  # The test's own built-in Wasm repository, so trust does not depend on the
  # seeded catalog rows surviving other tests.
  defp builtin_repo_url!(unique) do
    repo_url = "https://github.com/example-first-party/plugins-#{unique}"

    Repo.query!(
      """
      INSERT INTO platform.plugin_repositories
        (id, name, repo_url, artifact_kind, index_asset_name, signing_key_id,
         signing_public_key, enabled, builtin, is_default, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'Example first party', $1, 'wasm_plugin', 'index.json',
         'example-key', 'example-public-key', true, true, false, now(), now())
      """,
      [repo_url]
    )

    repo_url
  end

  defp register_control_session!(agent_uid) do
    ServiceRadar.TestSupport.register_agent_control_session!(agent_uid, @partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, @partition_id, agent_uid, node()})
    end)
  end

  defp admin do
    %{
      id: "00000000-0000-0000-0000-000000000001",
      email: "update-policy-test@example.com",
      role: :admin
    }
  end
end
