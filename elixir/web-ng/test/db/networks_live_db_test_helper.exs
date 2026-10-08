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
# sources verified identical with no duplicates. A lexical `test "` grep
# (≈2437) plus 13 compile-time generated cases across 9 verified `for` sites
# plus 3 `property` cases only approximates the 2453 total the CI summary
# reports: grep cannot see runtime-registered cases (properties expand per
# seed, `for` sites and doctests register at compile time), and ExUnit's
# `total`/`excluded`/`skipped` accounting is defined by the runner, not by
# the grep. The pin therefore tracks the guard-observed width from the CI
# summary, not the lexical model; the arithmetic gap between the two
# is a model limit, not an attribution to chase in-tree.
# The in-cluster WebNgDbDiagnostic observed 2449 selected at the 678e43e
# tree with failures confined to two behavioral assertions (neither
# selectional). The rebase onto newer staging after that head added
# lane-selected tests this pin must cover: +4 in metrics_controller_test
# (the /metrics auth split: 6 added, 2 renamed away, all module-tagged)
# and +2 in log_live/index_test (limit-clamp tests, explicitly tagged).
# Staging also added 3 tests with no lane tag at all (2 alert-detail
# resolution tests, 1 device alerts-tab test); they are tagged into this
# lane alongside this bump since both files were already in the lane srcs.
# 2449 + 4 + 2 + 3 = 2458, with no lowering, removal, bypass, or exclusion.
# The rebase onto staging 21fd58b9f (fleet-pagination feature #5508) adds
# +2 lane-selected tests in addon_fleet_live_test.exs (disconnected mount
# makes no queries; >100-row stream rendering), both covered by the file's
# existing @moduletag with no skip/exclude. Staging's other test deltas
# select outside this lane (:db_free ash_domains/oban additions) or net to
# zero (collector bundle generator rename). 2458 + 2 = 2460; hosted BazelCI
# must confirm the runtime count.
# PR #5524 (de742e6399) adds +4 lane-selected tests, each covered by its
# file's existing @moduletag :web_ng_shared_fixture_db with no skip/exclude:
# LocalTest "deactivate_user ends the user's sessions", GuardianTest
# "a token issued before deactivation stops verifying", TokenRevocationTest
# "keeps the user marker beyond the longest configurable token lifetime",
# and GatewayAuthPolicyTest "passive proxy refuses an inactive mapped user
# without creating a session". The Api.UserControllerTest change is a
# rename/strengthening of the existing "deactivates a user" case in an
# already-tagged module, not a new selection. 2460 + 4 = 2464, with no
# lowering, removal, bypass, or exclusion.
expected_selected_tests = 2464

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
