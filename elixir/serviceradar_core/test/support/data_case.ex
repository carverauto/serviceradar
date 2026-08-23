defmodule ServiceRadar.DataCase do
  @moduledoc """
  ExUnit case template for tests that use the ServiceRadar database.

  Each test runs under its own rollback-only sandbox owner. Serial tests may
  share that owner with application processes. Async tests may contain only
  transaction-isolated work: unboxed access, DDL, `TRUNCATE`, refreshes,
  application-global state, global processes, true multi-connection work, and
  fixed external resources remain serial. Async tests may call
  `allow_sandbox/1` only for children they own and stop before test teardown.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Every test using this template checks out a Repo connection, which only exists
      # once the application has been started -- and test_helper.exs starts it only when
      # a database URL is present. Tagging here rather than in each test file means a new
      # `use ServiceRadar.DataCase` is classified correctly without anyone remembering to.
      @moduletag :requires_app
    end
  end

  setup context do
    ServiceRadar.TestSupport.checkout_repo!(context)
  end

  @doc "Allows a test-owned child process to query through the caller's sandbox owner."
  defdelegate allow_sandbox(child_pid), to: ServiceRadar.TestSupport
end
