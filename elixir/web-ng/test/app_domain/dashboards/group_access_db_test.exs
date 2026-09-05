defmodule ServiceRadarWebNG.Dashboards.GroupAccessDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Dashboards.GroupAccess

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  @all_permissions [
    "settings.rbac.manage",
    "analytics.dashboards.share",
    "analytics.dashboards.edit",
    "dashboards.packages.share",
    "dashboards.packages.view_all"
  ]

  setup do
    marker = "group-access-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup!(marker) end)
    system = SystemActor.system(:dashboard_group_access_test)
    actor = actor!(system, marker, "operator", @all_permissions)
    group = group!(system, marker, "selected")

    %{actor: actor, group: group, marker: marker, scope: %{user: actor}, system: system}
  end

  test "audience pages use stable normalized title and id keysets and load only the selected grant",
       context do
    other_group = group!(context.system, context.marker, "other")

    authored =
      for index <- 0..50 do
        title = if rem(index, 2) == 0, do: "Alpha #{index}", else: "alpha #{index}"
        authored!(context.marker, context.actor.id, title, :private)
      end

    package = package!(context.marker)

    instances =
      for index <- 0..50 do
        name = if rem(index, 2) == 0, do: "Beta #{index}", else: "beta #{index}"
        instance!(context.marker, package.id, context.actor.id, name, :shared)
      end

    selected = hd(authored)

    group_grant!(
      :authored,
      selected.id,
      context.group.id,
      context.actor.id,
      :view,
      context.system
    )

    group_grant!(:authored, selected.id, other_group.id, context.actor.id, :edit, context.system)

    assert {:ok, first} =
             GroupAccess.page(
               context.scope,
               {:policy_editor, :authored},
               context.group.id,
               :first
             )

    assert length(first.results) == 50
    assert is_binary(first.after)
    assert first.before == nil

    assert {:ok, second} =
             GroupAccess.page(
               context.scope,
               {:policy_editor, :authored},
               context.group.id,
               {:after, first.after}
             )

    assert Enum.map(first.results ++ second.results, & &1.id) == sorted_ids(authored, :title)

    selected_row = Enum.find(first.results ++ second.results, &(&1.id == selected.id))
    assert [%{subject_group_id: selected_group_id}] = selected_row.access_grants
    assert selected_group_id == context.group.id

    assert {:ok, package_first} =
             GroupAccess.page(context.scope, {:policy_editor, :package}, context.group.id, :first)

    assert length(package_first.results) == 50

    assert {:ok, package_second} =
             GroupAccess.page(
               context.scope,
               {:policy_editor, :package},
               context.group.id,
               {:after, package_first.after}
             )

    assert Enum.map(package_first.results ++ package_second.results, & &1.id) ==
             sorted_ids(instances, :name)
  end

  test "public targets are no-write and ensure view cannot downgrade edit", context do
    public = authored!(context.marker, context.actor.id, "Public", :public)

    assert {:ok, %{grant: nil, changed?: false}} =
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :authored},
               public.id,
               context.group.id,
               audit_writer: audit_to(self())
             )

    assert count_group_grants(:authored, public.id, context.group.id) == 0
    refute_receive {:audit, _audit, _transaction?}

    private = authored!(context.marker, context.actor.id, "Editable", :private)
    group_grant!(:authored, private.id, context.group.id, context.actor.id, :edit, context.system)

    assert {:ok, %{changed?: false, visibility_changed?: false}} =
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :authored},
               private.id,
               context.group.id,
               audit_writer: audit_to(self())
             )

    assert %{access: :edit} = grant!(:authored, private.id, context.group.id, context.system)
    assert count_group_grants(:authored, private.id, context.group.id) == 1
    refute_receive {:audit, _audit, _transaction?}
  end

  test "local public authored and package targets permit edit and full revoke while central intent is no-write",
       context do
    package = package!(context.marker)
    authored = authored!(context.marker, context.actor.id, "Local public", :public)
    instance = instance!(context.marker, package.id, context.actor.id, "Local public", :public)

    for {source, target} <- [authored: authored, package: instance] do
      assert {:ok, %{grant: %{access: :edit}, changed?: true}} =
               GroupAccess.set_group_access(
                 context.scope,
                 {:local, source},
                 target.id,
                 context.group.id,
                 :edit,
                 audit_writer: fn _ -> :ok end
               )

      for operation <- [:ensure_group_view, :revoke_group_view] do
        assert {:ok, %{grant: %{access: :edit}, changed?: false}} =
                 apply(GroupAccess, operation, [
                   context.scope,
                   {:policy_editor, source},
                   target.id,
                   context.group.id,
                   [audit_writer: audit_to(self())]
                 ])
      end

      refute_receive {:audit, _audit, _transaction?}
      assert count_group_grants(source, target.id, context.group.id) == 1

      assert {:ok, %{changed?: true}} =
               GroupAccess.revoke_group_access(
                 context.scope,
                 {:local, source},
                 target.id,
                 context.group.id,
                 audit_writer: fn _ -> :ok end
               )

      assert count_group_grants(source, target.id, context.group.id) == 0
    end
  end

  test "a conditional revoke serialized with a local edit preserves the edit", context do
    target = authored!(context.marker, context.actor.id, "Serialized", :private)
    group_grant!(:authored, target.id, context.group.id, context.actor.id, :view, context.system)
    parent = self()
    gate = make_ref()

    revoke =
      Task.async(fn ->
        GroupAccess.revoke_group_view(
          context.scope,
          {:policy_editor, :authored},
          target.id,
          context.group.id,
          before_grant: fn ->
            send(parent, {:revoke_locked, self()})

            receive do
              {:continue_revoke, ^gate} -> :ok
            end
          end
        )
      end)

    assert_receive {:revoke_locked, revoke_pid}
    assert revoke_pid == revoke.pid

    edit =
      Task.async(fn ->
        GroupAccess.set_group_access(
          context.scope,
          {:local, :authored},
          target.id,
          context.group.id,
          :edit
        )
      end)

    assert Task.yield(edit, 50) == nil
    send(revoke.pid, {:continue_revoke, gate})
    assert {:ok, _result} = Task.await(revoke)
    assert {:ok, _result} = Task.await(edit)

    persisted_grant = grant!(:authored, target.id, context.group.id, context.system)
    assert persisted_grant.access == :edit
    assert count_group_grants(:authored, target.id, context.group.id) == 1
  end

  test "a local edit makes a delayed policy editor fingerprint stale without audit", context do
    target = authored!(context.marker, context.actor.id, "Fingerprint", :private)
    group_grant!(:authored, target.id, context.group.id, context.actor.id, :view, context.system)
    fingerprint = fingerprint!(:authored, context.scope, context.group.id, target.id)

    assert {:ok, _result} =
             GroupAccess.set_group_access(
               context.scope,
               {:local, :authored},
               target.id,
               context.group.id,
               :edit
             )

    assert {:error, :stale} =
             GroupAccess.revoke_group_view(
               context.scope,
               {:policy_editor, :authored},
               target.id,
               context.group.id,
               expected_fingerprint: fingerprint,
               audit_writer: audit_to(self())
             )

    persisted_grant = grant!(:authored, target.id, context.group.id, context.system)
    assert persisted_grant.access == :edit
    refute_receive {:audit, _audit, _transaction?}
  end

  test "private package sharing is atomic, rolls back with a failed grant, and stays shared on revoke",
       context do
    package = package!(context.marker)
    atomic = instance!(context.marker, package.id, context.actor.id, "Atomic", :private)
    parent = self()

    assert {:ok, %{visibility_changed?: true}} =
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :package},
               atomic.id,
               context.group.id,
               before_grant: fn ->
                 observer =
                   Task.async(fn ->
                     {:ok, observed} =
                       Ash.get(DashboardInstance, atomic.id, actor: context.system)

                     send(parent, {:observed_visibility, observed.visibility})
                   end)

                 Task.await(observer)
                 :ok
               end
             )

    assert_receive {:observed_visibility, :private}
    persisted_instance = Ash.get!(DashboardInstance, atomic.id, actor: context.system)
    assert persisted_instance.visibility == :shared

    rollback = instance!(context.marker, package.id, context.actor.id, "Rollback", :private)

    assert {:error, :synthetic_grant_failure} =
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :package},
               rollback.id,
               context.group.id,
               before_grant: fn -> {:error, :synthetic_grant_failure} end
             )

    assert %{visibility: :private} =
             Ash.get!(DashboardInstance, rollback.id, actor: context.system)

    assert count_group_grants(:package, rollback.id, context.group.id) == 0

    assert {:ok, _result} =
             GroupAccess.revoke_group_view(
               context.scope,
               {:policy_editor, :package},
               atomic.id,
               context.group.id
             )

    persisted_instance = Ash.get!(DashboardInstance, atomic.id, actor: context.system)
    assert persisted_instance.visibility == :shared
  end

  test "authored policy editor authorization requires manage and share plus a target edit path",
       context do
    owner = actor!(context.system, context.marker, "owner", [])
    target = authored!(context.marker, owner.id, "Authorization", :private)

    for {label, permissions} <- [
          {"missing-manage", ["analytics.dashboards.share", "analytics.dashboards.edit"]},
          {"missing-share", ["settings.rbac.manage", "analytics.dashboards.edit"]},
          {"missing-target", ["settings.rbac.manage", "analytics.dashboards.share"]}
        ] do
      denied = actor!(context.system, context.marker, label, permissions)

      assert {:error, _reason} =
               GroupAccess.ensure_group_view(
                 %{user: denied},
                 {:policy_editor, :authored},
                 target.id,
                 context.group.id
               )
    end

    global =
      actor!(context.system, context.marker, "global", [
        "settings.rbac.manage",
        "analytics.dashboards.share",
        "analytics.dashboards.edit"
      ])

    assert {:ok, _result} =
             GroupAccess.ensure_group_view(
               %{user: global},
               {:policy_editor, :authored},
               target.id,
               context.group.id,
               audit_writer: fn _audit -> :ok end
             )

    assert %{access: :view} = grant!(:authored, target.id, context.group.id, context.system)

    assert {:ok, _result} =
             GroupAccess.revoke_group_view(
               %{user: global},
               {:policy_editor, :authored},
               target.id,
               context.group.id,
               audit_writer: fn _audit -> :ok end
             )

    assert count_group_grants(:authored, target.id, context.group.id) == 0
  end

  test "package policy editor uses the exact conjunction while a local owner needs no global share",
       context do
    owner = actor!(context.system, context.marker, "package-owner", [])
    package = package!(context.marker)
    target = instance!(context.marker, package.id, owner.id, "Authorization", :private)

    assert {:error, _reason} =
             GroupAccess.ensure_group_view(
               %{user: owner},
               {:policy_editor, :package},
               target.id,
               context.group.id
             )

    assert {:ok, _result} =
             GroupAccess.ensure_group_view(
               %{user: owner},
               {:local, :package},
               target.id,
               context.group.id
             )

    missing_target =
      actor!(context.system, context.marker, "package-missing-target", [
        "settings.rbac.manage",
        "dashboards.packages.share"
      ])

    assert {:error, _reason} =
             GroupAccess.ensure_group_view(
               %{user: missing_target},
               {:policy_editor, :package},
               target.id,
               group!(context.system, context.marker, "denied").id
             )

    global =
      actor!(context.system, context.marker, "package-global", [
        "settings.rbac.manage",
        "dashboards.packages.share",
        "dashboards.packages.view_all"
      ])

    assert {:ok, _result} =
             GroupAccess.ensure_group_view(
               %{user: global},
               {:policy_editor, :package},
               target.id,
               group!(context.system, context.marker, "global").id
             )
  end

  test "outer transactions are rejected and successful audits run after commit", context do
    target = authored!(context.marker, context.actor.id, "Effects", :private)

    assert Repo.transaction(fn ->
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :authored},
               target.id,
               context.group.id,
               audit_writer: audit_to(self())
             )
           end) == {:ok, {:error, :outer_transaction_not_supported}}

    refute_receive {:audit, _audit, _transaction?}
    assert count_group_grants(:authored, target.id, context.group.id) == 0

    assert {:ok, _result} =
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :authored},
               target.id,
               context.group.id,
               audit_writer: audit_to(self())
             )

    assert_receive {:audit, audit, false}
    assert audit[:action] == :ensure_group_view
  end

  test "raw group mutations require the boundary while user grant paths remain available",
       context do
    target = authored!(context.marker, context.actor.id, "Boundary", :private)

    assert {:error, group_error} =
             DashboardAccessGrant
             |> Ash.Changeset.for_create(:create_group, %{
               dashboard_id: target.id,
               subject_group_id: context.group.id,
               access: :view,
               granted_by_id: context.actor.id
             })
             |> Ash.create(actor: context.system)

    assert Exception.message(group_error) =~ "dashboard group access boundary"

    recipient = actor!(context.system, context.marker, "recipient", [])

    assert {:ok, %{subject_type: :user}} =
             DashboardAccessGrant
             |> Ash.Changeset.for_create(:create, %{
               dashboard_id: target.id,
               subject_user_id: recipient.id,
               access: :view,
               granted_by_id: context.actor.id
             })
             |> Ash.create(actor: context.system)
  end

  test "query-based atomic update and destroy reject groups but preserve user grant operations",
       context do
    target = authored!(context.marker, context.actor.id, "Atomic Boundary", :private)
    recipient = actor!(context.system, context.marker, "atomic-recipient", [])

    user_grant =
      DashboardAccessGrant
      |> Ash.Changeset.for_create(:create, %{
        dashboard_id: target.id,
        subject_user_id: recipient.id,
        access: :view,
        granted_by_id: context.actor.id
      })
      |> Ash.create!(actor: context.system)

    group_grant =
      group_grant!(
        :authored,
        target.id,
        context.group.id,
        context.actor.id,
        :view,
        context.system
      )

    assert %{status: :success} =
             DashboardAccessGrant
             |> Ash.Query.filter(id == ^user_grant.id)
             |> Ash.bulk_update(:update, %{access: :edit},
               actor: context.system,
               strategy: [:atomic],
               return_errors?: true
             )

    assert %{status: :error, errors: update_errors} =
             DashboardAccessGrant
             |> Ash.Query.filter(id == ^group_grant.id)
             |> Ash.bulk_update(:update, %{access: :edit},
               actor: context.system,
               strategy: [:atomic],
               return_errors?: true
             )

    assert Enum.any?(
             List.wrap(update_errors),
             &(Exception.message(&1) =~ "dashboard group access boundary")
           )

    assert %{status: :success} =
             DashboardAccessGrant
             |> Ash.Query.filter(id == ^user_grant.id)
             |> Ash.bulk_destroy(:destroy, %{},
               actor: context.system,
               strategy: [:atomic],
               return_errors?: true
             )

    assert %{status: :error, errors: destroy_errors} =
             DashboardAccessGrant
             |> Ash.Query.filter(id == ^group_grant.id)
             |> Ash.bulk_destroy(:destroy, %{},
               actor: context.system,
               strategy: [:atomic],
               return_errors?: true
             )

    assert Enum.any?(
             List.wrap(destroy_errors),
             &(Exception.message(&1) =~ "dashboard group access boundary")
           )

    assert %{access: :view} = grant!(:authored, target.id, context.group.id, context.system)
  end

  test "audit delivery failures cannot undo a committed group grant", context do
    target = authored!(context.marker, context.actor.id, "Audit Failure", :private)

    assert {:ok, _result} =
             GroupAccess.ensure_group_view(
               context.scope,
               {:policy_editor, :authored},
               target.id,
               context.group.id,
               audit_writer: fn _audit -> raise "synthetic audit delivery failure" end
             )

    assert %{access: :view} = grant!(:authored, target.id, context.group.id, context.system)
  end

  defp actor!(system, marker, label, permissions) do
    profile = profile!(system, marker, label, permissions)
    suffix = System.unique_integer([:positive])
    password = "SyntheticGroupAccess#{suffix}!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "#{label}-#{marker}-#{suffix}@example.test",
          password: password,
          password_confirmation: password
        },
        actor: system
      )

    {:ok, user} =
      User.update_role_profile(user, %{role_profile_id: profile.id}, actor: system)

    user
  end

  defp profile!(system, marker, label, permissions) do
    RoleProfile
    |> Ash.Changeset.for_create(
      :create,
      %{name: "#{marker}-#{label}-profile", permissions: permissions},
      actor: system,
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.create!()
  end

  defp group!(system, marker, label) do
    {:ok, group} =
      UserGroup.create_group(%{name: "#{marker}-#{label}-group"}, actor: system)

    group
  end

  defp authored!(marker, owner_id, title, visibility) do
    id = Ecto.UUID.generate()

    Repo.insert_all(
      "authored_dashboards",
      [
        %{
          id: Ecto.UUID.dump!(id),
          dashboard_ref: synthetic_dashboard_ref(),
          title: "#{marker}-#{title}",
          owner_id: Ecto.UUID.dump!(owner_id),
          visibility: Atom.to_string(visibility)
        }
      ],
      prefix: "platform"
    )

    %{id: id, title: "#{marker}-#{title}"}
  end

  defp package!(marker) do
    id = Ecto.UUID.generate()
    dashboard_id = "#{marker}-package-#{id}"

    Repo.insert_all(
      "dashboard_packages",
      [
        %{
          id: Ecto.UUID.dump!(id),
          dashboard_id: dashboard_id,
          name: dashboard_id,
          version: "1.0.0"
        }
      ],
      prefix: "platform"
    )

    %{id: id}
  end

  defp instance!(marker, package_id, owner_id, name, visibility) do
    id = Ecto.UUID.generate()
    full_name = "#{marker}-#{name}"

    Repo.insert_all(
      "dashboard_instances",
      [
        %{
          id: Ecto.UUID.dump!(id),
          dashboard_package_id: Ecto.UUID.dump!(package_id),
          name: full_name,
          route_slug: "#{marker}-#{id}",
          owner_id: Ecto.UUID.dump!(owner_id),
          visibility: Atom.to_string(visibility)
        }
      ],
      prefix: "platform"
    )

    %{id: id, name: full_name}
  end

  defp group_grant!(source, target_id, group_id, actor_id, access, system) do
    case_result =
      case source do
        :authored -> %{dashboard_id: target_id}
        :package -> %{dashboard_instance_id: target_id}
      end

    attrs =
      Map.merge(case_result, %{
        subject_group_id: group_id,
        granted_by_id: actor_id,
        access: access
      })

    source
    |> grant_resource()
    |> Ash.Changeset.for_create(:set_group_access, attrs,
      actor: system,
      context: %{dashboard_group_access_boundary_owned: true}
    )
    |> Ash.create!()
  end

  defp grant!(:authored, target_id, group_id, system) do
    DashboardAccessGrant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_type == :group and subject_group_id == ^group_id and dashboard_id == ^target_id)
    |> Ash.read_one!(actor: system)
  end

  defp count_group_grants(source, target_id, group_id) do
    {table, target_field} = grant_table(source)

    Repo.one(
      from(g in table,
        prefix: "platform",
        where:
          field(g, ^target_field) == type(^target_id, :binary_id) and
            g.subject_group_id == type(^group_id, :binary_id) and g.subject_type == "group",
        select: count(g.id)
      )
    )
  end

  defp fingerprint!(source, scope, group_id, target_id) do
    {:ok, page} = GroupAccess.page(scope, {:policy_editor, source}, group_id, :first)
    target = Enum.find(page.results, &(&1.id == target_id))
    grant = List.first(target.access_grants)

    {target.visibility, target.updated_at, grant && grant.id, grant && grant.access, grant && grant.updated_at}
  end

  defp audit_to(test_pid) do
    fn audit ->
      send(test_pid, {:audit, audit, Repo.in_transaction?()})
      :ok
    end
  end

  defp sorted_ids(rows, field) do
    rows
    |> Enum.sort_by(&{String.downcase(Map.fetch!(&1, field)), &1.id})
    |> Enum.map(& &1.id)
  end

  defp synthetic_dashboard_ref do
    1_000_000 + :erlang.phash2(Ecto.UUID.generate(), 9_000_000)
  end

  defp grant_resource(:authored), do: DashboardAccessGrant
  defp grant_resource(:package), do: DashboardInstanceAccessGrant

  defp grant_table(:authored), do: {"dashboard_access_grants", :dashboard_id}
  defp grant_table(:package), do: {"dashboard_instance_access_grants", :dashboard_instance_id}

  defp cleanup!(marker) do
    title_pattern = "#{marker}-%"
    package_pattern = "#{marker}-package-%"
    group_pattern = "#{marker}-%-group"
    user_pattern = "%-#{marker}-%@example.test"
    profile_pattern = "#{marker}-%-profile"

    Repo.delete_all(from(d in "authored_dashboards", prefix: "platform", where: like(d.title, ^title_pattern)))

    Repo.delete_all(
      from(p in "dashboard_packages",
        prefix: "platform",
        where: like(p.dashboard_id, ^package_pattern)
      )
    )

    Repo.delete_all(from(g in "user_groups", prefix: "platform", where: like(g.name, ^group_pattern)))

    Repo.delete_all(from(u in "ng_users", prefix: "platform", where: like(u.email, ^user_pattern)))

    Repo.delete_all(from(p in "role_profiles", prefix: "platform", where: like(p.name, ^profile_pattern)))
  end
end
