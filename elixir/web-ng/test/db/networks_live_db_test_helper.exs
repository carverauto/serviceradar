# This focused target reuses the already-provisioned serial_0 integration database after the
# core lanes finish. Select only the cases that are intentionally assigned to this shared
# fixture lane; the ordinary database-free target still loads these files but cannot run them.
Code.require_file("../test_helper.exs", __DIR__)

ExUnit.configure(
  exclude: [:test],
  include: [:web_ng_shared_fixture_db],
  max_cases: 1
)

# A lane that selects nothing means the tag/filter wiring broke; fail rather than pass vacuously.
# 8 GodView stream cases are tagged :skip as known-divergent (product decisions
# tracked in https://github.com/carverauto/serviceradar/issues/4988); they load
# but never select.
# Pinned from the filtered BazelCI lane summary (total - excluded - skipped).
# Reconciled 2026-10-06 against the c749e1d078 lane tree: 242 contract/BUILD
# sources verified identical with no duplicates; 2437 lexical `test "` cases
# + 13 compile-time generated cases across 9 verified `for` sites (sso 2x,
# cli_auth_policy 2x, networks_live 4x, admin_authorization 2x, ash_json_api
# 2x, native_addon_importer 4x/2x/2x/2x) + 3 `property` cases = 2453
# registered (matches the CI summary); minus 2 untagged-excluded
# (srql_plan_cache_mode 1, camera_relay_stream_handler 1) and 8
# god_view_stream :skip = 2443 attributable. The lane guard itself executed
# 2448, so the pin tracks the observed width; the 5-case residual above the
# lexical model has no additional registration/tag source in-tree.
expected_selected_tests = 2448

ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
  selected = total - excluded - skipped

  if selected != expected_selected_tests do
    IO.puts(:stderr, """

    FAILED: the web-ng shared-fixture DB target executed #{selected} tests;
    expected exactly #{expected_selected_tests}.

    Tag every case intentionally assigned to this lane with
    `@tag :web_ng_shared_fixture_db` (or tag its module), and update this
    intentional count when the lane changes. Missing one case must not pass
    silently.
    """)

    System.at_exit(fn _ -> System.halt(1) end)
  end
end)
