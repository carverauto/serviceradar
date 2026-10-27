defmodule ServiceRadar.Inventory.AvailabilityConvergenceIntegrationTest do
  @moduledoc """
  The upgrade that removes the staged availability rollout
  (`simplify-merged-availability-rollout`), against the real schema. Each test puts the
  database into the state a deployment in one rollout mode had, runs migration
  `20261026220000_converge_merged_availability` and the reconciliation it enqueues, and
  checks what the device badge, order and counts read, what every Armis northbound
  source pushes, and that per-agent results are untouched.

  The pre-upgrade state is rebuilt inside the rollback-only test transaction: the mode
  column and `availability_mode()`, the shadow table, and, for `legacy` and `shadow`,
  the trigger that copied every `is_available` change into the compatibility table.
  The legacy mirror is written directly as the pre-upgrade rows held it.

  Every fixture is invented (generated ids and addresses, SITE01-style names).
  """

  use ServiceRadar.DataCase, async: false

  import ServiceRadar.TestSupport.AvailabilityFixtures,
    only: [create_device!: 2, ledger_row!: 5, minutes_ago: 1, wifi: 3]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.ArmisAvailabilityPreview
  alias ServiceRadar.Integrations.ArmisNorthboundPopulation
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Availability.ReconcileWorker
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.ConvergeMergedAvailability, as: Migration
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261026220000_converge_merged_availability.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:availability_convergence_test)
    uid = "agent-convergence-" <> Ash.UUID.generate()

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)

    {:ok, actor: actor}
  end

  for mode <- ["legacy", "shadow"] do
    test "upgrading from #{mode}: merged values everywhere, every Armis push unchanged",
         %{actor: actor} do
      fixture = upgrade_fixture!(actor, unquote(mode))
      {probed, silent} = pre_capture_devices!(actor)
      aps = [fixture.legacy.ap, fixture.merged.ap]
      before = pushes(fixture)
      ledger_before = ledger_rows(fixture)
      transitions_before = Map.new(aps ++ [probed, silent], &{&1.uid, transitions_for(&1)})

      assert job_args = upgrade!()
      assert job_args["announce"] == true

      # The Wi-Fi access point the legacy hysteresis held offline: the badge and the
      # order read the merged state, the count follows it, and no per-device event was
      # emitted for its first merged decision.
      for ap <- aps do
        assert {true, "available"} = device_row(ap)
        assert transitions_for(ap) == transitions_before[ap.uid]
      end

      # Devices that predate availability capture are reconciled the same way, and a
      # device left unknown keeps its last boolean.
      assert {true, "available"} = device_row(probed)
      assert {true, "unknown"} = device_row(silent)

      for device <- [probed, silent],
          do: assert(transitions_for(device) == transitions_before[device.uid])

      assert rollup_counts() == state_counts()
      assert pushes(fixture) == before

      # The merged source never cut over, so it was moved to legacy semantics, with a
      # record, and pushes exactly what the mirror made it push.
      assert semantics(fixture.merged.source) == :legacy
      assert [{"merged", "legacy", reason}] = semantics_changes(fixture.merged.source)
      assert reason =~ "preserved the pre-cutover northbound value"
      assert semantics(fixture.pinned.source) == :merged
      assert semantics_changes(fixture.pinned.source) == []
      assert ledger_rows(fixture) == ledger_before
      assert_rollout_objects_gone!()
    end
  end

  test "upgrading from authoritative changes no value and announces nothing", %{actor: actor} do
    fixture = upgrade_fixture!(actor, "authoritative")
    before = pushes(fixture)
    ledger_before = ledger_rows(fixture)
    legacy_before = legacy_rows(fixture)

    # What adopting merged semantics would change for the legacy source: the access point
    # (legacy down, merged up) changes, and the two devices merged leaves unknown are
    # withheld. The preview reads the merged state as it did once cut over.
    preview = ArmisAvailabilityPreview.build(fixture.legacy.source)
    assert %{linked_ids: 3, would_change: 1, withheld: 2} = preview

    assert job_args = upgrade!()
    assert job_args["announce"] == false

    assert {true, "available"} = device_row(fixture.merged.ap)
    assert semantics(fixture.merged.source) == :merged
    assert semantics_changes(fixture.merged.source) == []
    assert legacy_rows(fixture) == legacy_before
    assert pushes(fixture) == before
    assert ArmisAvailabilityPreview.build(fixture.legacy.source) == preview
    assert ledger_rows(fixture) == ledger_before
    assert_rollout_objects_gone!()
  end

  test "after the upgrade a new device has a legacy value and the legacy writers keep it",
       %{actor: actor} do
    fixture = upgrade_fixture!(actor, "legacy")
    assert upgrade!()

    source = reload(fixture.legacy.source)
    ip = TestSupport.unique_device_ip()
    ingest_armis!(actor, source, ip, "armis-after-upgrade", true)
    device = device_by_ip(ip)

    # The resolver has no evidence for it, so the merged column cannot be what is pushed.
    {:ok, _} = Availability.resolve_devices([device.uid])
    assert {false, "unknown"} = device_row(device)
    assert legacy_value(device) == true
    assert pushed(source, "armis-after-upgrade") == true

    # A later legacy write moves the compatibility value, never the device row.
    ingest_armis!(actor, source, ip, "armis-after-upgrade", false)
    assert legacy_value(device) == false
    assert {false, "unknown"} = device_row(device)
    assert pushed(source, "armis-after-upgrade") == false
  end

  # -- the pre-upgrade deployment --------------------------------------------------------

  # Three Armis sources, each with its own linked devices:
  #   legacy - an existing source in legacy semantics;
  #   merged - a source created with merged semantics and no agent;
  #   pinned - a source pushing one agent's per-agent results.
  # The canonical sources each link an access point the controller reports up while the
  # legacy hysteresis holds it down, a device with no evidence that the legacy value holds
  # up, and a device whose legacy value is NULL.
  defp upgrade_fixture!(actor, mode) do
    pre_upgrade_schema!(mode)

    legacy_source = actor |> create_source!("SITE01 legacy") |> keep_legacy_semantics!()
    merged_source = create_source!(actor, "SITE01 merged")

    pinned_source =
      create_source!(actor, "SITE01 pinned", northbound_availability_source_agent_id: "agent-pin")

    legacy = canonical_devices!(actor, legacy_source, mode)
    merged = canonical_devices!(actor, merged_source, mode)
    pinned = pinned_devices!(actor, pinned_source)

    if mode == "shadow" do
      Repo.query!("INSERT INTO platform.device_availability_shadow (device_uid) VALUES ($1)", [
        legacy.ap.uid
      ])
    end

    %{legacy: legacy, merged: merged, pinned: pinned}
  end

  defp pre_upgrade_schema!(mode) do
    Repo.query!("DROP TABLE platform.integration_source_availability_semantics_changes")

    Repo.query!(
      "ALTER TABLE platform.availability_settings ADD COLUMN mode text NOT NULL DEFAULT 'legacy'"
    )

    Repo.query!("""
    INSERT INTO platform.availability_settings (singleton) VALUES (true)
    ON CONFLICT (singleton) DO NOTHING
    """)

    Repo.query!("UPDATE platform.availability_settings SET mode = $1, expiry_watermark = NULL", [
      mode
    ])

    Repo.query!("""
    CREATE FUNCTION platform.availability_mode() RETURNS text LANGUAGE sql STABLE AS $$
      SELECT COALESCE((SELECT mode FROM platform.availability_settings WHERE singleton), 'legacy')
    $$
    """)

    Repo.query!("CREATE TABLE platform.device_availability_shadow (device_uid text PRIMARY KEY)")

    if mode in ["legacy", "shadow"] do
      Repo.query!("""
      CREATE TRIGGER trg_ocsf_devices_availability_legacy_update
      AFTER UPDATE OF is_available ON platform.ocsf_devices
      FOR EACH ROW WHEN (OLD.is_available IS DISTINCT FROM NEW.is_available)
      EXECUTE FUNCTION platform.trg_ocsf_devices_availability_legacy()
      """)
    end
  end

  defp canonical_devices!(actor, source, mode) do
    [ap, steady, nulled] =
      for {name, available?} <- [{"ap", false}, {"steady", true}, {"nulled", nil}] do
        ip = TestSupport.unique_device_ip()
        ingest_armis!(actor, source, ip, "#{source.name} #{name}", available?)
        Map.put(device_by_ip(ip), :armis_id, "#{source.name} #{name}")
      end

    # The controller reports the access point up.
    {:ok, _} = Availability.record_evidence([wifi(ap.uid, :up, minutes_ago(2))])

    case mode do
      mode when mode in ["legacy", "shadow"] ->
        # The legacy writers' values, with the mirror the pre-upgrade release kept. The
        # access point predates the compatibility table, so it has no row there, and
        # neither has the device whose value is NULL.
        for {device, available?} <- [{ap, false}, {steady, true}, {nulled, nil}] do
          legacy_mirror!(device, available?)
        end

        Repo.query!(
          "DELETE FROM platform.device_availability_legacy WHERE device_uid = ANY($1::text[])",
          [[ap.uid, nulled.uid]]
        )

      "authoritative" ->
        # Seeded at cutover and kept by the legacy writers; the resolver owns the rows.
        for {device, available?} <- [{ap, false}, {steady, true}, {nulled, nil}] do
          Repo.query!(
            """
            INSERT INTO platform.device_availability_legacy (device_uid, is_available)
            VALUES ($1, $2)
            ON CONFLICT (device_uid) DO UPDATE SET is_available = EXCLUDED.is_available
            """,
            [device.uid, available?]
          )
        end

        {:ok, _} = Availability.resolve_devices([ap.uid, steady.uid, nulled.uid])
    end

    activate_collection!(source, [ap, steady, nulled])
    %{source: source, ap: ap, steady: steady, nulled: nulled}
  end

  # The agent the source pins can reach one device and not the other; another agent
  # disagrees with it on both.
  defp pinned_devices!(actor, source) do
    devices =
      for {name, pinned?} <- [{"reached", true}, {"blocked", false}] do
        ip = TestSupport.unique_device_ip()
        ingest_armis!(actor, source, ip, "#{source.name} #{name}", true)
        device = Map.put(device_by_ip(ip), :armis_id, "#{source.name} #{name}")
        ledger_row!(actor, device, "agent-pin", pinned?, minutes_ago(3))
        ledger_row!(actor, device, "agent-other", not pinned?, minutes_ago(3))
        device
      end

    activate_collection!(source, devices)
    %{source: source, devices: devices}
  end

  # Two devices no writer has touched since before availability capture: no provenance,
  # the column default state, a legacy value that holds them up. One has a fresh up result
  # from an agent, the other no evidence at all.
  defp pre_capture_devices!(actor) do
    [probed, silent] =
      for _ <- 1..2 do
        device = create_device!(actor, TestSupport.unique_device_ip())

        Repo.query!(
          """
          UPDATE platform.ocsf_devices
          SET is_available = true, availability_state = 'unknown',
              availability_decided_by = NULL, availability_changed_at = NULL,
              availability_agents = NULL
          WHERE uid = $1
          """,
          [device.uid]
        )

        device
      end

    ledger_row!(actor, probed, "agent-pre-capture", true, minutes_ago(1))
    {probed, silent}
  end

  defp legacy_mirror!(device, available?) do
    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET is_available = $2,
          availability_state = platform.availability_projection($2),
          availability_decided_by = jsonb_build_object('rule', 'legacy_mirror'),
          availability_conflict = false,
          availability_agents = NULL
      WHERE uid = $1
      """,
      [device.uid, available?]
    )
  end

  # -- the upgrade ------------------------------------------------------------------------

  # Runs the migration's statements, then the reconciliation it enqueued. Returns that
  # job's arguments.
  defp upgrade! do
    Enum.each(Migration.statements(), &Repo.query!/1)

    %{rows: [[args]]} =
      Repo.query!(
        """
        SELECT args FROM platform.oban_jobs
        WHERE worker = $1 AND args ->> 'phase' = 'reconcile'
        ORDER BY id DESC LIMIT 1
        """,
        [inspect(ReconcileWorker)]
      )

    assert :ok = ReconcileWorker.perform(%Oban.Job{args: args})
    args
  end

  defp assert_rollout_objects_gone! do
    assert %{rows: [[nil, nil, nil]]} =
             Repo.query!("""
             SELECT to_regclass('platform.device_availability_shadow'),
                    to_regprocedure('platform.availability_mode()'),
                    (SELECT attname FROM pg_attribute
                     WHERE attrelid = 'platform.availability_settings'::regclass
                       AND attname = 'mode' AND NOT attisdropped)
             """)

    assert %{rows: [[false]]} =
             Repo.query!("""
             SELECT EXISTS (
               SELECT 1 FROM pg_trigger
               WHERE tgrelid = 'platform.ocsf_devices'::regclass
                 AND tgname IN ('trg_ocsf_devices_availability_mirror',
                                'trg_ocsf_devices_availability_legacy_update')
             )
             """)
  end

  # -- what each source pushes -------------------------------------------------------------

  # The production push path: the source's population over its activated collection,
  # eligible ids with their values, and withheld ids with their reasons.
  defp pushes(fixture) do
    for key <- [:legacy, :merged, :pinned], into: %{} do
      source = reload(Map.fetch!(fixture, key).source)
      assert {:ok, population} = ArmisNorthboundPopulation.load(source)

      {key,
       %{
         pushed: Enum.map(population.candidates, &{&1.armis_device_id, &1.is_available}),
         withheld: Enum.map(population.withheld, &{&1.source_object_id, &1.reason})
       }}
    end
  end

  defp pushed(source, armis_id) do
    source
    |> ArmisNorthboundRunner.candidates_query()
    |> Repo.all()
    |> Enum.find(&(&1.armis_device_id == armis_id))
    |> Map.fetch!(:is_available)
  end

  defp reload(source), do: Ash.get!(IntegrationSource, source.id, authorize?: false)
  defp semantics(source), do: reload(source).northbound_availability_semantics

  defp semantics_changes(source) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT from_semantics, to_semantics, reason
        FROM platform.integration_source_availability_semantics_changes
        WHERE integration_source_id = $1 ORDER BY id
        """,
        [Ecto.UUID.dump!(source.id)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  # -- reads ------------------------------------------------------------------------------

  defp fixture_uids(fixture) do
    canonical =
      for key <- [:legacy, :merged], d <- [:ap, :steady, :nulled], do: fixture[key][d].uid

    canonical ++ Enum.map(fixture.pinned.devices, & &1.uid)
  end

  defp ledger_rows(fixture) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT to_jsonb(a) FROM platform.device_agent_availability AS a
        WHERE device_uid = ANY($1::text[]) ORDER BY device_uid, agent_id
        """,
        [fixture_uids(fixture)]
      )

    rows
  end

  defp legacy_rows(fixture) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT device_uid, is_available, updated_at FROM platform.device_availability_legacy
        WHERE device_uid = ANY($1::text[]) ORDER BY device_uid
        """,
        [fixture_uids(fixture)]
      )

    rows
  end

  defp legacy_value(device) do
    %{rows: [[available?]]} =
      Repo.query!(
        "SELECT is_available FROM platform.device_availability_legacy WHERE device_uid = $1",
        [device.uid]
      )

    available?
  end

  defp device_row(device) do
    %{rows: [[available?, state]]} =
      Repo.query!(
        "SELECT is_available, availability_state FROM platform.ocsf_devices WHERE uid = $1",
        [device.uid]
      )

    {available?, state}
  end

  defp device_by_ip(ip) do
    %{rows: [[uid, hostname, mac]]} =
      Repo.query!(
        "SELECT uid, hostname, mac FROM platform.ocsf_devices WHERE ip = $1 AND deleted_at IS NULL",
        [ip]
      )

    %{uid: uid, ip: ip, hostname: hostname, mac: mac}
  end

  defp transitions_for(device) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT t FROM platform.oban_jobs AS j, jsonb_array_elements(j.args -> 'transitions') AS t
        WHERE j.worker = $1 AND t ->> 'uid' = $2
        """,
        [inspect(Transitions), device.uid]
      )

    rows
  end

  defp rollup_counts do
    %{rows: rows} =
      Repo.query!("""
      SELECT key, value FROM platform.device_inventory_counts
      WHERE key IN ('available', 'unavailable', 'unknown') AND value <> 0
      """)

    Map.new(rows, &List.to_tuple/1)
  end

  defp state_counts do
    %{rows: rows} =
      Repo.query!("""
      SELECT availability_state, count(*) FROM platform.ocsf_devices
      WHERE deleted_at IS NULL AND source_retired_at IS NULL
      GROUP BY availability_state
      """)

    Map.new(rows, &List.to_tuple/1)
  end

  # -- Armis fixtures ---------------------------------------------------------------------

  defp create_source!(actor, name, attrs \\ []) do
    attrs =
      Map.merge(
        %{
          name: name <> " " <> Ash.UUID.generate(),
          source_type: :armis,
          endpoint: "https://armis.example.invalid/#{System.unique_integer([:positive])}",
          northbound_enabled: true,
          custom_fields: ["availability"]
        },
        Map.new(attrs)
      )

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{secret_key: "secret", api_key: "api"})
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  # A source created before merged availability: `legacy` semantics, which new sources
  # cannot choose.
  defp keep_legacy_semantics!(source) do
    Repo.query!(
      "UPDATE platform.integration_sources SET northbound_availability_semantics = 'legacy' WHERE id = $1",
      [Ecto.UUID.dump!(source.id)]
    )

    %{source | northbound_availability_semantics: :legacy}
  end

  defp ingest_armis!(actor, source, ip, armis_id, available?) do
    update = %{
      "ip" => ip,
      "mac" => unique_mac(),
      "hostname" => "armis-" <> String.replace(ip, ".", "-") <> ".example.com",
      "source" => "armis",
      "is_available" => available?,
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_id" => armis_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{"sync_service_id" => source.id}
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)
  end

  defp activate_collection!(source, devices) do
    observed_at = ~U[2026-09-01 08:00:00.000000Z]
    content_hash = String.duplicate("a", 64)
    count = length(devices)

    snapshot = %{
      partition: "default",
      source: "armis",
      source_instance: to_string(source.id),
      collection_id: "collection-" <> Ash.UUID.generate(),
      content_hash: content_hash,
      query_hash: nil,
      observed_at: observed_at,
      metadata: %{
        "accounting_status" => "exact",
        "raw_rows" => count,
        "excluded_rows" => 0,
        "invalid_rows" => 0,
        "valid_occurrences" => count,
        "distinct_source_ids" => count,
        "duplicate_occurrences" => 0,
        "conflicting_duplicate_ids" => 0
      }
    }

    observations =
      Enum.map(devices, fn device ->
        %{
          device_id: device.uid,
          partition: "default",
          source: "armis",
          source_instance: snapshot.source_instance,
          source_object_id: device.armis_id,
          source_integration_id: "armis:source:#{source.id}:#{device.armis_id}",
          collection_id: snapshot.collection_id,
          content_hash: content_hash,
          query_hash: nil,
          present: true,
          first_observed_at: observed_at,
          last_observed_at: observed_at,
          absent_since: nil,
          hostname: device.hostname,
          ip: device.ip,
          mac: device.mac,
          serial_number: nil,
          vendor_name: nil,
          model: nil,
          device_type: nil,
          site_name: nil,
          management_status: nil,
          metadata: %{"identifier_metadata" => %{"sync_service_id" => to_string(source.id)}}
        }
      end)

    assert :ok = DeviceSourceObservationIngestor.activate_resolved(snapshot, observations)
  end

  defp unique_mac do
    [:positive]
    |> System.unique_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(10, "0")
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&"02:#{&1}")
  end
end
