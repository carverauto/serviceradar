# Run against the guarded lifecycle's quiescent serial_0 scratch clone.
Code.require_file("../test_helper.exs", __DIR__)

ExUnit.configure(exclude: [:test], include: [:web_ng_shared_fixture_db], max_cases: 1)

ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
  if total - excluded - skipped == 0 do
    IO.puts(:stderr, "FAILED: the plugin-config CLI acceptance target executed ZERO tests")
    System.at_exit(fn _ -> System.halt(1) end)
  end
end)
