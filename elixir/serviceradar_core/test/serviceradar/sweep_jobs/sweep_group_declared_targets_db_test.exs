defmodule ServiceRadar.SweepJobs.SweepGroupDeclaredTargetsDbTest do
  @moduledoc """
  Regression coverage for issue #4963: the declared side of
  `platform.device_sweep_overlap` is persisted per sweep group, and the view
  reports every relationship class.

  Before the fix no production path wrote `config_type = 'sweep'` rows to
  `agent_config_instances`, so the view's declared arm was always empty and
  `declared_not_observed` / `declared_and_observed` could never appear. Every
  test in the "view relationship classes" describe block fails on that shape:
  with no declared rows the declared classes return zero rows and the observed
  rows these tests assert against are missing their declared counterparts.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.DeclaredTargets
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupDeclaredTarget
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])

    actor = %{
      id: Ash.UUID.generate(),
      email: "declared-targets-#{unique}@serviceradar.local",
      role: :admin
    }

    {:ok, actor: actor, unique: unique}
  end

  describe "declared-target persistence" do
    test "creating a group persists its declared targets before create returns", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} = create_group(actor, unique, %{static_targets: ["198.51.100.21"]})

      assert MapSet.new(declared_rows(actor, group.id), & &1.target) ==
               MapSet.new(["198.51.100.21"])
    end

    test "persists static and SRQL-resolved targets once per group", %{
      actor: actor,
      unique: unique
    } do
      # Two devices inside the SRQL range, one outside; the static target
      # 192.0.2.10 overlaps the first device so the two declarations must
      # collapse to a single row carrying the device uid.
      {:ok, _inside} = create_device(actor, "dev-inside-1-#{unique}", "192.0.2.10")
      {:ok, _inside2} = create_device(actor, "dev-inside-2-#{unique}", "192.0.2.11")
      {:ok, _outside} = create_device(actor, "dev-outside-#{unique}", "203.0.113.50")

      {:ok, group} =
        create_group(actor, unique, %{
          target_query: "in:devices ip:192.0.2.0/24",
          static_targets: ["192.0.2.10", "198.51.100.0/24"]
        })

      assert {:ok, _} = DeclaredTargets.refresh(group)

      rows = declared_rows(actor, group.id)

      # The overlapping target is ONE row carrying the device uid (source
      # srql wins over static), and the whole relation is one row per target
      # for the group -- never one per agent.
      assert Map.new(rows, &{&1.target, {&1.device_uid, &1.source}}) == %{
               "192.0.2.10" => {"dev-inside-1-#{unique}", :srql},
               "192.0.2.11" => {"dev-inside-2-#{unique}", :srql},
               "198.51.100.0/24" => {nil, :static}
             }
    end

    test "refresh prunes targets the group no longer declares", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} =
        create_group(actor, unique, %{static_targets: ["198.51.100.7", "198.51.100.8"]})

      assert {:ok, _} = DeclaredTargets.refresh(group)

      assert MapSet.new(declared_rows(actor, group.id), & &1.target) ==
               MapSet.new(["198.51.100.7", "198.51.100.8"])

      {:ok, updated} =
        group
        |> Ash.Changeset.for_update(:update, %{static_targets: ["198.51.100.8"]}, actor: actor)
        |> Ash.update()

      assert {:ok, _} = DeclaredTargets.refresh(updated)

      assert MapSet.new(declared_rows(actor, group.id), & &1.target) ==
               MapSet.new(["198.51.100.8"])
    end

    test "deleting the group deletes its declared targets", %{actor: actor, unique: unique} do
      {:ok, group} = create_group(actor, unique, %{static_targets: ["198.51.100.9"]})
      assert {:ok, _} = DeclaredTargets.refresh(group)
      assert [_] = declared_rows(actor, group.id)

      assert :ok = Ash.destroy(group, actor: actor)
      assert [] = declared_rows(actor, group.id)
    end
  end

  describe "view relationship classes" do
    test "declared_not_observed reports a static target nobody swept", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} = create_group(actor, unique, %{static_targets: ["198.51.100.7"]})
      assert {:ok, _} = DeclaredTargets.refresh(group)

      [row] = overlap_rows(group.id)

      assert row["relationship"] == "declared_not_observed"
      assert row["declared"] == true
      assert row["observed"] == false
      assert row["declared_target"] == "198.51.100.7"
      assert row["ip"] == "198.51.100.7"
      # Partition-wide group: one declaration compatible with any agent.
      assert row["agent_id"] == nil
      assert row["declared_at"]
    end

    test "declared_and_observed reports a declared target with coverage", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} = create_group(actor, unique, %{static_targets: ["203.0.113.5"]})
      assert {:ok, _} = DeclaredTargets.refresh(group)

      insert_coverage("203.0.113.5",
        device_uid: "dev-observed-#{unique}",
        sweep_group_id: group.id,
        agent_id: "scanner-observed-#{unique}"
      )

      [row] = overlap_rows(group.id)

      assert row["relationship"] == "declared_and_observed"
      assert row["declared"] == true
      assert row["observed"] == true
      assert row["device_uid"] == "dev-observed-#{unique}"
      assert row["ip"] == "203.0.113.5"
      assert row["observed_ip"] == "203.0.113.5"
      # The group is partition-wide, so its declaration carries a NULL agent
      # and the match across that NULL is reported as inferred -- the compat
      # semantics the view has always had.
      assert row["match_kind"] == "inferred_agent"
      assert row["match_via"] == "host"
    end

    test "observed_not_declared reports coverage no group declares", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} = create_group(actor, unique, %{static_targets: ["203.0.113.5"]})
      assert {:ok, _} = DeclaredTargets.refresh(group)

      insert_coverage("203.0.113.99",
        device_uid: "dev-orphan-#{unique}",
        sweep_group_id: group.id,
        agent_id: "scanner-observed-#{unique}"
      )

      # The group also declares 203.0.113.5, which nobody swept, so its own
      # declared_not_observed row is in the result; the assertion is about
      # the coverage row no declaration covers.
      [row] =
        Enum.filter(overlap_rows(group.id), &(&1["relationship"] == "observed_not_declared"))

      assert row["declared"] == false
      assert row["observed"] == true
      assert row["device_uid"] == "dev-orphan-#{unique}"
      assert row["ip"] == "203.0.113.99"
    end

    test "a fixed-subset group declares per selected agent", %{
      actor: actor,
      unique: unique
    } do
      scanner_a = "scanner-a-#{unique}"
      scanner_b = "scanner-b-#{unique}"
      create_agent(actor, scanner_a)
      create_agent(actor, scanner_b)

      {:ok, group} =
        create_group(actor, unique, %{
          static_targets: ["198.51.100.8"],
          agent_ids: [scanner_a, scanner_b]
        })

      assert {:ok, _} = DeclaredTargets.refresh(group)

      insert_coverage("198.51.100.8",
        device_uid: "dev-fixed-#{unique}",
        sweep_group_id: group.id,
        agent_id: scanner_a
      )

      rows = overlap_rows(group.id)

      # scanner-a swept the declared target; scanner-b owes it and has not.
      assert [
               %{"relationship" => "declared_and_observed", "agent_id" => agent_a},
               %{"relationship" => "declared_not_observed", "agent_id" => agent_b}
             ] = Enum.sort_by(rows, & &1["relationship"])

      assert agent_a == scanner_a
      assert agent_b == scanner_b
    end
  end

  describe "recording at compile time" do
    setup do
      # Shared target query results and recorded digests outlive a test's
      # sandbox; start cold.
      ConfigCache.invalidate(:sweep)
      :ok
    end

    test "a device added after the group was created is declared once a config compiles", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} = create_group(actor, unique, %{target_query: "in:devices ip:203.0.113.0/24"})
      assert declared_rows(actor, group.id) == []

      {:ok, device} = create_device(actor, "dev-later-#{unique}", "203.0.113.60")

      # The shared query result would expire on its TTL in production.
      ConfigCache.invalidate(:sweep)
      assert {:ok, _config} = SweepCompiler.compile("default", nil)

      assert Map.new(declared_rows(actor, group.id), &{&1.target, {&1.device_uid, &1.source}}) ==
               %{"203.0.113.60" => {device.uid, :srql}}
    end

    test "a target query that fails at compile time keeps the recorded device targets", %{
      actor: actor,
      unique: unique
    } do
      {:ok, device} = create_device(actor, "dev-kept-#{unique}", "203.0.113.61")

      {:ok, group} =
        create_group(actor, unique, %{target_query: "in:devices ip:203.0.113.61"})

      assert [%{target: "203.0.113.61"}] = declared_rows(actor, group.id)

      ConfigCache.invalidate(:sweep)

      assert {:ok, _config} =
               SweepCompiler.compile("default", nil,
                 query_page_fn: fn _query, _opts -> {:error, :srql_unavailable} end
               )

      assert Map.new(declared_rows(actor, group.id), &{&1.target, &1.device_uid}) ==
               %{"203.0.113.61" => device.uid}
    end

    test "recompiling an unchanged group does not rewrite its rows", %{
      actor: actor,
      unique: unique
    } do
      {:ok, group} = create_group(actor, unique, %{static_targets: ["198.51.100.31"]})
      assert [_] = declared_rows(actor, group.id)

      # Backdate the row so a rewrite would be visible in declared_at.
      Repo.query!(
        "UPDATE platform.sweep_group_declared_targets SET declared_at = '2000-01-01 00:00:00' " <>
          "WHERE sweep_group_id = $1",
        [Ecto.UUID.dump!(group.id)]
      )

      ConfigCache.invalidate(:sweep)
      assert {:ok, _config} = SweepCompiler.compile("default", nil)

      assert [%{declared_at: ~U[2000-01-01 00:00:00Z]}] = declared_rows(actor, group.id)
    end
  end

  defp create_group(actor, unique, attrs) do
    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "Declared Targets Group #{unique}", partition: "default"}, attrs),
      actor: actor
    )
    |> Ash.create()
  end

  defp create_device(actor, uid, ip) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, ip: ip, hostname: uid}, actor: actor)
    |> Ash.create()
  end

  defp create_agent(actor, uid) do
    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid}, actor: actor)
    |> Ash.create(actor: actor)
  end

  defp declared_rows(actor, group_id) do
    SweepGroupDeclaredTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(sweep_group_id == ^group_id)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rows} -> rows
      error -> flunk("declared target read failed: #{inspect(error)}")
    end
  end

  defp overlap_rows(group_id) do
    {:ok, %Postgrex.Result{columns: columns, rows: rows}} =
      Repo.query(
        "SELECT relationship, declared, observed, ip, declared_target, covering_declarations, " <>
          "observed_ip, agent_id, device_uid, declared_at, match_kind, match_via " <>
          "FROM platform.device_sweep_overlap WHERE sweep_group_id = $1",
        [Ecto.UUID.dump!(group_id)]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp insert_coverage(ip, opts) do
    now = DateTime.utc_now()

    row = %{
      day: Date.utc_today(),
      device_uid: opts[:device_uid],
      ip: ip,
      sweep_group_id: opts[:sweep_group_id] && Ecto.UUID.dump!(opts[:sweep_group_id]),
      agent_id: opts[:agent_id],
      execution_count: 1,
      available_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, nil} = Repo.insert_all("sweep_coverage_daily", [row], prefix: "platform")
    :ok
  end
end
