# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# This seeds file is for the dedicated deployment UI (web-ng).
# In the single-deployment model, each deployment serves one account.
# The schema context is implicit from the PostgreSQL search_path
# configured by infrastructure.

IO.puts("Seeding default admin user...")

ServiceRadarWebNG.Bootstrap.AdminUser.ensure_admin_user()

IO.puts("Seeding complete!")
