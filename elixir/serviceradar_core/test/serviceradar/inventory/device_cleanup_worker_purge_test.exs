defmodule ServiceRadar.Inventory.DeviceCleanupWorkerPurgeTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @actor SystemActor.system(:device_cleanup_worker_purge_test)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, prefix: "sr:purge-test-#{System.unique_integer([:positive])}"}
  end

  test "a device that still has source observations is purged", %{prefix: prefix} do
    uid = insert_expired_device!("#{prefix}-a")
    insert_source_observation!(uid)

    assert {%{deleted: 1}, 1} = purge([uid])

    refute device_exists?(uid)
    assert row_count("device_source_observations", "device_id", uid) == 0
  end

  test "a device whose agent has checkers is purged", %{prefix: prefix} do
    uid = insert_expired_device!("#{prefix}-a")
    agent_uid = "#{prefix}-agent"

    Repo.query!("INSERT INTO platform.ocsf_agents (uid, device_uid) VALUES ($1, $2)", [
      agent_uid,
      uid
    ])

    Repo.query!(
      "INSERT INTO platform.checkers (name, type, agent_uid) VALUES ('ping', 'icmp', $1)",
      [agent_uid]
    )

    assert {%{deleted: 1}, 1} = purge([uid])

    refute device_exists?(uid)
    assert row_count("ocsf_agents", "uid", agent_uid) == 0
    assert row_count("checkers", "agent_uid", agent_uid) == 0
  end

  test "a new restricting foreign key to a device does not stall the purge", %{prefix: prefix} do
    uid = insert_expired_device!("#{prefix}-a")
    table = "purge_test_child_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE TABLE platform.#{table} (
      device_uid text NOT NULL REFERENCES platform.ocsf_devices(uid) ON DELETE RESTRICT
    )
    """)

    Repo.query!("INSERT INTO platform.#{table} (device_uid) VALUES ($1)", [uid])

    assert {%{deleted: 1}, 1} = purge([uid])

    refute device_exists?(uid)
    assert row_count(table, "device_uid", uid) == 0
  end

  test "a device whose delete fails is isolated from the rest of its batch", %{prefix: prefix} do
    failing = insert_expired_device!("#{prefix}-a")
    purgeable = insert_expired_device!("#{prefix}-b")
    table = guarded_child_table!()

    Repo.query!("INSERT INTO platform.#{table} (device_uid) VALUES ($1)", [failing])

    assert {%{deleted: 1, errors: 1}, 1} = purge([failing, purgeable])

    assert device_exists?(failing)
    refute device_exists?(purgeable)
  end

  test "a device with automation history is skipped and the rest of its batch purged", %{
    prefix: prefix
  } do
    retained = insert_expired_device!("#{prefix}-a")
    purgeable = insert_expired_device!("#{prefix}-b")
    insert_source_observation!(purgeable)
    target_id = insert_execution_target!(retained)

    assert {%{deleted: 1, skipped: 1, errors: 0}, 1} = purge([retained, purgeable])

    assert device_exists?(retained)

    assert row_count("ansible_automation_execution_targets", "id", Ecto.UUID.dump!(target_id)) ==
             1

    refute device_exists?(purgeable)
  end

  test "a batch that purges nothing does not end the run", %{prefix: prefix} do
    # A full first batch (in uid order) of devices kept by automation history,
    # then one purgeable device after them.
    %{rows: rows} =
      Repo.query!(
        """
        INSERT INTO platform.ocsf_devices (uid, deleted_at, deleted_reason)
        SELECT $1 || '-a-' || lpad(CAST(n AS text), 3, '0'), now() - interval '3 days', 'purge_test'
        FROM generate_series(1, 100) AS n
        RETURNING uid
        """,
        [prefix]
      )

    [first | rest] = rows |> List.flatten() |> Enum.sort()
    target_id = insert_execution_target!(first)

    # The other 99 devices are targets of the same execution, each through its
    # own AWX host membership.
    Repo.query!(
      """
      WITH t AS (
        SELECT * FROM platform.ansible_automation_execution_targets WHERE id = $1
      ),
      d AS (
        SELECT uid, row_number() OVER (ORDER BY uid) AS n
        FROM unnest(CAST($2 AS text[])) AS uid
      ),
      m AS (
        INSERT INTO platform.ansible_awx_host_memberships
          (controller_id, inventory_id, awx_host_id, canonical_device_uid, source_generation,
           host_name, enabled, current, last_seen_at, link_disposition, source_fingerprint)
        SELECT t.controller_id, t.inventory_id, 1000 + d.n, d.uid, 3, 'host01', true, true,
               now() AT TIME ZONE 'utc', 'approved', t.source_fingerprint
        FROM t CROSS JOIN d
        RETURNING id, awx_host_id, canonical_device_uid
      )
      INSERT INTO platform.ansible_automation_execution_targets
        (execution_id, membership_id, canonical_device_uid, controller_id, inventory_id,
         awx_host_id, membership_generation, source_fingerprint, host_name, snapshot_digest)
      SELECT t.execution_id, m.id, m.canonical_device_uid, t.controller_id, t.inventory_id,
             m.awx_host_id, 3, t.source_fingerprint, 'host01', t.snapshot_digest
      FROM t CROSS JOIN m
      """,
      [Ecto.UUID.dump!(target_id), rest]
    )

    purgeable = insert_expired_device!("#{prefix}-b")
    configure_cleanup!(batch_size: 100)

    assert :ok = DeviceCleanupWorker.perform(%Oban.Job{args: %{"manual" => true}})

    refute device_exists?(purgeable)
    assert device_exists?(first)
  end

  # A table with a RESTRICT foreign key to ocsf_devices whose rows refuse to be
  # deleted, so the purge of any device it references fails.
  defp guarded_child_table! do
    table = "purge_test_guarded_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE TABLE platform.#{table} (
      device_uid text NOT NULL REFERENCES platform.ocsf_devices(uid) ON DELETE RESTRICT
    )
    """)

    Repo.query!("""
    CREATE FUNCTION platform.#{table}_refuse() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'refused'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{table}_refuse BEFORE DELETE ON platform.#{table}
    FOR EACH ROW EXECUTE FUNCTION platform.#{table}_refuse()
    """)

    table
  end

  defp purge(uids) do
    DeviceCleanupWorker.hard_delete_records(%{deleted: 0, errors: 0}, Enum.map(uids, &%{uid: &1}))
  end

  defp insert_expired_device!(uid) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices (uid, deleted_at, deleted_reason)
      VALUES ($1, now() - interval '3 days', 'purge_test')
      """,
      [uid]
    )

    uid
  end

  defp insert_source_observation!(uid) do
    Repo.query!(
      """
      INSERT INTO platform.device_source_observations
        (device_id, source, source_instance, source_object_id, source_integration_id,
         collection_id, content_hash, first_observed_at, last_observed_at)
      VALUES ($1, 'purge_test', 'instance-1', $1, 'integration-1', 'collection-1', 'hash-1',
              now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [uid]
    )
  end

  defp device_exists?(uid), do: row_count("ocsf_devices", "uid", uid) == 1

  defp row_count(table, column, value) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.#{table} WHERE #{column} = $1", [value])

    count
  end

  defp configure_cleanup!(opts) do
    attrs = %{
      retention_days: 1,
      cleanup_interval_minutes: 60,
      batch_size: Keyword.fetch!(opts, :batch_size),
      enabled: true
    }

    {:ok, _settings} =
      case DeviceCleanupSettings.get_settings(actor: @actor) do
        {:ok, %DeviceCleanupSettings{} = settings} ->
          DeviceCleanupSettings.update_settings(settings, attrs, actor: @actor)

        _missing ->
          DeviceCleanupSettings.create_settings(attrs, actor: @actor)
      end
  end

  # An AWX execution that targeted `device_uid`: the audit row whose RESTRICT
  # foreign key keeps the device from being purged.
  defp insert_execution_target!(device_uid) do
    suffix = System.unique_integer([:positive])
    controller_id = Ash.UUID.generate()
    membership_id = Ash.UUID.generate()
    source_fingerprint = "sha256:" <> String.duplicate("e", 64)

    Repo.query!(
      """
      INSERT INTO platform.ansible_controllers
        (id, name, base_url, agent_id, credential_secret_id,
         sync_credential_secret_id, execution_credential_secret_id)
      VALUES (CAST(CAST($1 AS text) AS uuid), $2, 'https://awx.example.com', 'agent-purge-test',
              CAST(CAST($3 AS text) AS uuid), CAST(CAST($3 AS text) AS uuid), CAST(CAST($4 AS text) AS uuid))
      """,
      [
        controller_id,
        "purge-test-#{suffix}",
        CredentialIntegrationFixtures.secret_id!(),
        CredentialIntegrationFixtures.secret_id!()
      ]
    )

    Repo.query!(
      """
      INSERT INTO platform.ansible_awx_host_memberships
        (id, controller_id, inventory_id, awx_host_id, canonical_device_uid,
         source_generation, host_name, ansible_host, enabled, current,
         last_seen_at, link_disposition, source_fingerprint)
      VALUES (CAST(CAST($1 AS text) AS uuid), CAST(CAST($2 AS text) AS uuid), 34, 7, $3, 3,
              'host01', '192.0.2.10', true, true,
              (now() AT TIME ZONE 'utc'), 'approved', $4)
      """,
      [membership_id, controller_id, device_uid, source_fingerprint]
    )

    {:ok, operation} =
      AutomationOperation.create_operation(
        %{
          tenant_id: "platform",
          action: "ansible.playbook.run",
          mutating: true,
          check_mode: false,
          initiator_principal_type: :human,
          initiator_principal_id: "purge-test-#{suffix}",
          authorization_version: String.duplicate("1", 64),
          authority_ceiling: %{"target_membership_ids" => [membership_id]},
          approval_snapshot: %{},
          request_source: "db_test",
          declared_inputs: %{},
          input_classifications: %{},
          input_digest: String.duplicate("2", 64),
          target_digest: String.duplicate("3", 64),
          callback_actions: [],
          run_budget: %{},
          metadata: %{}
        },
        actor: @actor
      )

    {:ok, execution} =
      AutomationExecution.create_execution(
        %{
          operation_id: operation.id,
          controller_id: controller_id,
          inventory_id: 34,
          job_template_id: 42,
          project_id: 3,
          scm_revision: String.duplicate("a", 40),
          content_sha256: String.duplicate("b", 64),
          execution_environment_id: 4,
          machine_credential_id: 5,
          credential_snapshot: %{"credential_ids" => [5]},
          check_mode: false,
          host_limit: "host01",
          dispatch_id: Ash.UUID.generate(),
          snapshot_digest: String.duplicate("c", 64),
          metadata: %{}
        },
        actor: @actor
      )

    {:ok, target} =
      AutomationExecutionTarget.create_target(
        %{
          execution_id: execution.id,
          membership_id: membership_id,
          canonical_device_uid: device_uid,
          controller_id: controller_id,
          inventory_id: 34,
          awx_host_id: 7,
          membership_generation: 3,
          source_fingerprint: source_fingerprint,
          host_name: "host01",
          ansible_host: "192.0.2.10",
          snapshot_digest: String.duplicate("d", 64)
        },
        actor: @actor
      )

    target.id
  end
end
