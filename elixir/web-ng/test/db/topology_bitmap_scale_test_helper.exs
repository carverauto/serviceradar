# Reuse the guarded, migrated scratch clone and its fail-closed zero-test check.
Code.require_file("topology_atlas_db_test_helper.exs", __DIR__)
Code.require_file("../integration/topology_bitmap_scale/support.exs", __DIR__)
ExUnit.configure(exclude: [:test], include: [:topology_bitmap_scale], max_cases: 1)

# Peers and the writer must see committed mutations. This target owns its
# quiescent scratch clone until the existing hosted lifecycle tears it down.
:ok = Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :auto)
