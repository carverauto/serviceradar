# This focused target reuses the already-provisioned serial_0 integration database after the
# core lanes finish. Select only the cases that are intentionally assigned to this shared
# fixture lane; the ordinary database-free target still loads these files but cannot run them.
Code.require_file("../test_helper.exs", __DIR__)

ExUnit.configure(
  exclude: [:test],
  include: [:web_ng_shared_fixture_db],
  max_cases: 1
)

expected_selected_tests = 111

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
