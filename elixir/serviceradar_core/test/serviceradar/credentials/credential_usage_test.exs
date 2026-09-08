defmodule ServiceRadar.Credentials.CredentialUsageTest do
  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialUsage
  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.LiveGrant
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Repo

  @moduletag :integration

  @manager %{
    id: "credential-usage-manager",
    role: :admin,
    permissions: ["settings.credentials.manage"]
  }

  @viewer %{
    id: "credential-usage-viewer",
    role: :viewer,
    permissions: []
  }

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "exposes the batched credential usage API" do
    assert Code.ensure_loaded?(CredentialUsage)
    assert function_exported?(CredentialUsage, :for_secret, 2)
    assert function_exported?(CredentialUsage, :for_secrets, 2)
  end

  test "empty batches are available without a database lookup" do
    assert {:ok, %{}} = CredentialUsage.for_secrets([], actor: @viewer)
  end

  test "malformed, unauthorized, missing, and partial batches fail closed" do
    secret = secret_fixture("authorization")
    missing_id = Ecto.UUID.generate()

    for result <- [
          CredentialUsage.for_secret("not-a-uuid", actor: @manager),
          CredentialUsage.for_secret(secret.id, actor: @viewer),
          CredentialUsage.for_secret(missing_id, actor: @manager),
          CredentialUsage.for_secrets([secret.id, missing_id], actor: @manager)
        ] do
      assert result == {:error, {:credential_usage_unavailable, :authorization}}
    end
  end

  test "duplicate IDs are normalized once and return redacted empty results" do
    secret = secret_fixture("dedupe")
    secret_id = secret.id

    assert {:ok, %{^secret_id => %Result{} = usage}} =
             CredentialUsage.for_secrets([secret.id, String.upcase(secret.id), secret.id],
               actor: @manager
             )

    assert usage.status == :available
    assert usage.consumers == []
    assert usage.live_grants == []
    refute Map.has_key?(Map.from_struct(usage), :secret_payload)
  end

  test "all direct consumer resources are named without decrypting default-secret fields" do
    secret = secret_fixture("direct")
    ids = insert_direct_consumers(secret.id)

    assert {:ok, %Result{consumers: consumers}} =
             CredentialUsage.for_secret(secret.id, actor: @manager)

    assert consumer_keys(consumers) ==
             Enum.sort([
               {:ansible_controller, ids.ansible_controller, :callback},
               {:ansible_controller, ids.ansible_controller, :execution},
               {:ansible_controller, ids.ansible_controller, :sync},
               {:ansible_playbook_repository, ids.ansible_playbook_repository, nil},
               {:credential_rule, ids.credential_rule, nil},
               {:device_snmp_credential, ids.device_snmp_credential, nil},
               {:integration_source, ids.integration_source, nil},
               {:mapper_mikrotik_controller, ids.mapper_mikrotik_controller, nil},
               {:mapper_unifi_controller, ids.mapper_unifi_controller, nil},
               {:outbound_mail_settings, ids.outbound_mail_settings, :api_key},
               {:outbound_mail_settings, ids.outbound_mail_settings, :password},
               {:plugin_repository, ids.plugin_repository, nil},
               {:snmp_profile, ids.snmp_profile, nil},
               {:snmp_target, ids.snmp_target, nil}
             ])

    assert consumers
           |> Enum.find(&(&1.kind == :snmp_profile))
           |> Map.fetch!(:label)
           |> String.starts_with?("Usage SNMP profile-")

    for consumer <- consumers do
      assert %Consumer{} = consumer
      refute Map.has_key?(Map.from_struct(consumer), :secret_payload)
      refute Map.has_key?(Map.from_struct(consumer), :encrypted_secret_payload)
    end
  end

  test "Ansible legacy and sync columns normalize equal and fallback references" do
    equal = secret_fixture("ansible-equal")
    legacy_only = secret_fixture("ansible-legacy")
    divergent_legacy = secret_fixture("ansible-divergent-legacy")
    divergent_sync = secret_fixture("ansible-divergent-sync")

    equal_id = insert_ansible_controller("Equal controller", equal.id, equal.id, nil, nil)
    legacy_id = insert_ansible_controller("Legacy controller", legacy_only.id, nil, nil, nil)

    divergent_id =
      insert_ansible_controller(
        "Divergent controller",
        divergent_legacy.id,
        divergent_sync.id,
        nil,
        nil
      )

    assert {:ok, usages} =
             CredentialUsage.for_secrets(
               [equal.id, legacy_only.id, divergent_legacy.id, divergent_sync.id],
               actor: @manager
             )

    assert consumer_keys(usages[equal.id].consumers) == [{:ansible_controller, equal_id, :sync}]

    assert consumer_keys(usages[legacy_only.id].consumers) == [
             {:ansible_controller, legacy_id, :sync}
           ]

    assert consumer_keys(usages[divergent_legacy.id].consumers) == [
             {:ansible_controller, divergent_id, :legacy_sync}
           ]

    assert consumer_keys(usages[divergent_sync.id].consumers) == [
             {:ansible_controller, divergent_id, :sync}
           ]
  end

  test "all five binding owner kinds and supported field roots resolve and nested paths dedupe" do
    secret = secret_fixture("bindings")
    owners = insert_binding_owners(secret.id)

    assert {:ok, %Result{consumers: consumers}} =
             CredentialUsage.for_secret(secret.id, actor: @manager)

    assert consumer_keys(consumers) ==
             Enum.sort([
               {:notification_channel, owners.notification_channel, :secret_refs},
               {:plugin_assignment, owners.plugin_assignment, :params},
               {:plugin_target_policy, owners.plugin_target_policy, :params_template},
               {:producer_schedule, owners.producer_schedule, :credential_refs},
               {:producer_schedule, owners.producer_schedule, :params},
               {:vulnerability_feed_definition, owners.vulnerability_feed_definition,
                :credential_ref}
             ])
  end

  test "missing owners, unrecognized kinds, and unsupported binding roots make usage unavailable" do
    for {suffix, kind, field_path, owner?} <- [
          {"missing", "plugin_assignment", "$.params.k:746f6b656e", false},
          {"kind", "credential_rule", "$.params", false},
          {"root", "plugin_assignment", "$.not_params.k:746f6b656e", true}
        ] do
      secret = secret_fixture("binding-#{suffix}")
      owner_id = if owner?, do: insert_plugin_assignment_owner(%{}), else: Ecto.UUID.generate()

      insert_binding(secret.id, kind, owner_id, field_path)

      assert CredentialUsage.for_secret(secret.id, actor: @manager) ==
               {:error, {:credential_usage_unavailable, :network_credential_secret_bindings}}
    end
  end

  test "live grants use one strict expiry boundary and return only redacted fields" do
    secret = secret_fixture("grants")
    now = ~U[2026-08-31 12:00:00Z]

    live_issued = insert_grant(secret.id, :issued, DateTime.add(now, 1, :second), "issued")
    live_active = insert_grant(secret.id, :active, DateTime.add(now, 60, :second), "active")
    _boundary = insert_grant(secret.id, :issued, now, "boundary")
    _expired_active = insert_grant(secret.id, :active, DateTime.add(now, -1, :second), "old")

    for status <- [:consumed, :denied, :expired, :revoked] do
      insert_grant(secret.id, status, DateTime.add(now, 60, :second), Atom.to_string(status))
    end

    assert {:ok, %Result{live_grants: grants}} =
             CredentialUsage.for_secret(secret.id, actor: @manager, now: now)

    assert Enum.map(grants, & &1.id) == Enum.sort([live_issued, live_active])

    for grant <- grants do
      assert %LiveGrant{} = grant

      assert grant |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:consumer_id, :consumer_kind, :expires_at, :id, :purpose, :status]

      refute Map.has_key?(Map.from_struct(grant), :secret_ref)
      refute Map.has_key?(Map.from_struct(grant), :inject)
      refute Map.has_key?(Map.from_struct(grant), :metadata)
    end
  end

  test "batched results are deterministically sorted and isolated by secret" do
    first = secret_fixture("batch-first")
    second = secret_fixture("batch-second")

    first_profile = insert_snmp_profile(first.id, "Zulu profile")
    first_rule = insert_rule(first.id, "Alpha rule")
    second_profile = insert_snmp_profile(second.id, "Second profile")

    assert {:ok, usage} =
             CredentialUsage.for_secrets([second.id, first.id], actor: @manager)

    assert consumer_keys(usage[first.id].consumers) == [
             {:credential_rule, first_rule, nil},
             {:snmp_profile, first_profile, nil}
           ]

    assert consumer_keys(usage[second.id].consumers) == [
             {:snmp_profile, second_profile, nil}
           ]
  end

  defp insert_direct_consumers(secret_id) do
    mapper_job_id = uuid()
    snmp_profile_id = insert_snmp_profile(secret_id, "Usage SNMP profile")
    device_id = "usage-device-#{System.unique_integer([:positive])}"

    sql!("INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [device_id])

    sql!("INSERT INTO platform.mapper_jobs (id, name) VALUES ($1, $2)", [
      dump(mapper_job_id),
      unique("Usage mapper job")
    ])

    ids = %{
      credential_rule: insert_rule(secret_id, "Usage credential rule"),
      snmp_profile: snmp_profile_id,
      snmp_target: uuid(),
      device_snmp_credential: uuid(),
      mapper_unifi_controller: uuid(),
      mapper_mikrotik_controller: uuid(),
      integration_source: uuid(),
      outbound_mail_settings: outbound_mail_settings_id(),
      plugin_repository: uuid(),
      ansible_controller: uuid(),
      ansible_playbook_repository: uuid()
    }

    sql!(
      "INSERT INTO platform.snmp_targets (id, name, host, snmp_profile_id, credential_secret_id) VALUES ($1, $2, '192.0.2.1', $3, $4)",
      [dump(ids.snmp_target), unique("Usage target"), dump(snmp_profile_id), dump(secret_id)]
    )

    sql!(
      "INSERT INTO platform.device_snmp_credentials (id, device_id, credential_secret_id) VALUES ($1, $2, $3)",
      [dump(ids.device_snmp_credential), device_id, dump(secret_id)]
    )

    sql!(
      "INSERT INTO platform.mapper_unifi_controllers (id, name, base_url, encrypted_api_key, mapper_job_id, credential_secret_id) VALUES ($1, 'Usage UniFi', 'https://unifi.example.test', $2, $3, $4)",
      [dump(ids.mapper_unifi_controller), <<0, 1, 2>>, dump(mapper_job_id), dump(secret_id)]
    )

    sql!(
      "INSERT INTO platform.mapper_mikrotik_controllers (id, name, base_url, username, encrypted_password, mapper_job_id, credential_secret_id) VALUES ($1, 'Usage MikroTik', 'https://routeros.example.test', 'usage', $2, $3, $4)",
      [
        dump(ids.mapper_mikrotik_controller),
        <<0, 1, 2>>,
        dump(mapper_job_id),
        dump(secret_id)
      ]
    )

    sql!(
      "INSERT INTO platform.integration_sources (id, name, source_type, endpoint, encrypted_credentials_encrypted, credential_secret_id) VALUES ($1, 'Usage integration', 'custom', 'https://integration.example.test', $2, $3)",
      [dump(ids.integration_source), <<0, 1, 2>>, dump(secret_id)]
    )

    sql!(
      "UPDATE platform.outbound_mail_settings SET from_email = 'usage@example.test', encrypted_password = $1, encrypted_api_key = $1, password_secret_id = $2, api_key_secret_id = $2 WHERE id = $3",
      [<<0, 1, 2>>, dump(secret_id), dump(ids.outbound_mail_settings)]
    )

    sql!(
      "INSERT INTO platform.plugin_repositories (id, name, repo_url, index_asset_name, signing_key_id, signing_public_key, credential_secret_id, inserted_at, updated_at) VALUES ($1, 'Usage repository', $2, 'index.json', 'usage-key', 'usage-public-key', $3, now(), now())",
      [
        dump(ids.plugin_repository),
        "https://github.com/example/usage-#{System.unique_integer([:positive])}",
        dump(secret_id)
      ]
    )

    insert_ansible_controller_with_id(
      ids.ansible_controller,
      "Usage AWX controller",
      secret_id,
      secret_id,
      secret_id,
      secret_id
    )

    sql!(
      "INSERT INTO platform.ansible_playbook_repositories (id, name, git_url, credential_secret_id) VALUES ($1, 'Usage playbooks', $2, $3)",
      [
        dump(ids.ansible_playbook_repository),
        "https://github.com/example/playbooks-#{System.unique_integer([:positive])}.git",
        dump(secret_id)
      ]
    )

    ids
  end

  defp insert_binding_owners(secret_id) do
    ref = SecretRefs.network_credential_ref(secret_id)
    package_id = insert_plugin_package()
    provider_id = uuid()

    owners = %{
      vulnerability_feed_definition: uuid(),
      notification_channel: uuid(),
      producer_schedule: uuid(),
      plugin_assignment: uuid(),
      plugin_target_policy: uuid()
    }

    sql!(
      "INSERT INTO platform.vulnerability_feed_definitions (id, provider, feed_key, display_name, feed_type, credential_ref) VALUES ($1, 'usage', $2, 'Usage vulnerability feed', 'test', $3)",
      [dump(owners.vulnerability_feed_definition), unique("feed"), ref]
    )

    sql!(
      "INSERT INTO platform.notification_providers (id, provider_key, provider_type, display_name) VALUES ($1, $2, 'builtin', 'Usage provider')",
      [dump(provider_id), unique("usage-provider")]
    )

    sql!(
      "INSERT INTO platform.notification_channels (id, name, provider_id, secret_refs) VALUES ($1, 'Usage notification', $2, $3::jsonb)",
      [dump(owners.notification_channel), dump(provider_id), %{"token" => ref}]
    )

    sql!(
      "INSERT INTO platform.producer_schedules (id, producer_kind, plugin_package_id, schedule_id, display_name, credential_refs, params) VALUES ($1, 'wasm_plugin', $2, $3, 'Usage schedule', $4::jsonb, $5::jsonb)",
      [
        dump(owners.producer_schedule),
        dump(package_id),
        unique("usage-schedule"),
        %{"token" => ref},
        %{"nested" => %{"token" => ref}}
      ]
    )

    insert_plugin_assignment_owner(%{
      "id" => owners.plugin_assignment,
      "package_id" => package_id,
      "params" => %{"one" => ref, "nested" => %{"two" => ref}}
    })

    sql!(
      "INSERT INTO platform.plugin_target_policies (id, name, plugin_package_id, params_template) VALUES ($1, 'Usage policy', $2, $3::jsonb)",
      [dump(owners.plugin_target_policy), dump(package_id), %{"token" => ref}]
    )

    owners
  end

  defp insert_plugin_assignment_owner(attrs) do
    id = Map.get(attrs, "id", uuid())
    package_id = Map.get_lazy(attrs, "package_id", &insert_plugin_package/0)
    params = Map.get(attrs, "params", %{})

    sql!(
      "INSERT INTO platform.plugin_assignments (id, agent_uid, partition_id, plugin_id, plugin_package_id, source, enabled, params) VALUES ($1, $2, 'usage-partition', $3, $4, 'manual', false, $5::jsonb)",
      [
        dump(id),
        unique("usage-agent"),
        unique("usage-plugin"),
        dump(package_id),
        params
      ]
    )

    id
  end

  defp insert_plugin_package do
    plugin_id = unique("usage-plugin-package")
    package_id = uuid()

    sql!("INSERT INTO platform.plugins (plugin_id, name) VALUES ($1, 'Usage plugin')", [plugin_id])

    sql!(
      "INSERT INTO platform.plugin_packages (id, plugin_id, name, version, entrypoint, runtime, outputs, content_hash) VALUES ($1, $2, 'Usage plugin', '1.0.0', 'run', 'wasi-preview1', 'serviceradar.plugin_result.v1', $3)",
      [dump(package_id), plugin_id, "sha256:#{plugin_id}"]
    )

    package_id
  end

  defp insert_binding(secret_id, kind, owner_id, field_path) do
    sql!(
      "INSERT INTO platform.network_credential_secret_bindings (id, secret_id, owner_kind, owner_id, field_path) VALUES (uuid_generate_v7(), $1, $2, $3, $4)",
      [dump(secret_id), kind, to_string(owner_id), field_path]
    )
  end

  defp insert_grant(secret_id, status, expires_at, suffix) do
    id = uuid()

    sql!(
      "INSERT INTO platform.credential_broker_grants (id, secret_id, secret_ref, grant_type, consumer_kind, consumer_id, purpose, expires_at, status) VALUES ($1, $2, $3, 'usage-test', 'test', $4, 'usage.test', $5, $6)",
      [
        dump(id),
        dump(secret_id),
        SecretRefs.network_credential_ref(secret_id),
        suffix,
        expires_at,
        Atom.to_string(status)
      ]
    )

    id
  end

  defp insert_rule(secret_id, name) do
    id = uuid()

    sql!(
      "INSERT INTO platform.network_credential_rules (id, name, provider, auth_method, purpose, target_query, scope_type, scope_value, secret_id) VALUES ($1, $2, 'usage', 'token', 'test', 'in:devices', 'agent', $3, $4)",
      [dump(id), unique(name), unique("usage-scope"), dump(secret_id)]
    )

    id
  end

  defp insert_snmp_profile(secret_id, name) do
    id = uuid()

    sql!(
      "INSERT INTO platform.snmp_profiles (id, name, credential_secret_id) VALUES ($1, $2, $3)",
      [dump(id), unique(name), dump(secret_id)]
    )

    id
  end

  defp insert_ansible_controller(name, legacy_id, sync_id, execution_id, callback_id) do
    id = uuid()

    insert_ansible_controller_with_id(
      id,
      name,
      legacy_id,
      sync_id,
      execution_id,
      callback_id
    )

    id
  end

  defp insert_ansible_controller_with_id(id, name, legacy_id, sync_id, execution_id, callback_id) do
    sql!(
      "INSERT INTO platform.ansible_controllers (id, name, base_url, agent_id, credential_secret_id, sync_credential_secret_id, execution_credential_secret_id, callback_credential_secret_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
      [
        dump(id),
        unique(name),
        "https://awx-#{System.unique_integer([:positive])}.example.test",
        unique("usage-awx-agent"),
        dump(legacy_id),
        dump(sync_id),
        dump(execution_id),
        dump(callback_id)
      ]
    )
  end

  defp outbound_mail_settings_id do
    %{rows: [[id]]} =
      sql!("SELECT id FROM platform.outbound_mail_settings ORDER BY inserted_at LIMIT 1")

    Ecto.UUID.load!(id)
  end

  defp secret_fixture(suffix) do
    NetworkCredentialSecret.create_secret!(
      %{
        name: unique("Credential usage #{suffix}"),
        provider: "credential-usage-test",
        credential_kind: :api_token,
        secret_payload: "credential-usage-marker"
      },
      actor: SystemActor.system(:credential_usage_test)
    )
  end

  defp consumer_keys(consumers), do: Enum.map(consumers, &{&1.kind, &1.id, &1.slot})

  defp sql!(statement, params \\ []), do: SQL.query!(Repo, statement, params)
  defp dump(nil), do: nil
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp uuid, do: Ash.UUIDv7.generate()

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
