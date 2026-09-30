# Standalone helper for the MTR reader parity target
# (`//elixir/web-ng:mtr_reader_parity_test`, run by the SrqlParity BuildBuddy
# action). It starts no application and touches no shared fixture database:
# the test opens its own MyXQL connection to the warehouse and its own
# Postgrex connection to a scratch CNPG database it creates, and the MTR
# readers under test run through their `:cnpg_query`/`:starrocks_query`
# seams. Only the driver libraries' OTP applications are started (Postgrex
# verifies the CNPG server over TLS, so `:ssl` and its dependencies must be
# up); the general `test/test_helper.exs` would boot the whole endpoint and
# require the shared fixture instead.
for app <- [:crypto, :ssl, :postgrex, :myxql] do
  {:ok, _} = Application.ensure_all_started(app)
end

ExUnit.start(assert_receive_timeout: 2_000, max_cases: 1)

ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
  selected = total - excluded - skipped

  if selected != 7 do
    IO.puts(:stderr, """

    FAILED: the MTR reader parity target executed #{selected} tests; expected exactly 7.

    Every case in test/integration/starrocks/mtr_reader_parity_test.exs must run:
    a silently skipped reader is an unproven reader. Update this count only when
    the file intentionally gains or loses a case.
    """)

    System.at_exit(fn _ -> System.halt(1) end)
  end
end)
