defmodule ServiceRadar.DataCase do
  @moduledoc """
  ExUnit case template for tests that use the ServiceRadar database.

  Each test runs under its own rollback-only sandbox owner. Synchronous tests
  share that owner with supervised and background processes started by the
  test. Use `@tag sandbox: :unboxed` only for DDL or true multi-connection
  concurrency tests, and clean up every row such a test commits.
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
end
