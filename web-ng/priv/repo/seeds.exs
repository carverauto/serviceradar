# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     ServiceRadarWebNG.Repo.insert!(%ServiceRadarWebNG.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias ServiceRadar.Identity.{Tenant, User, TenantMembership}

IO.puts("Seeding test tenants...")

# Define test tenant configurations
tenants = [
  %{
    id: "00000000-0000-0000-0000-000000000000",
    name: "Default Organization",
    slug: "default",
    owner_email: "admin@default.local",
    owner_password: "password123456"
  },
  %{
    id: "00000000-0000-0000-0000-000000000002",
    name: "Tenant Two",
    slug: "tenant-two",
    owner_email: "admin@tenant-two.local",
    owner_password: "password123456"
  }
]

for tenant_config <- tenants do
  # Get or create tenant
  tenant =
    case Ash.get(Tenant, tenant_config.id, authorize?: false) do
      {:ok, existing_tenant} ->
        IO.puts("  Tenant '#{existing_tenant.name}' already exists (#{existing_tenant.id})")
        existing_tenant

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        IO.puts("  Creating tenant '#{tenant_config.name}'...")

        {:ok, tenant} =
          Tenant
          |> Ash.Changeset.for_create(:create, %{
            name: tenant_config.name,
            slug: tenant_config.slug
          })
          |> Ash.Changeset.force_change_attribute(:id, tenant_config.id)
          |> Ash.create(authorize?: false)

        IO.puts("    Created tenant: #{tenant.name} (#{tenant.id})")
        tenant

      {:error, error} ->
        IO.puts("  Error checking tenant: #{inspect(error)}")
        nil
    end

  if tenant do
    # Check if owner user exists
    {:ok, user_result} =
      ServiceRadar.Repo.query(
        "SELECT id, email FROM ng_users WHERE email = $1",
        [tenant_config.owner_email]
      )

    user =
      if user_result.num_rows == 0 do
        IO.puts("    Creating owner user #{tenant_config.owner_email}...")

        {:ok, user} =
          User
          |> Ash.Changeset.for_create(:register_with_password, %{
            email: tenant_config.owner_email,
            password: tenant_config.owner_password,
            password_confirmation: tenant_config.owner_password,
            tenant_id: tenant.id
          })
          |> Ash.create(authorize?: false)

        IO.puts("      Created: #{user.email}")
        user
      else
        [[user_id, email] | _] = user_result.rows
        IO.puts("    Owner user #{email} already exists")
        %{id: user_id}
      end

    # Convert UUIDs to binary for query (handle both string and binary cases)
    user_id_bin =
      if is_binary(user.id) and byte_size(user.id) == 16,
        do: user.id,
        else: Ecto.UUID.dump!(to_string(user.id))

    tenant_id_bin =
      if is_binary(tenant.id) and byte_size(tenant.id) == 16,
        do: tenant.id,
        else: Ecto.UUID.dump!(to_string(tenant.id))

    # Check if membership exists
    {:ok, membership_result} =
      ServiceRadar.Repo.query(
        "SELECT id FROM tenant_memberships WHERE user_id = $1 AND tenant_id = $2",
        [user_id_bin, tenant_id_bin]
      )

    if membership_result.num_rows == 0 do
      IO.puts("    Creating owner membership...")
      # Get string UUID for Ash call
      user_id_str =
        if is_binary(user.id) and byte_size(user.id) == 16,
          do: Ecto.UUID.cast!(user.id),
          else: to_string(user.id)

      tenant_id_str =
        if is_binary(tenant.id) and byte_size(tenant.id) == 16,
          do: Ecto.UUID.cast!(tenant.id),
          else: to_string(tenant.id)

      {:ok, _membership} =
        TenantMembership
        |> Ash.Changeset.for_create(:create, %{
          user_id: user_id_str,
          tenant_id: tenant_id_str,
          role: :owner
        })
        |> Ash.create(tenant: tenant_id_str, authorize?: false)

      IO.puts("      Created membership")
    else
      IO.puts("    Membership already exists")
    end
  end
end

IO.puts("\nSeeding complete!")
IO.puts("\nTest credentials:")
IO.puts("  Default tenant: admin@default.local / password123456")
IO.puts("  Tenant Two:     admin@tenant-two.local / password123456")
