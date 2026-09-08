defmodule ServiceRadar.PrefixTags.ManualIntegrationTest do
  @moduledoc """
  DB-backed regression coverage for operator-authored prefix tags.

  Run through the guarded Bazel lifecycle, or follow
  `.agents/skills/srql-fixtures-db-tests/SKILL.md` to create a codex_* scratch database before a
  focused Mix invocation.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.PrefixTags.Changes.BroadcastManualInvalidation
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Manual
  alias ServiceRadar.PrefixTags.PrefixTag
  alias ServiceRadar.PrefixTags.Snapshot
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag timeout: 120_000

  @manager %{
    id: "prefix-tag-manager",
    role: :operator,
    permissions: MapSet.new(["settings.prefix_tags.manage"])
  }
  @system SystemActor.system(:prefix_tags_manual_integration_test)

  setup do
    Store.clear()
    on_exit(&Store.clear/0)
    :ok
  end

  test "manual create, update, destroy, and reconcile preserve count and local trie" do
    snapshot = Manual.ensure_active_snapshot!(actor: @system)

    assert {:ok, first} =
             Manual.create(
               %{prefix: "10.210.0.0/24", tags: ["site:first"]},
               actor: @manager
             )

    assert snapshot_count(snapshot.id) == 1
    assert [%{tags: tags}] = Store.lookup("10.210.0.1", "manual")
    assert "site:first" in tags

    assert {:ok, updated} =
             Manual.update(
               first,
               %{prefix: "10.211.0.0/24", tags: ["site:updated"]},
               actor: @manager
             )

    assert snapshot_count(snapshot.id) == 1
    assert Store.lookup("10.210.0.1", "manual") == []
    assert [%{tags: tags}] = Store.lookup("10.211.0.1", "manual")
    assert "site:updated" in tags

    assert {:ok, second} =
             Manual.create(
               %{prefix: "10.212.0.0/24", tags: ["site:second"]},
               actor: @manager
             )

    assert snapshot_count(snapshot.id) == 2

    Repo.query!(
      "UPDATE platform.prefix_tag_snapshots SET record_count = 99 WHERE id = $1",
      [Ecto.UUID.dump!(snapshot.id)]
    )

    # The public Ash id is a UUID string; reconcile must dump it before sending
    # it as a Postgrex UUID parameter.
    assert Manual.reconcile_record_count!(snapshot.id) == 2
    assert snapshot_count(snapshot.id) == 2

    assert :ok = Manual.destroy(updated, actor: @manager)
    assert snapshot_count(snapshot.id) == 1
    assert Store.lookup("10.211.0.1", "manual") == []

    assert :ok = Manual.destroy(second, actor: @manager)
    assert snapshot_count(snapshot.id) == 0
    assert Store.stats("manual").total_prefixes == 0
  end

  test "generic create is system-only and create_manual rejects imported snapshots" do
    manual_snapshot = Manual.ensure_active_snapshot!(actor: @system)

    assert {:ok, imported_snapshot} =
             Snapshot.create(
               %{source: "netbox", status: "building", is_active: false, record_count: 0},
               actor: @system
             )

    generic_attrs = %{
      snapshot_id: imported_snapshot.id,
      prefix: "10.220.0.0/24",
      tags: ["source:netbox"]
    }

    assert {:error, %Ash.Error.Forbidden{}} = PrefixTag.create(generic_attrs, actor: @manager)
    assert {:ok, _imported} = PrefixTag.create(generic_attrs, actor: @system)

    assert {:error, manager_error} =
             PrefixTag.create_manual(
               %{
                 snapshot_id: imported_snapshot.id,
                 prefix: "10.221.0.0/24",
                 tags: ["source:not-manual"]
               },
               actor: @manager
             )

    assert inspect(manager_error) =~
             "only manual prefix tags may be created, updated, or destroyed"

    assert {:error, system_error} =
             PrefixTag.create_manual(
               %{
                 snapshot_id: imported_snapshot.id,
                 prefix: "10.222.0.0/24",
                 tags: ["source:not-manual"]
               },
               actor: @system
             )

    assert inspect(system_error) =~
             "only manual prefix tags may be created, updated, or destroyed"

    assert {:ok, _manual} =
             PrefixTag.create_manual(
               %{
                 snapshot_id: manual_snapshot.id,
                 prefix: "10.223.0.0/24",
                 tags: ["source:manual"]
               },
               actor: @manager
             )

    assert snapshot_count(imported_snapshot.id) == 0
    assert snapshot_count(manual_snapshot.id) == 1

    # Destroy actions return bare :ok, so their invalidation hook must recover
    # the source from changeset.data.snapshot_id rather than guess "manual".
    changeset = Ash.Changeset.new(%PrefixTag{snapshot_id: imported_snapshot.id})

    assert BroadcastManualInvalidation.source_for_invalidation(changeset, nil) == "netbox"
  end

  test "Loader-disabled invalidation rebuilds every row beyond the first Ash page" do
    snapshot = Manual.ensure_active_snapshot!(actor: @system)

    assert Process.whereis(Loader) == nil
    assert :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, Loader.pubsub_topic())

    Repo.query!(
      """
      INSERT INTO platform.prefix_tags
        (id, snapshot_id, prefix, tags, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        $1,
        set_masklen('10.230.0.0'::inet + n, 32)::cidr,
        jsonb_build_array('bulk:' || n::text),
        NOW(),
        NOW()
      FROM generate_series(0, 299) AS n
      """,
      [Ecto.UUID.dump!(snapshot.id)]
    )

    assert :ok = Manual.invalidate!()

    assert_receive {:prefix_tags_snapshot_changed, %{source: "manual", reloaded_on: reloaded_on}}

    assert reloaded_on == node()
    assert Store.stats("manual").total_prefixes == 300

    assert [%{prefix: "10.230.1.43/32", tags: ["bulk:299"]}] =
             Store.lookup("10.230.1.43", "manual")
  end

  defp snapshot_count(snapshot_id) do
    assert {:ok, snapshot} = Snapshot.by_id(%{id: snapshot_id}, actor: @system)
    snapshot.record_count
  end
end
