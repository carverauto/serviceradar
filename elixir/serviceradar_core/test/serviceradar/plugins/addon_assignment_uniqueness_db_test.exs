defmodule ServiceRadar.Plugins.AddonAssignmentUniquenessDbTest do
  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonProfileReconciler
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  defmodule Resolver do
    @moduledoc false

    def resolve(_inputs, opts) do
      uids = Keyword.get(opts, :agent_uids, [Keyword.fetch!(opts, :agent_uid)])
      {:ok, [%{entity: "agents", rows: Enum.map(uids, &%{"uid" => &1})}]}
    end
  end

  defmodule AgentLoader do
    @moduledoc false

    def load(uids, _actor) do
      {:ok,
       Enum.map(uids, fn uid ->
         %{uid: uid, version: "1.0.0", metadata: %{"os" => "linux", "arch" => "amd64"}}
       end)}
    end
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:addon_assignment_uniqueness_test)
    id = Ecto.UUID.generate()
    package = approved_package("assignment-test-#{id}", actor)
    %{actor: actor, package: package, agent_uid: "agent-test-#{id}"}
  end

  test "enabled assignments conflict across every source", ctx do
    for {owner, contender} <- [{:manual, :profile}, {:profile, :policy}, {:policy, :manual}] do
      uid = "#{ctx.agent_uid}-#{owner}"
      assert {:ok, first} = create_assignment(ctx.package, uid, owner, true, ctx.actor)

      assert {:error, %Invalid{} = error} =
               create_assignment(ctx.package, uid, contender, true, ctx.actor)

      assert Exception.message(error) =~ "add-on is already enabled for this agent"
      assert [%{id: id, source: ^owner}] = enabled_assignments(uid, ctx.actor)
      assert id == first.id
    end
  end

  test "profile re-application preserves its row and refuses an overlapping profile", ctx do
    profile = create_profile(ctx.package, "in:agents", ctx.actor)
    overlapping = create_profile(ctx.package, "in:agents uid:#{ctx.agent_uid}", ctx.actor)

    opts = [
      actor: ctx.actor,
      resolver: Resolver,
      agent_loader: AgentLoader,
      agent_uid: ctx.agent_uid
    ]

    assert {:ok, %{upserted: 1}} = AddonProfileReconciler.reconcile(profile, opts)
    assert [first] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert {:ok, %{unchanged: 1}} = AddonProfileReconciler.reconcile(profile, opts)

    assert {:ok, %{upserted: 0, assignment_conflicts: [conflict]}} =
             AddonProfileReconciler.reconcile(overlapping, opts)

    assert conflict.assignment_id == first.id
    assert [%{id: id}] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert id == first.id

    other_uid = "#{ctx.agent_uid}-uncovered"

    assert {:ok, %{upserted: 1, assignment_conflicts: [^conflict]}} =
             AddonProfileReconciler.reconcile(
               overlapping,
               Keyword.put(opts, :agent_uids, [ctx.agent_uid, other_uid])
             )

    assert [%{addon_profile_id: profile_id}] = enabled_assignments(other_uid, ctx.actor)
    assert profile_id == overlapping.id
    assert [%{id: id}] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert id == first.id
  end

  test "atomic enable cannot bypass uniqueness and succeeds once the holder is disabled", ctx do
    assert {:ok, first} =
             create_assignment(ctx.package, ctx.agent_uid, :profile, true, ctx.actor)

    assert {:ok, second} =
             create_assignment(ctx.package, ctx.agent_uid, :policy, false, ctx.actor)

    result = atomic_update(second, %{enabled: true}, ctx.actor)
    assert result.status == :error
    assert Enum.any?(result.errors, &String.contains?(Exception.message(&1), "already enabled"))

    assert [%{id: id}] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert id == first.id

    assert {:ok, _} =
             first
             |> Ash.Changeset.for_update(:update, %{enabled: false})
             |> Ash.update(actor: ctx.actor)

    assert %{status: :success} = atomic_update(second, %{enabled: true}, ctx.actor)
    assert [%{id: id}] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert id == second.id
  end

  test "raw database writes cannot enable a duplicate", ctx do
    assert {:ok, _} = create_assignment(ctx.package, ctx.agent_uid, :manual, true, ctx.actor)

    assert {:ok, second} =
             create_assignment(ctx.package, ctx.agent_uid, :policy, false, ctx.actor)

    assert_raise Postgrex.Error, ~r/addon_assignments_one_enabled_per_agent_addon_index/, fn ->
      Repo.query!(
        "UPDATE platform.addon_assignments SET enabled = true WHERE id = ($1::text)::uuid",
        [second.id]
      )
    end
  end

  test "atomic package changes keep the logical add-on key authoritative", ctx do
    other = approved_package("other-#{ctx.package.addon_id}", ctx.actor)
    assert {:ok, first} = create_assignment(ctx.package, ctx.agent_uid, :manual, true, ctx.actor)
    assert {:ok, second} = create_assignment(other, ctx.agent_uid, :policy, false, ctx.actor)

    attrs = %{addon_package_id: ctx.package.id, enabled: true}
    assert %{status: :error} = atomic_update(second, attrs, ctx.actor)
    assert [%{id: id}] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert id == first.id

    assert {:ok, _} =
             first
             |> Ash.Changeset.for_update(:update, %{enabled: false})
             |> Ash.update(actor: ctx.actor)

    assert %{status: :success} = atomic_update(second, attrs, ctx.actor)
    assert [%{id: id, addon_id: addon_id}] = enabled_assignments(ctx.agent_uid, ctx.actor)
    assert id == second.id
    assert addon_id == ctx.package.addon_id
  end

  defp atomic_update(assignment, attrs, actor) do
    AddonAssignment
    |> Ash.Query.filter(id == ^assignment.id)
    |> Ash.bulk_update(:update, attrs, actor: actor, strategy: :atomic, return_errors?: true)
  end

  defp enabled_assignments(uid, actor) do
    AddonAssignment
    |> Ash.Query.filter(agent_uid == ^uid and enabled == true)
    |> Ash.read!(actor: actor)
  end

  defp create_assignment(package, uid, source, enabled, actor) do
    AddonAssignment
    |> Ash.Changeset.for_create(:create, %{
      agent_uid: uid,
      addon_package_id: package.id,
      source: source,
      source_key: if(source == :manual, do: nil, else: Ecto.UUID.generate()),
      enabled: enabled
    })
    |> Ash.create(actor: actor)
  end

  defp approved_package(addon_id, actor) do
    package =
      AddonPackage
      |> Ash.Changeset.for_create(:create, %{
        addon_id: addon_id,
        version: "1.0.0",
        name: "Synthetic assignment package",
        artifacts: %{"linux/amd64" => %{}},
        config_schema: %{"type" => "object"}
      })
      |> Ash.create!(actor: actor)

    package
    |> Ash.Changeset.for_update(:approve, %{
      approved_capabilities: [],
      approved_by: "system:assignment_test"
    })
    |> Ash.update!(actor: actor)
  end

  defp create_profile(package, query, actor) do
    AddonProfile
    |> Ash.Changeset.for_create(:create, %{
      name: "Synthetic profile #{Ecto.UUID.generate()}",
      addon_package_id: package.id,
      target_query: query
    })
    |> Ash.create!(actor: actor)
    |> Ash.load!(:addon_package, actor: actor)
  end
end
