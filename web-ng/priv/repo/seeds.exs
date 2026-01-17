# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# This seeds file is for the dedicated deployment UI (web-ng).
# In the single-deployment model, each deployment serves one account.
# The schema context is implicit from the PostgreSQL search_path
# configured by infrastructure.

alias ServiceRadar.Identity.User

IO.puts("Seeding default admin user...")

# Default admin credentials (override via environment variables)
admin_email = System.get_env("ADMIN_EMAIL", "admin@serviceradar.local")
admin_password = System.get_env("ADMIN_PASSWORD", "password123456")

# Check if admin user exists
{:ok, user_result} =
  ServiceRadar.Repo.query(
    "SELECT id, email FROM ng_users WHERE email = $1",
    [admin_email]
  )

if user_result.num_rows == 0 do
  IO.puts("  Creating admin user #{admin_email}...")

  {:ok, user} =
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: admin_email,
      password: admin_password,
      password_confirmation: admin_password
    })
    |> Ash.create(authorize?: false)

  IO.puts("  Created: #{user.email}")
else
  [[_user_id, email] | _] = user_result.rows
  IO.puts("  Admin user #{email} already exists")
end

IO.puts("\nSeeding complete!")
IO.puts("\nDefault credentials:")
IO.puts("  Email: #{admin_email}")
IO.puts("  Password: #{admin_password}")
IO.puts("\nNote: Override with ADMIN_EMAIL and ADMIN_PASSWORD environment variables.")
