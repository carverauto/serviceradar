defmodule ServiceRadar.DataCase do
  @moduledoc """
  ExUnit case template for tests that use the ServiceRadar database.

  Each test runs under its own rollback-only sandbox owner. Synchronous tests
  share that owner with supervised and background processes started by the
  test. Use `@tag sandbox: :unboxed` only for DDL or true multi-connection
  concurrency tests, and clean up every row such a test commits.
  """

  use ExUnit.CaseTemplate

  setup context do
    ServiceRadar.TestSupport.checkout_repo!(context)
  end
end
