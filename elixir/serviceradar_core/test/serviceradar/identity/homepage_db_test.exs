defmodule ServiceRadar.Identity.HomepageDbTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardUserPreference
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.AddConfigurableHomepages
  alias ServiceRadar.TestSupport

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261006140000_add_configurable_homepages.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    system = SystemActor.system(:homepage_db_test)
    admin = user!(system, :admin)
    viewer = user!(system, :viewer)
    private_dashboard = dashboard!(admin, :private)

    {:ok, system: system, admin: admin, viewer: viewer, private_dashboard: private_dashboard}
  end

  test "a homepage is only a typed choice; unknown kinds, free-text paths and malformed targets are rejected",
       %{viewer: viewer} do
    for invalid <- [
          %{"kind" => "url", "target_id" => "https://example.com"},
          %{"kind" => "overview", "path" => "//example.com"},
          %{
            "kind" => "overview",
            "target_type" => "authored",
            "target_id" => Ecto.UUID.generate()
          },
          %{"kind" => "dashboard", "target_type" => "authored", "target_id" => "not-a-uuid"},
          %{"kind" => "dashboard", "target_type" => "package", "target_id" => "../settings"},
          %{"kind" => "dashboard"},
          "/dashboards"
        ] do
      assert {:error, %Invalid{}} =
               User.update_homepage_preference(viewer, invalid, actor: viewer),
             "expected #{inspect(invalid)} to be rejected"
    end

    assert {:ok, saved} =
             User.update_homepage_preference(viewer, %{kind: :dashboards_index}, actor: viewer)

    assert saved.homepage == %{"kind" => "dashboards_index"}

    assert {:ok, cleared} = User.update_homepage_preference(saved, nil, actor: viewer)
    assert is_nil(cleared.homepage)
  end

  test "a dashboard homepage must be one the saving actor can open",
       %{admin: admin, viewer: viewer, private_dashboard: dashboard} do
    homepage = %{"kind" => "dashboard", "target_type" => "authored", "target_id" => dashboard.id}

    # Private to the admin and not shared: the viewer cannot point a homepage at it.
    assert {:error, %Invalid{}} = User.update_homepage_preference(viewer, homepage, actor: viewer)

    missing = %{homepage | "target_id" => Ecto.UUID.generate()}
    assert {:error, %Invalid{}} = User.update_homepage_preference(admin, missing, actor: admin)

    assert {:ok, saved} = User.update_homepage_preference(admin, homepage, actor: admin)
    assert saved.homepage == homepage
  end

  test "users set only their own homepage; group and deployment homepages need their manage permissions",
       %{admin: admin, viewer: viewer, system: system} do
    overview = %{"kind" => "overview"}

    # Not even an auth manager sets another user's homepage.
    assert {:error, %Forbidden{}} =
             User.update_homepage_preference(viewer, overview, actor: admin)

    {:ok, group} = UserGroup.create_group(%{name: "homepage-group-#{unique()}"}, actor: system)

    assert {:error, %Forbidden{}} =
             group
             |> Ash.Changeset.for_update(:update_homepage, %{homepage: overview}, actor: viewer)
             |> Ash.update()

    assert {:ok, updated} =
             group
             |> Ash.Changeset.for_update(
               :update_homepage,
               %{homepage: overview, homepage_priority: 10},
               actor: admin
             )
             |> Ash.update()

    assert updated.homepage == overview
    assert updated.homepage_priority == 10

    assert {:error, %Forbidden{}} =
             AuthorizationSettings.save_default_homepage(overview, actor: viewer)

    assert {:ok, settings} = AuthorizationSettings.save_default_homepage(overview, actor: admin)
    assert settings.default_homepage == overview
  end

  test "the hub-default backfill fills an empty homepage and leaves an existing one",
       %{system: system, admin: admin} do
    empty = user!(system, :viewer)
    kept = user!(system, :viewer)
    overview = %{"kind" => "overview"}
    assert {:ok, kept} = User.update_homepage_preference(kept, overview, actor: kept)

    filled = dashboard!(admin, :private)
    other = dashboard!(admin, :private)
    hub_default!(empty, filled, system)
    hub_default!(kept, other, system)

    Repo.query!(AddConfigurableHomepages.backfill_sql())

    assert stored_homepage(empty) == %{
             "kind" => "dashboard",
             "target_type" => "authored",
             "target_id" => filled.id
           }

    assert stored_homepage(kept) == overview

    Repo.query!(AddConfigurableHomepages.backfill_sql())
    assert stored_homepage(empty)["target_id"] == filled.id
    assert stored_homepage(kept) == overview
  end

  defp user!(system, role) do
    suffix = unique()
    password = "SyntheticHomepage#{suffix}!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "homepage-#{role}-#{suffix}@example.test",
          password: password,
          password_confirmation: password
        },
        actor: system
      )

    {:ok, user} = User.update_role(user, %{role: role}, actor: system)
    user
  end

  defp dashboard!(owner, visibility) do
    AuthoredDashboard
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "Homepage target #{unique()}",
        dashboard_ref: 1_000_000 + rem(unique(), 8_999_999),
        visibility: visibility,
        status: :active
      },
      actor: owner
    )
    |> Ash.create!()
  end

  defp hub_default!(user, dashboard, system) do
    {:ok, _preference} =
      DashboardUserPreference.upsert_preference(
        %{
          user_id: user.id,
          target_type: :authored,
          target_id: dashboard.id,
          favorite: false,
          is_default: true,
          metadata: %{}
        },
        actor: system
      )
  end

  defp stored_homepage(user) do
    %{rows: [[homepage]]} =
      Repo.query!("SELECT homepage FROM platform.ng_users WHERE id = ($1::text)::uuid", [user.id])

    homepage
  end

  defp unique, do: System.unique_integer([:positive])
end
