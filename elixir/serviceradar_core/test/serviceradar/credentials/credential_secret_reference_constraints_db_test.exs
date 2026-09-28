defmodule ServiceRadar.Credentials.CredentialSecretReferenceConstraintsDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.NetworkCredentialSecretBinding
  alias ServiceRadar.Credentials.NetworkCredentialSecretDeletionAudit
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.GuardNetworkCredentialSecretDeletion, as: Migration

  require Ash.Query

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260830220000_guard_network_credential_secret_deletion.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  @moduletag :integration
  @partition_id "credential-reference-constraints"

  Code.require_file(@migration_path)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    secret = secret_fixture()
    on_exit(&unregister_fixture_sessions/0)
    {:ok, secret: secret}
  end

  test "a JSON credential reference creates a restrictive binding", %{secret: secret} do
    assignment =
      plugin_assignment_fixture(%{
        params: %{"credential" => SecretRefs.network_credential_ref(secret.id)}
      })

    assert [%{secret_id: id, owner_kind: :plugin_assignment, owner_id: owner_id}] =
             bindings_for(secret.id)

    assert id == secret.id
    assert owner_id == to_string(assignment.id)

    assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
             delete_secret_row(secret.id)

    assert constraint == "network_credential_secret_bindings_secret_id_fkey"
  end

  test "removing an owner removes its binding", %{secret: secret} do
    assignment =
      plugin_assignment_fixture(%{
        params: %{"credential" => SecretRefs.network_credential_ref(secret.id)}
      })

    assert [_binding] = bindings_for(secret.id)

    assert :ok =
             assignment
             |> Ash.Changeset.for_destroy(:destroy, %{}, actor: system_actor())
             |> Ash.destroy!()

    assert [] = bindings_for(secret.id)
  end

  test "nested and array credential references are indexed and stale bindings are replaced", %{
    secret: secret
  } do
    replacement = secret_fixture()

    assignment =
      plugin_assignment_fixture(%{
        params: %{
          "credentials" => [
            SecretRefs.network_credential_ref(secret.id),
            %{"nested" => SecretRefs.network_credential_ref(secret.id)}
          ],
          "replacement" => SecretRefs.network_credential_ref(replacement.id)
        }
      })

    assert binding_paths(secret.id) == [
             "$.params.k:63726564656e7469616c73.i:0",
             "$.params.k:63726564656e7469616c73.i:1.k:6e6573746564"
           ]

    assert binding_paths(replacement.id) == ["$.params.k:7265706c6163656d656e74"]

    assignment
    |> Ash.Changeset.for_update(
      :update,
      %{params: %{"replacement" => SecretRefs.network_credential_ref(replacement.id)}},
      actor: system_actor()
    )
    |> Ash.update!()

    assert [] == bindings_for(secret.id)
    assert binding_paths(replacement.id) == ["$.params.k:7265706c6163656d656e74"]
  end

  test "field paths distinguish dotted and numeric object keys from nesting and array indexes", %{
    secret: secret
  } do
    other = secret_fixture()

    plugin_assignment_fixture(%{
      params: %{
        "a.b" => SecretRefs.network_credential_ref(secret.id),
        "a" => %{"b" => SecretRefs.network_credential_ref(secret.id)},
        "0" => SecretRefs.network_credential_ref(other.id),
        "array" => [SecretRefs.network_credential_ref(other.id)]
      }
    })

    assert binding_paths(secret.id) == [
             "$.params.k:61.k:62",
             "$.params.k:612e62"
           ]

    assert binding_paths(other.id) == [
             "$.params.k:30",
             "$.params.k:6172726179.i:0"
           ]
  end

  test "owner-table triggers bind only notification, producer, and policy credential fields", %{
    secret: secret
  } do
    ref = SecretRefs.network_credential_ref(secret.id)

    # A plugin assignment binds only credential references inside `params`: a
    # plain string there, or a reference in any other column, binds nothing.
    assignment =
      plugin_assignment_fixture(%{
        params: %{"endpoint" => "https://example.test"},
        permissions_override: %{"unrelated" => ref}
      })

    assert assignment.permissions_override["unrelated"] == ref

    %{rows: [[package_id]]} =
      SQL.query!(
        Repo,
        "SELECT plugin_package_id FROM platform.plugin_assignments WHERE id = $1",
        [
          Ecto.UUID.dump!(assignment.id)
        ]
      )

    provider_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      "INSERT INTO platform.notification_providers (id, provider_key, provider_type, display_name) VALUES ($1, $2, 'builtin', 'test')",
      [Ecto.UUID.dump!(provider_id), "trigger-test-#{System.unique_integer([:positive])}"]
    )

    SQL.query!(
      Repo,
      "INSERT INTO platform.notification_channels (id, name, provider_id, secret_refs, config, last_error, metadata) VALUES ($1, $2, $3, $4::jsonb, $5::jsonb, $6, $5::jsonb)",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "trigger-channel-#{System.unique_integer([:positive])}",
        Ecto.UUID.dump!(provider_id),
        %{"token" => ref},
        %{"ignored" => ref},
        ref
      ]
    )

    SQL.query!(
      Repo,
      "INSERT INTO platform.producer_schedules (id, producer_kind, plugin_package_id, schedule_id, display_name, credential_refs, params, last_error, metadata) VALUES ($1, 'wasm_plugin', $2, $3, 'test', $4::jsonb, $5::jsonb, $6, $7::jsonb)",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        package_id,
        "trigger-schedule-#{System.unique_integer([:positive])}",
        %{"credential" => ref},
        %{"param" => ref},
        ref,
        %{"ignored" => ref}
      ]
    )

    SQL.query!(
      Repo,
      "INSERT INTO platform.plugin_target_policies (id, name, plugin_package_id, params_template) VALUES ($1, $2, $3, $4::jsonb)",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "trigger-policy-#{System.unique_integer([:positive])}",
        package_id,
        %{"token" => ref}
      ]
    )

    assert [] =
             NetworkCredentialSecretBinding
             |> Ash.Query.filter(
               owner_kind == :plugin_assignment and owner_id == ^to_string(assignment.id)
             )
             |> Ash.read!(actor: system_actor())

    # Only the credential column of each owner binds; `config`, `metadata` and
    # `last_error` carry the same reference and must not.
    bindings =
      secret.id
      |> bindings_for()
      |> Enum.map(&{&1.owner_kind, &1.field_path})
      |> Enum.sort()

    assert bindings == [
             {:notification_channel, "$.secret_refs.k:746f6b656e"},
             {:plugin_target_policy, "$.params_template.k:746f6b656e"},
             {:producer_schedule, "$.credential_refs.k:63726564656e7469616c"},
             {:producer_schedule, "$.params.k:706172616d"}
           ]
  end

  test "a malformed network credential reference is rejected by the owner trigger" do
    assignment = plugin_assignment_fixture(%{params: %{}})

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             SQL.query(
               Repo,
               "UPDATE platform.plugin_assignments SET params = jsonb_build_object('credential', $1::text) WHERE id = $2",
               [
                 "credentialref:network-credential-secret:not-a-uuid",
                 Ecto.UUID.dump!(assignment.id)
               ]
             )

    assert message =~ "invalid network credential reference"

    # The vulnerability-feed owner trims before it checks, and still rejects.
    assert {:error, error} =
             VulnerabilityFeedDefinition
             |> Ash.Changeset.for_create(
               :upsert,
               %{
                 provider: "credential-reference-invalid-#{System.unique_integer([:positive])}",
                 feed_key: "feed-#{System.unique_integer([:positive])}",
                 display_name: "Credential reference constraints feed",
                 feed_type: "test",
                 credential_ref: "  credentialref:network-credential-secret:not-a-uuid  "
               },
               actor: system_actor()
             )
             |> Ash.create()

    assert Exception.message(error) =~ "invalid network credential reference"
  end

  test "bare, canonical, and trimmed uppercase feed references bind restrictively" do
    for ref_for <- [
          &to_string/1,
          fn id -> "  #{String.upcase(id)}  " end,
          &SecretRefs.network_credential_ref/1,
          fn id -> "  credentialref:network-credential-secret:#{String.upcase(id)}  " end
        ] do
      secret = secret_fixture()
      feed = vulnerability_feed_fixture(%{credential_ref: ref_for.(secret.id)})

      assert [
               %{
                 owner_kind: :vulnerability_feed_definition,
                 owner_id: owner_id,
                 field_path: "$.credential_ref"
               }
             ] = bindings_for(secret.id)

      assert owner_id == to_string(feed.id)

      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               delete_secret_row(secret.id)

      assert constraint == "network_credential_secret_bindings_secret_id_fkey"
    end
  end

  test "a conflicting vulnerability-feed upsert binds only the persisted owner", %{secret: secret} do
    replacement = secret_fixture()
    provider = "credential-reference-upsert-#{System.unique_integer([:positive])}"
    feed_key = "feed-#{System.unique_integer([:positive])}"

    persisted =
      vulnerability_feed_fixture(%{
        provider: provider,
        feed_key: feed_key,
        credential_ref: SecretRefs.network_credential_ref(secret.id)
      })

    upserted =
      VulnerabilityFeedDefinition
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider: provider,
          feed_key: feed_key,
          display_name: "Credential reference constraints feed",
          feed_type: "test",
          credential_ref: SecretRefs.network_credential_ref(replacement.id)
        },
        actor: system_actor()
      )
      |> Ash.create!()

    assert upserted.id == persisted.id
    assert [] = bindings_for(secret.id)

    assert [
             %{
               owner_kind: :vulnerability_feed_definition,
               owner_id: persisted_owner_id,
               field_path: "$.credential_ref"
             }
           ] = bindings_for(replacement.id)

    assert persisted_owner_id == to_string(persisted.id)
  end

  test "raw vulnerability helper trims the runtime Unicode whitespace set", %{secret: secret} do
    runtime_trim =
      "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{0085}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"

    for {feed_id, credential_ref} <- [
          {Ecto.UUID.generate(),
           runtime_trim <>
             "credentialref:network-credential-secret:#{String.upcase(secret.id)}" <> runtime_trim},
          {Ecto.UUID.generate(), runtime_trim <> String.upcase(secret.id) <> runtime_trim}
        ] do
      SQL.query!(
        Repo,
        "SELECT platform.insert_vulnerability_feed_secret_bindings($1, $2)",
        [Ecto.UUID.dump!(feed_id), credential_ref]
      )

      assert [
               %{
                 owner_kind: :vulnerability_feed_definition,
                 owner_id: owner_id,
                 field_path: "$.credential_ref"
               }
             ] =
               secret.id
               |> bindings_for()
               |> Enum.filter(&(&1.owner_id == to_string(feed_id)))

      assert owner_id == to_string(feed_id)
    end
  end

  test "raw vulnerability helper rejects a Unicode-trimmed malformed network marker" do
    feed_id = Ecto.UUID.generate()

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             SQL.query(
               Repo,
               "SELECT platform.insert_vulnerability_feed_secret_bindings($1, $2)",
               [
                 Ecto.UUID.dump!(feed_id),
                 "\t\ncredentialref:network-credential-secret:not-a-uuid\u{3000}"
               ]
             )

    assert message =~
             "invalid network credential reference at vulnerability_feed_definition.$.credential_ref"
  end

  test "a broker grant network reference must name its own secret id", %{secret: secret} do
    other = secret_fixture()

    grant_attrs = %{
      grant_type: "credential-reference-constraints",
      consumer_kind: :test,
      consumer_id: "credential-reference-constraints",
      purpose: "credential.reference.constraints",
      ttl_seconds: 60
    }

    mismatched =
      grant_attrs
      |> Map.merge(%{
        secret_id: secret.id,
        secret_ref: SecretRefs.network_credential_ref(other.id)
      })
      |> CredentialBrokerGrant.issue_attrs()

    # `issue_attrs/1` derives the id from a canonical reference, so drop it to
    # reach the NULL branch of the same check.
    missing_secret_id =
      grant_attrs
      |> Map.put(:secret_ref, SecretRefs.network_credential_ref(secret.id))
      |> CredentialBrokerGrant.issue_attrs()
      |> Map.delete(:secret_id)

    for attrs <- [mismatched, missing_secret_id] do
      assert {:error, error} = CredentialBrokerGrant.issue_grant(attrs, actor: system_actor())
      assert Exception.message(error) =~ "network credential secret_ref must match secret_id"
    end
  end

  test "migration backfills a missing broker secret id only from a live canonical reference" do
    SQL.query!(Repo, "CREATE TEMP TABLE network_credential_secrets (id uuid PRIMARY KEY)")

    SQL.query!(Repo, """
    CREATE TEMP TABLE credential_broker_grants (
      id uuid PRIMARY KEY,
      secret_id uuid,
      secret_ref text NOT NULL
    )
    """)

    secret_id = Ecto.UUID.generate()
    resolvable_grant_id = Ecto.UUID.generate()
    orphaned_grant_id = Ecto.UUID.generate()
    unrelated_grant_id = Ecto.UUID.generate()

    SQL.query!(Repo, "INSERT INTO pg_temp.network_credential_secrets (id) VALUES ($1)", [
      Ecto.UUID.dump!(secret_id)
    ])

    SQL.query!(
      Repo,
      """
      INSERT INTO pg_temp.credential_broker_grants (id, secret_ref)
      VALUES
        ($1, $4),
        ($2, 'credentialref:network-credential-secret:' || $5::uuid::text),
        ($3, 'credentialref:example:service-account')
      """,
      [
        Ecto.UUID.dump!(resolvable_grant_id),
        Ecto.UUID.dump!(orphaned_grant_id),
        Ecto.UUID.dump!(unrelated_grant_id),
        SecretRefs.network_credential_ref(secret_id),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    SQL.query!(Repo, Migration.backfill_credential_broker_grant_secret_ids_sql("pg_temp"))

    assert %{rows: rows} =
             SQL.query!(
               Repo,
               "SELECT id::text, secret_id::text FROM pg_temp.credential_broker_grants ORDER BY id"
             )

    assert Enum.sort(rows) ==
             Enum.sort([
               [resolvable_grant_id, secret_id],
               [orphaned_grant_id, nil],
               [unrelated_grant_id, nil]
             ])
  end

  test "every binding owner kind has an AFTER binding trigger on its table" do
    # Map.fetch! fails for an owner kind added to the resource without a table
    # here, so a new kind cannot ship without its trigger being checked.
    owner_tables = %{
      notification_channel: "notification_channels",
      plugin_assignment: "plugin_assignments",
      plugin_target_policy: "plugin_target_policies",
      producer_schedule: "producer_schedules",
      vulnerability_feed_definition: "vulnerability_feed_definitions"
    }

    expected =
      NetworkCredentialSecretBinding
      |> Info.attribute(:owner_kind)
      |> Map.fetch!(:constraints)
      |> Keyword.fetch!(:one_of)
      |> Enum.map(&[Map.fetch!(owner_tables, &1), "AFTER"])
      |> Enum.sort()

    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT c.relname, CASE WHEN (t.tgtype::integer & 2) = 2 THEN 'BEFORE' ELSE 'AFTER' END FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE t.tgname = 'sync_network_credential_secret_bindings' AND c.relnamespace = 'platform'::regnamespace ORDER BY c.relname"
      )

    assert Enum.sort(rows) == expected
  end

  test "a selected preexisting malformed marker makes the migration backfill path fail loudly" do
    assignment = plugin_assignment_fixture(%{params: %{}})

    SQL.query!(
      Repo,
      "ALTER TABLE platform.plugin_assignments DISABLE TRIGGER sync_network_credential_secret_bindings"
    )

    SQL.query!(
      Repo,
      "UPDATE platform.plugin_assignments SET params = jsonb_build_object('credential', $1::text) WHERE id = $2",
      [
        "credentialref:network-credential-secret:not-a-uuid",
        Ecto.UUID.dump!(assignment.id)
      ]
    )

    SQL.query!(
      Repo,
      "ALTER TABLE platform.plugin_assignments ENABLE TRIGGER sync_network_credential_secret_bindings"
    )

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             SQL.query(
               Repo,
               "SELECT platform.insert_network_credential_secret_bindings('plugin_assignment', id, params, '$.params') FROM platform.plugin_assignments WHERE id = $1",
               [Ecto.UUID.dump!(assignment.id)]
             )

    assert message =~
             "invalid network credential reference at plugin_assignment.$.params.k:63726564656e7469616c"
  end

  test "deletion audits expose only the redacted record surface" do
    assert [:read, :record] =
             NetworkCredentialSecretDeletionAudit
             |> Info.actions()
             |> Enum.map(& &1.name)
             |> Enum.sort()

    audit =
      NetworkCredentialSecretDeletionAudit
      |> Ash.Changeset.for_create(
        :record,
        %{
          secret_id: Ecto.UUID.generate(),
          name: "redacted audit",
          provider: "test",
          credential_kind: :api_token,
          source_type: :internal_encrypted
        },
        actor: system_actor()
      )
      |> Ash.create!()

    assert %{name: "redacted audit", deleted_by_actor_id: nil} = audit

    %{rows: columns} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_schema = 'platform' AND table_name = 'network_credential_secret_deletion_audits' ORDER BY column_name"
      )

    assert Enum.map(columns, &hd/1) == [
             "credential_kind",
             "deleted_at",
             "deleted_by_actor_id",
             "id",
             "name",
             "provider",
             "secret_id",
             "source_type"
           ]
  end

  test "every foreign key into secrets and broker grants has a declared delete action" do
    expected = %{
      "ansible_controllers_callback_credential_secret_id_fkey" => "r",
      "ansible_controllers_credential_secret_id_fkey" => "r",
      "ansible_controllers_execution_credential_secret_id_fkey" => "r",
      "ansible_controllers_sync_credential_secret_id_fkey" => "r",
      "ansible_playbook_repositories_credential_secret_id_fkey" => "r",
      "credential_broker_grant_versions_version_source_id_fkey" => "c",
      "credential_secret_resolution_audits_secret_id_fkey" => "n",
      "credential_broker_grants_secret_id_fkey" => "r",
      "device_snmp_credentials_credential_secret_id_fkey" => "r",
      "integration_sources_credential_secret_id_fkey" => "r",
      "mapper_mikrotik_controllers_credential_secret_id_fkey" => "r",
      "mapper_unifi_controllers_credential_secret_id_fkey" => "r",
      "network_credential_rules_secret_id_fkey" => "r",
      "network_credential_secret_bindings_secret_id_fkey" => "r",
      "network_credential_secret_versions_version_source_id_fkey" => "c",
      "outbound_mail_settings_api_key_secret_id_fkey" => "r",
      "outbound_mail_settings_password_secret_id_fkey" => "r",
      "plugin_repositories_credential_secret_id_fkey" => "r",
      "snmp_profiles_credential_secret_id_fkey" => "r",
      "snmp_targets_credential_secret_id_fkey" => "r"
    }

    # Selected by the referenced table, not by name, so a new foreign key fails
    # here until it is given a delete action on purpose.
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT conname, confdeltype
        FROM pg_constraint
        WHERE contype = 'f'
          AND confrelid IN (
            'platform.network_credential_secrets'::regclass,
            'platform.credential_broker_grants'::regclass
          )
        ORDER BY conname
        """
      )

    delete_actions = Map.new(rows, fn [name, action] -> {name, action} end)

    assert delete_actions == expected

    # A restrictive foreign key the resource does not map surfaces as a raw
    # constraint error instead of the "credential_in_use" message callers match.
    configured = AshPostgres.DataLayer.Info.foreign_key_names(NetworkCredentialSecret)
    restrict = for {name, "r"} <- delete_actions, do: name

    assert Enum.sort(restrict) == configured |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    assert configured |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == ["credential_in_use"]
  end

  defp bindings_for(secret_id) do
    NetworkCredentialSecretBinding
    |> Ash.Query.filter(secret_id == ^secret_id)
    |> Ash.read!(actor: system_actor())
  end

  defp binding_paths(secret_id) do
    secret_id
    |> bindings_for()
    |> Enum.map(& &1.field_path)
    |> Enum.sort()
  end

  defp delete_secret_row(secret_id) do
    case SQL.query(
           Repo,
           "DELETE FROM platform.network_credential_secrets WHERE id = $1",
           [Ecto.UUID.dump!(secret_id)]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp secret_fixture do
    NetworkCredentialSecret.create_secret!(
      %{
        name: "DB constraint secret #{System.unique_integer([:positive])}",
        provider: "credential-reference-constraints",
        credential_kind: :api_token,
        secret_payload: "credential-reference-constraint-marker"
      },
      actor: system_actor()
    )
  end

  defp vulnerability_feed_fixture(overrides) do
    attrs =
      Map.merge(
        %{
          provider: "credential-reference-constraints",
          feed_key: "feed-#{System.unique_integer([:positive])}",
          display_name: "Credential reference constraints feed",
          feed_type: "test"
        },
        Map.new(overrides)
      )

    VulnerabilityFeedDefinition
    |> Ash.Changeset.for_create(:upsert, attrs, actor: system_actor())
    |> Ash.create!()
  end

  defp plugin_assignment_fixture(overrides) do
    suffix = System.unique_integer([:positive])
    plugin_id = "credential-reference-constraints-#{suffix}"
    agent_uid = "credential-reference-agent-#{suffix}"

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Credential reference constraints agent",
        capabilities: ["wasm"]
      },
      actor: system_actor()
    )
    |> Ash.create!()

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{plugin_id: plugin_id, name: "Credential reference constraints"},
      actor: system_actor()
    )
    |> Ash.create!()

    manifest = %{
      "id" => plugin_id,
      "name" => "Credential reference constraints",
      "version" => "1.0.0",
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

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Credential reference constraints",
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}",
          signature: %{},
          source_type: :upload
        },
        actor: system_actor()
      )
      |> Ash.create!()

    package =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: system_actor())
      |> Ash.update!()

    register_control_session!(agent_uid)

    attrs =
      Map.merge(
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :manual,
          enabled: true,
          interval_seconds: 3_600,
          timeout_seconds: 600,
          params: %{}
        },
        Map.new(overrides)
      )

    PluginAssignment
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  defp register_control_session!(agent_uid) do
    {:ok, _pid} =
      ProcessRegistry.register(
        {:agent_control, @partition_id, agent_uid, node()},
        %{
          agent_id: agent_uid,
          partition_id: @partition_id,
          gateway_node: node(),
          capabilities: ["wasm"]
        }
      )

    Process.put({__MODULE__, :agent_uids}, [
      agent_uid | Process.get({__MODULE__, :agent_uids}, [])
    ])

    assert_control_partition(agent_uid, 40)
  end

  defp assert_control_partition(_agent_uid, 0),
    do: flunk("test control-session partition did not converge")

  defp assert_control_partition(agent_uid, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(@partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: @partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_partition(agent_uid, attempts - 1)
    end
  end

  defp unregister_fixture_sessions do
    {__MODULE__, :agent_uids}
    |> Process.get([])
    |> Enum.each(fn agent_uid ->
      ProcessRegistry.unregister({:agent_control, @partition_id, agent_uid, node()})
    end)
  end

  defp system_actor, do: SystemActor.system(:credential_reference_constraints_test)
end
