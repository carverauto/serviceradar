defmodule ServiceRadar.Inventory.Identity.SourceRetirementTest do
  @moduledoc """
  Integration coverage for source identifier retirement (change `add-source-id-succession`,
  tasks 3.1-3.4, 6.1, 6.2, 14.1 and 14.4): an exact collection counts the absences it proves
  when it activates, and a retirement pass archives an identifier absent from N consecutive
  exact collections under one query and unreported for T, unless the pass is over the mass
  guard. A retirement that leaves its record retired-only marks the record `source_retired`,
  and the database holds the mark to that definition whichever writer touches the record.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.Identity.SourceRetirementWorker
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.Remediation.SourceIdentityRepair
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @prefix "platform"

  # N = 3 collections, T = 24 hours.
  @settings %{
    source_retirement_enabled: true,
    source_retirement_absent_collections: 3,
    source_retirement_min_absence_hours: 24,
    source_retirement_max_fraction: 0.5,
    source_retirement_guard_override: false
  }

  # The same, with no mass guard: for a test that retires most of its instance.
  @unguarded %{@settings | source_retirement_max_fraction: 1.0}

  @defaults %{
    source_retirement_enabled: true,
    source_retirement_absent_collections: 3,
    source_retirement_min_absence_hours: 24,
    source_retirement_max_fraction: 0.5,
    source_retirement_guard_override: false,
    source_retired_grace_days: 7,
    max_successions_per_run: 200
  }

  @doc false
  def forward_event([_, _, _, kind], measurements, metadata, {parent, source_instance}) do
    if metadata.source_instance == source_instance do
      send(parent, {:source_retirement, kind, measurements, metadata})
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, new_instance(SystemActor.system(:source_retirement_test), 0)}
  end

  describe "absence counting" do
    test "one absence holds the identifier", ctx do
      a = armis_record(ctx, 1)
      b = armis_record(ctx, 2)

      collect(ctx, 1, [a, b], hours: 0)
      collect(ctx, 2, [a], hours: 1)

      assert %{absent_count: 1} = absence(ctx, b)
      assert absence(ctx, a) == nil
      assert {:ok, %{status: :completed, retired: 0}} = retire(ctx, 100)
      assert held?(ctx, b)
    end

    test "a collection counts an absence once", ctx do
      a = armis_record(ctx, 1)
      b = armis_record(ctx, 2)

      collect(ctx, 1, [a, b])
      second = collect(ctx, 2, [a])

      assert {:ok, %{absent: 0}} = SourceRetirement.record_collection(second)
      assert %{absent_count: 1, collection_ids: [only]} = absence(ctx, b)
      assert only == second.collection_id
    end

    test "a collection that reports the identifier resets its count", ctx do
      a = armis_record(ctx, 1)
      b = armis_record(ctx, 2)

      collect(ctx, 1, [a, b])
      collect(ctx, 2, [a])
      collect(ctx, 3, [a])
      assert %{absent_count: 2} = absence(ctx, b)

      collect(ctx, 4, [a, b])
      assert absence(ctx, b) == nil

      collect(ctx, 5, [a])
      collect(ctx, 6, [a])
      assert %{absent_count: 2} = absence(ctx, b)
      assert {:ok, %{retired: 0}} = retire(ctx, 100)
      assert held?(ctx, b)
    end

    test "a collection that is not exact counts neither absence nor presence", ctx do
      a = armis_record(ctx, 1)
      b = armis_record(ctx, 2)

      collect(ctx, 1, [a, b])
      collect(ctx, 2, [a])
      collect(ctx, 3, [a])
      collect(ctx, 4, [a], exact: false)
      assert %{absent_count: 2} = absence(ctx, b)

      # While the latest collection is not exact, nothing retires.
      assert {:ok, %{status: :no_exact_collection}} = retire(ctx, 100)

      collect(ctx, 5, [a, b], exact: false)
      assert %{absent_count: 2} = absence(ctx, b)

      collect(ctx, 6, [a])
      assert %{absent_count: 3} = absence(ctx, b)
    end

    test "a change of collection query restarts the count", ctx do
      a = armis_record(ctx, 1)
      b = armis_record(ctx, 2)
      first_query = sha("query-1")
      second_query = sha("query-2")

      collect(ctx, 1, [a, b], query_hash: first_query)
      collect(ctx, 2, [a], query_hash: first_query)
      collect(ctx, 3, [a], query_hash: first_query)
      assert %{absent_count: 2, query_hash: ^first_query} = absence(ctx, b)

      collect(ctx, 4, [a], query_hash: second_query)

      assert %{absent_count: 1, query_hash: ^second_query, collection_ids: [restart]} =
               absence(ctx, b)

      assert restart == "#{ctx.inst}-c4"
      assert {:ok, %{retired: 0}} = retire(ctx, 100)
      assert held?(ctx, b)
    end

    test "a source with no exact collections never counts or retires", ctx do
      instance = %{ctx.instance | source: "netbox"}
      reported = netbox_record(ctx, 1)
      unreported = netbox_record(ctx, 2)

      for k <- 1..4, do: collect(ctx, k, [reported], source: "netbox")

      assert absences(ctx, "netbox") == []
      assert retirement_jobs(ctx) == []

      assert {:ok, %{status: :unscoped}} =
               SourceRetirement.run(instance,
                 settings: @settings,
                 now: DateTime.shift(ctx.t0, hour: 100),
                 actor: ctx.actor
               )

      assert {:error, :unscoped_source} =
               SourceIdentityRepair.dry_run("netbox", ctx.inst, settings: @settings)

      assert typed_id_holder(:netbox_device_id, unreported.source_id, "default") ==
               unreported.uid
    end
  end

  describe "retirement" do
    test "absent from N collections within T is not retired", ctx do
      {_a, b} = sustained_absence(ctx)

      assert %{absent_count: 3} = absence(ctx, b)
      assert {:ok, %{status: :completed, candidates: 0, retired: 0}} = retire(ctx, 6)
      assert held?(ctx, b)
      assert %{absent_count: 3} = absence(ctx, b)
    end

    test "sustained absence archives the identifier and records the proof", ctx do
      {a, b} = sustained_absence(ctx)
      revision = revision(b)
      attach_events(ctx)

      assert {:ok, %{status: :completed, retired: 1, devices: 1, failed: 0}} = retire(ctx, 30)

      refute held?(ctx, b)
      assert held?(ctx, a)
      assert absence(ctx, b) == nil
      assert revision(b) > revision

      assert [%{device_id: device_id, partition: partition, archive_reason: "source_absent"}] =
               archived(b)

      assert device_id == b.uid
      assert partition == ctx.id_partition

      {:ok, decisions} = IdentityDecision.for_device(b.uid, actor: ctx.actor)
      assert [decision] = Enum.filter(decisions, &(&1.decision_kind == :source_id_retired))
      assert decision.device_uids == [b.uid]
      assert decision.subject == b.source_id
      assert decision.reason == "source_absent"
      assert decision.evidence["identifier_type"] == "armis_device_id"
      assert decision.evidence["source_instance"] == ctx.inst
      assert decision.evidence["absent_collections"] == 3
      assert decision.evidence["collection_ids"] == Enum.map(2..4, &"#{ctx.inst}-c#{&1}")

      # The record stays live and keeps the retired id as history.
      assert {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(b.uid, true, actor: ctx.actor)

      {uid, source_id} = {b.uid, b.source_id}

      assert_received {:source_retirement, :retired, %{identifiers: 1},
                       %{
                         device_uid: ^uid,
                         identifier_type: :armis_device_id,
                         identifier_values: [^source_id]
                       }}

      refute_received {:source_retirement, :retired, _measurements, _metadata}
    end

    test "the integration id derived from a retired id retires with it", ctx do
      {a, b} = sustained_absence(ctx)

      for record <- [a, b],
          do:
            register(
              ctx,
              record.uid,
              :integration_id,
              integration_id(ctx, record),
              ctx.id_partition
            )

      # An integration id derived from another Armis id is not the retired id's: it stays.
      unrelated = integration_id(ctx, %{source_id: b.source_id <> "9"})
      register(ctx, b.uid, :integration_id, unrelated, ctx.id_partition)

      assert {:ok, %{retired: 1, devices: 1, failed: 0}} = retire(ctx, 30)

      assert typed_id_holder(:integration_id, integration_id(ctx, b), ctx.id_partition) == nil
      assert typed_id_holder(:integration_id, integration_id(ctx, a), ctx.id_partition) == a.uid
      assert typed_id_holder(:integration_id, unrelated, ctx.id_partition) == b.uid

      assert [%{device_id: device_id, archive_reason: "source_absent"}] =
               archived(:integration_id, integration_id(ctx, b))

      assert device_id == b.uid

      {:ok, decisions} = IdentityDecision.for_device(b.uid, actor: ctx.actor)
      assert [decision] = Enum.filter(decisions, &(&1.decision_kind == :source_id_retired))

      assert [%{"identifier_type" => "integration_id", "identifier_value" => value}] =
               decision.evidence["accompanying_identifiers"]

      assert value == integration_id(ctx, b)
    end

    test "a pass limited to some devices retires only theirs", ctx do
      a = armis_record(ctx, 1)
      b = armis_record(ctx, 2)
      c = armis_record(ctx, 3)
      d = armis_record(ctx, 4)

      collect(ctx, 1, [a, b, c, d], hours: 0)
      for k <- 2..4, do: collect(ctx, k, [a, d], hours: k)

      assert {:ok, %{retired: 1}} =
               SourceRetirement.run(ctx.instance,
                 settings: @settings,
                 now: DateTime.shift(ctx.t0, hour: 100),
                 actor: ctx.actor,
                 uids: [a.uid, b.uid, d.uid]
               )

      refute held?(ctx, b)
      assert held?(ctx, c)
    end

    test "the dry run classifies what a pass would retire and writes nothing", ctx do
      {a, b} = sustained_absence(ctx)

      assert {:ok, report} =
               SourceIdentityRepair.dry_run("armis", ctx.inst,
                 settings: @settings,
                 now: DateTime.shift(ctx.t0, hour: 30)
               )

      assert report.mode == "dry_run"
      assert report.identifier_type == "armis_device_id"
      assert report.collection_id == "#{ctx.inst}-c4"
      assert report.retirable_count == 1
      assert [row] = report.classifications
      assert row.device_uid == b.uid
      assert row.classification == "no_current_ids"
      assert row.retirable_ids == [b.source_id]
      assert row.proposed_action == "retire_stale_ids"
      refute row.device_uid == a.uid
      assert held?(ctx, b)
    end
  end

  describe "the source_retired mark" do
    test "a retirement that leaves the record retired-only marks it and hides it", ctx do
      {a, b} = sustained_absence(ctx)
      attach_events(ctx)

      assert {:ok, %{retired: 1, devices: 1, marked: 1}} = retire(ctx, 30)

      assert %Device{deleted_at: nil, source_retired_at: %DateTime{}} = marked = device!(ctx, b)
      assert marked.metadata["identity_state"] == "source_retired"
      assert %Device{source_retired_at: nil} = unmarked = device!(ctx, a)
      refute Map.has_key?(unmarked.metadata, "identity_state")
      assert retired_decision!(ctx, b).evidence["marked_source_retired"] == true

      uid = b.uid

      assert_received {:source_retirement, :retired, %{identifiers: 1},
                       %{device_uid: ^uid, marked: true}}

      # The inventory operators read leaves the record out unless asked; resolution reads it.
      both = Enum.sort([a.uid, b.uid])
      assert read_uids(ctx, :inventory, [a, b]) == [a.uid]
      assert read_uids(ctx, :inventory, [a, b], %{include_retired: true}) == both
      assert read_uids(ctx, :inventory, [a, b], %{include_deleted: true}) == both
      assert read_uids(ctx, :read, [a, b]) == both
    end

    test "a record an agent, another source, an operator or a recent observation claims is kept unmarked",
         ctx do
      a = armis_record(ctx, 1)

      [unclaimed, at_cutoff, agent, agent_identifier, netbox, manual, observed] =
        absent = Enum.map(2..8, &armis_record(ctx, &1))

      # The pass at hour 30 has its cutoff at hour 6: an observation at the cutoff is T old.
      cutoff = DateTime.shift(ctx.t0, hour: 6)
      put_column(at_cutoff, :identity_observed_at, DateTime.to_naive(cutoff))
      put_column(agent, :agent_id, "agent-#{ctx.n}")
      register(ctx, agent_identifier.uid, :agent_id, "agent-#{ctx.n}-id", "default")
      register(ctx, netbox.uid, :netbox_device_id, "nb-#{ctx.n}", "default")
      put_column(manual, :discovery_sources, ["armis", "manual"])

      put_column(
        observed,
        :identity_observed_at,
        cutoff |> DateTime.shift(second: 1) |> DateTime.to_naive()
      )

      collect(ctx, 1, [a | absent], hours: 0)
      for k <- 2..4, do: collect(ctx, k, [a], hours: 2 * (k - 1))
      attach_events(ctx)

      assert {:ok, %{retired: 7, devices: 7, marked: 2, failed: 0}} =
               retire(ctx, 30, @unguarded)

      expected = [
        {unclaimed, true},
        {at_cutoff, true},
        {agent, false},
        {agent_identifier, false},
        {netbox, false},
        {manual, false},
        {observed, false}
      ]

      for {{record, marked?}, label} <-
            Enum.zip(
              expected,
              ~w(unclaimed at_cutoff agent agent_identifier netbox manual observed)
            ) do
        refute held?(ctx, record), "#{label}: its id did not retire"
        assert is_struct(device!(ctx, record).source_retired_at, DateTime) == marked?, label

        assert retired_decision!(ctx, record).evidence["marked_source_retired"] == marked?,
               label

        uid = record.uid
        assert_received {:source_retirement, :retired, _, %{device_uid: ^uid, marked: ^marked?}}
      end
    end

    test "a marked record counts as inactive in the inventory rollups", ctx do
      {_a, b} = sustained_absence(ctx)
      total = inventory_total()

      assert {:ok, %{marked: 1}} = retire(ctx, 30)
      assert inventory_total() == total - 1

      # A rebuild counts as the trigger does.
      Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
      assert inventory_total() == active_devices()

      rebuilt = inventory_total()
      register_identifier(ctx, b.uid, :agent_id, "agent-#{ctx.n}", "default")
      assert inventory_total() == rebuilt + 1
    end

    test "an agent or source-authoritative identifier registered on a marked record clears the mark",
         ctx do
      for {type, i} <- Enum.with_index(SourceRetirement.marking_identifier_types(), 1) do
        record = marked_record(ctx, i)

        register_identifier(
          ctx,
          record.uid,
          type,
          "#{ctx.n}-#{type}",
          identifier_partition(ctx, type)
        )

        cleared = device!(ctx, record)
        assert cleared.source_retired_at == nil, "#{type} left the mark"
        refute Map.has_key?(cleared.metadata, "identity_state"), "#{type} left identity_state"
      end
    end

    test "an identifier a merge moves onto a marked record clears the mark", ctx do
      holder = armis_record(ctx, 1)
      record = marked_record(ctx, 2)

      {:ok, identifier} =
        DeviceIdentifier
        |> Ash.Query.filter(device_id == ^holder.uid and identifier_type == :armis_device_id)
        |> Ash.read_one(actor: ctx.actor)

      {:ok, _moved} =
        identifier
        |> Ash.Changeset.for_update(:reassign_device, %{device_id: record.uid})
        |> Ash.update(actor: ctx.actor)

      assert device!(ctx, record).source_retired_at == nil
    end

    test "address and other evidence registered on a marked record leaves the mark", ctx do
      record = marked_record(ctx, 1)
      marked_at = device!(ctx, record).source_retired_at
      evidence = identifier_types() -- SourceRetirement.marking_identifier_types()

      assert :mac in evidence and :ip in evidence

      for type <- evidence,
          do: register_identifier(ctx, record.uid, type, evidence_value(ctx, type), "default")

      assert %Device{source_retired_at: ^marked_at} = marked = device!(ctx, record)
      assert marked.metadata["identity_state"] == "source_retired"
    end
  end

  describe "mass guard" do
    test "a pass over the fraction retires nothing, logs the counts and emits telemetry", ctx do
      {_a, absent} = mass_absence(ctx)
      attach_events(ctx)

      log =
        capture_log(fn ->
          assert {:error,
                  {:mass_retirement_refused, %{candidates: 3, live: 4, max_fraction: 0.5}}} =
                   retire(ctx, 100)
        end)

      assert log =~ "pass refused (mass_deletion)"
      assert log =~ "from 3 of 4 live records"

      assert_received {:source_retirement, :refused, %{candidates: 3, live_devices: 4},
                       %{reason: :mass_deletion, source: "armis"}}

      refute_received {:source_retirement, :retired, _measurements, _metadata}

      for record <- absent do
        assert held?(ctx, record)
        assert archived(record) == []
        assert %{absent_count: 3} = absence(ctx, record)
      end
    end

    test "the override admits one refused pass, which clears it", ctx do
      {_a, absent} = mass_absence(ctx)
      stored = settings!(ctx.actor)

      {:ok, _stored} =
        DeviceCleanupSettings.update_settings(
          stored,
          %{source_retirement_guard_override: true},
          actor: ctx.actor
        )

      overridden = %{@settings | source_retirement_guard_override: true}

      capture_log(fn ->
        assert {:ok, %{status: :completed, retired: 3, devices: 3}} =
                 retire(ctx, 100, overridden)
      end)

      for record <- absent, do: refute(held?(ctx, record))

      assert {:ok, %DeviceCleanupSettings{source_retirement_guard_override: false}} =
               DeviceCleanupSettings.get_settings(actor: ctx.actor)

      # The override is spent: a second instance's pass over the guard is refused, even under
      # the settings read before the override was cleared.
      other = new_instance(ctx.actor, 10)
      {_other_a, other_absent} = mass_absence(other)

      capture_log(fn ->
        assert {:error, {:mass_retirement_refused, %{candidates: 3, live: 4}}} =
                 retire(other, 100, overridden)
      end)

      for record <- other_absent, do: assert(held?(other, record))
    end
  end

  describe "queuing and the worker" do
    test "an exact activation queues one pass for its instance", ctx do
      a = armis_record(ctx, 1)

      collect(ctx, 1, [a])
      collect(ctx, 2, [a])

      assert [%Oban.Job{args: args, queue: "maintenance"}] = retirement_jobs(ctx)

      assert args == %{
               "partition" => "default",
               "source" => "armis",
               "source_instance" => ctx.inst
             }
    end

    test "a collection that is not exact queues none", ctx do
      a = armis_record(ctx, 1)

      collect(ctx, 1, [a], exact: false)

      assert retirement_jobs(ctx) == []
    end

    test "the worker runs a pass under the stored settings", ctx do
      {a, b} = sustained_absence(ctx)
      stored_settings!(ctx, %{})

      assert :ok = SourceRetirementWorker.perform(%Oban.Job{args: job_args(ctx)})

      refute held?(ctx, b)
      assert held?(ctx, a)
    end

    test "the worker retires nothing while retirement is disabled", ctx do
      {_a, b} = sustained_absence(ctx)
      stored_settings!(ctx, %{source_retirement_enabled: false})

      assert :ok = SourceRetirementWorker.perform(%Oban.Job{args: job_args(ctx)})

      assert held?(ctx, b)
    end

    test "the worker cancels a job without an instance" do
      assert {:cancel, :invalid_args} = SourceRetirementWorker.perform(%Oban.Job{args: %{}})
    end
  end

  describe "settings" do
    test "a settings row from before retirement and a new one read the same defaults", ctx do
      delete_settings_row()

      # A row that existed when the retirement columns were added reads their column defaults.
      Repo.query!("INSERT INTO platform.device_cleanup_settings (key) VALUES ('default')")
      assert Map.take(settings!(ctx.actor), Map.keys(@defaults)) == @defaults

      delete_settings_row()
      assert {:ok, created} = DeviceCleanupSettings.create_settings(%{}, actor: ctx.actor)
      assert Map.take(created, Map.keys(@defaults)) == @defaults
    end

    test "out-of-range retirement settings are refused", ctx do
      settings = settings!(ctx.actor)

      for changes <- [
            %{source_retirement_absent_collections: 1},
            %{source_retirement_min_absence_hours: 0},
            %{source_retirement_max_fraction: 0.0},
            %{source_retired_grace_days: 0},
            %{max_successions_per_run: -1}
          ] do
        assert {:error, _} =
                 DeviceCleanupSettings.update_settings(settings, changes, actor: ctx.actor),
               "accepted #{inspect(changes)}"
      end
    end
  end

  # One Armis source instance per test. t0 lies ten days back, so the collections and passes a
  # test places after it are in the past. `ip_base` keeps the addresses of two instances in one
  # test apart.
  defp new_instance(actor, ip_base) do
    n = System.unique_integer([:positive, :monotonic])
    inst = "retirement-test-#{n}"

    %{
      actor: actor,
      n: n,
      inst: inst,
      ip_base: ip_base,
      instance: %{partition: "default", source: "armis", source_instance: inst},
      id_partition: "default:armis:#{inst}",
      t0: DateTime.utc_now() |> DateTime.shift(day: -10) |> DateTime.truncate(:microsecond)
    }
  end

  # Records a and b; b is absent from collections 2-4, observed 2, 4 and 6 hours after t0.
  defp sustained_absence(ctx) do
    a = armis_record(ctx, 1)
    b = armis_record(ctx, 2)

    collect(ctx, 1, [a, b], hours: 0)
    for k <- 2..4, do: collect(ctx, k, [a], hours: 2 * (k - 1))

    {a, b}
  end

  # Four records, three of them absent from collections 2-4: retiring them all is more than
  # half of the instance's live records.
  defp mass_absence(ctx) do
    [a | absent] = records = Enum.map(1..4, &armis_record(ctx, &1))

    collect(ctx, 1, records, hours: 0)
    for k <- 2..4, do: collect(ctx, k, [a], hours: k)

    {a, absent}
  end

  defp armis_record(ctx, i) do
    device = create_device(ctx, i)
    source_id = "#{ctx.n}0#{i}"
    register(ctx, device.uid, :armis_device_id, source_id, ctx.id_partition)
    %{uid: device.uid, source_id: source_id}
  end

  defp netbox_record(ctx, i) do
    device = create_device(ctx, i)
    source_id = "nb-#{ctx.n}-#{i}"
    register(ctx, device.uid, :netbox_device_id, source_id, "default")
    %{uid: device.uid, source_id: source_id}
  end

  defp create_device(ctx, i) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        ip: "192.0.2.#{ctx.ip_base + i}",
        hostname: "retirement-#{ctx.n}-#{i}"
      })
      |> Ash.create(actor: ctx.actor)

    device
  end

  # Registers the identifier, then backdates its sightings to t0, so only the collections
  # decide when it was last reported.
  defp register(ctx, uid, type, value, partition) do
    register_identifier(ctx, uid, type, value, partition)

    {1, _} =
      Repo.update_all(
        from(di in "device_identifiers",
          where:
            di.identifier_type == ^Atom.to_string(type) and di.identifier_value == ^value and
              di.partition == ^partition
        ),
        [set: [first_seen: DateTime.to_naive(ctx.t0), last_seen: DateTime.to_naive(ctx.t0)]],
        prefix: @prefix
      )
  end

  # One INSERT, as an ingest registration is: the statement the mark-clearing trigger sees.
  defp register_identifier(ctx, uid, type, value, partition) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: uid,
        identifier_type: type,
        identifier_value: value,
        partition: partition,
        confidence: :strong,
        source: "test"
      })
      |> Ash.create(actor: ctx.actor)
  end

  defp identifier_partition(ctx, :armis_device_id), do: ctx.id_partition
  defp identifier_partition(_ctx, _type), do: "default"

  defp identifier_types do
    DeviceIdentifier
    |> Ash.Resource.Info.attribute(:identifier_type)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
  end

  defp evidence_value(_ctx, :mac), do: "00005E005301"
  defp evidence_value(ctx, :ip), do: "192.0.2.#{ctx.ip_base + 99}"
  defp evidence_value(ctx, type), do: "#{ctx.n}-#{type}"

  # A record marked as SourceRetirement marks it; the mirror trigger sets identity_state.
  defp marked_record(ctx, i) do
    device = create_device(ctx, i)

    %{num_rows: 1} =
      Repo.query!("UPDATE platform.ocsf_devices SET source_retired_at = $2 WHERE uid = $1", [
        device.uid,
        NaiveDateTime.utc_now()
      ])

    %{uid: device.uid}
  end

  # Writes a column no device action accepts, as the writer that owns it does.
  defp put_column(record, column, value)
       when column in [:agent_id, :discovery_sources, :identity_observed_at] do
    %{num_rows: 1} =
      Repo.query!("UPDATE platform.ocsf_devices SET #{column} = $2 WHERE uid = $1", [
        record.uid,
        value
      ])
  end

  defp device!(ctx, record) do
    {:ok, device} = Device.get_by_uid(record.uid, false, actor: ctx.actor)
    device
  end

  defp retired_decision!(ctx, record) do
    {:ok, decisions} = IdentityDecision.for_device(record.uid, actor: ctx.actor)
    [decision] = Enum.filter(decisions, &(&1.decision_kind == :source_id_retired))
    decision
  end

  defp read_uids(ctx, action, records, args \\ %{}) do
    uids = Enum.map(records, & &1.uid)

    {:ok, devices} =
      Device
      |> Ash.Query.for_read(action, args, actor: ctx.actor)
      |> Ash.Query.filter(uid in ^uids)
      |> Ash.read(actor: ctx.actor)
      |> Page.unwrap()

    devices |> Enum.map(& &1.uid) |> Enum.sort()
  end

  defp inventory_total do
    %{rows: [[total]]} =
      Repo.query!(
        "SELECT COALESCE((SELECT value FROM platform.device_inventory_counts WHERE key = 'total'), 0)"
      )

    total
  end

  defp active_devices do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.ocsf_devices WHERE deleted_at IS NULL AND source_retired_at IS NULL"
      )

    count
  end

  # Activates collection k of the instance, observed `hours` (default k) after t0, reporting
  # `present`. Returns the snapshot.
  defp collect(ctx, k, present, opts \\ []) do
    source = Keyword.get(opts, :source, "armis")
    collection_id = "#{ctx.inst}-c#{k}"
    content_hash = sha(collection_id)
    query_hash = Keyword.get(opts, :query_hash)
    observed_at = DateTime.shift(ctx.t0, hour: Keyword.get(opts, :hours, k))

    snapshot = %{
      partition: "default",
      source: source,
      source_instance: ctx.inst,
      collection_id: collection_id,
      content_hash: content_hash,
      query_hash: query_hash,
      observed_at: observed_at,
      metadata:
        if(Keyword.get(opts, :exact, true), do: %{"accounting_status" => "exact"}, else: %{})
    }

    observations =
      Enum.map(present, fn record ->
        %{
          device_id: record.uid,
          partition: "default",
          source: source,
          source_instance: ctx.inst,
          source_object_id: record.source_id,
          source_integration_id: "#{source}:source:#{ctx.inst}:#{record.source_id}",
          collection_id: collection_id,
          content_hash: content_hash,
          query_hash: query_hash,
          present: true,
          first_observed_at: observed_at,
          last_observed_at: observed_at,
          absent_since: nil,
          hostname: nil,
          ip: nil,
          mac: nil,
          serial_number: nil,
          vendor_name: nil,
          model: nil,
          device_type: nil,
          site_name: nil,
          management_status: nil,
          metadata: %{}
        }
      end)

    assert :ok = DeviceSourceObservationIngestor.activate_resolved(snapshot, observations)
    snapshot
  end

  defp retire(ctx, hours, settings \\ @settings) do
    SourceRetirement.run(ctx.instance,
      settings: settings,
      now: DateTime.shift(ctx.t0, hour: hours),
      actor: ctx.actor
    )
  end

  defp absence(ctx, record) do
    Repo.one(
      from(a in "source_identifier_absences",
        where:
          a.partition == "default" and a.source == "armis" and a.source_instance == ^ctx.inst and
            a.source_object_id == ^record.source_id,
        select: %{
          absent_count: a.absent_count,
          query_hash: a.query_hash,
          collection_ids: a.collection_ids
        }
      ),
      prefix: @prefix
    )
  end

  defp absences(ctx, source) do
    Repo.all(
      from(a in "source_identifier_absences",
        where: a.source == ^source and a.source_instance == ^ctx.inst,
        select: a.source_object_id
      ),
      prefix: @prefix
    )
  end

  defp held?(ctx, record),
    do: typed_id_holder(:armis_device_id, record.source_id, ctx.id_partition) == record.uid

  defp typed_id_holder(type, value, partition) do
    Repo.one(
      from(di in "device_identifiers",
        where:
          di.identifier_type == ^Atom.to_string(type) and di.identifier_value == ^value and
            di.partition == ^partition,
        select: di.device_id
      ),
      prefix: @prefix
    )
  end

  defp archived(record), do: archived(:armis_device_id, record.source_id)

  defp archived(type, value) do
    Repo.all(
      from(a in "device_identifier_archive",
        where: a.identifier_type == ^Atom.to_string(type) and a.identifier_value == ^value,
        select: %{
          device_id: a.device_id,
          partition: a.partition,
          archive_reason: a.archive_reason
        }
      ),
      prefix: @prefix
    )
  end

  # The integration id an Armis update carries for its device id.
  defp integration_id(ctx, record), do: "armis:#{ctx.inst}:device:#{record.source_id}"

  defp revision(record) do
    Repo.one(from(d in "ocsf_devices", where: d.uid == ^record.uid, select: d.identity_revision),
      prefix: @prefix
    )
  end

  defp retirement_jobs(ctx) do
    worker = Oban.Worker.to_string(SourceRetirementWorker)

    from(job in Oban.Job, where: job.worker == ^worker)
    |> Repo.all()
    |> Enum.filter(&(&1.args["source_instance"] == ctx.inst))
  end

  defp job_args(ctx),
    do: %{"partition" => "default", "source" => "armis", "source_instance" => ctx.inst}

  defp attach_events(ctx) do
    handler_id = "source-retirement-events-#{ctx.n}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :inventory, :source_retirement, :refused],
          [:serviceradar, :inventory, :source_retirement, :retired]
        ],
        &__MODULE__.forward_event/4,
        {self(), ctx.inst}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp settings!(actor) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} -> settings
      _ -> DeviceCleanupSettings.create_settings!(%{}, actor: actor)
    end
  end

  defp delete_settings_row,
    do: Repo.query!("DELETE FROM platform.device_cleanup_settings WHERE key = 'default'")

  # The stored settings the worker reads: the module's N and T with `changes` on top.
  defp stored_settings!(ctx, changes) do
    {:ok, settings} =
      DeviceCleanupSettings.update_settings(
        settings!(ctx.actor),
        Map.merge(@settings, changes),
        actor: ctx.actor
      )

    settings
  end

  defp sha(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
