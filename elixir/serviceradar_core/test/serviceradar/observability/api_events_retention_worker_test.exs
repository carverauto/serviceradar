defmodule ServiceRadar.Observability.ApiEventsRetentionWorkerTest do
  @moduledoc """
  Unit coverage for ApiEventsRetentionWorker's retention-window resolution
  (default 90, operator override). The delete behavior at the window
  boundary is covered against a real database by
  AuditHistoryRetentionIntegrationTest.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.ApiEventsRetentionWorker

  setup do
    original = Application.get_env(:serviceradar_core, ApiEventsRetentionWorker)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_core, ApiEventsRetentionWorker)
      else
        Application.put_env(:serviceradar_core, ApiEventsRetentionWorker, original)
      end
    end)

    :ok
  end

  test "defaults to 90 days with no configured override" do
    Application.delete_env(:serviceradar_core, ApiEventsRetentionWorker)

    assert ApiEventsRetentionWorker.retention_days() == 90
  end

  test "honors a configured retention override" do
    Application.put_env(:serviceradar_core, ApiEventsRetentionWorker, retention_days: 30)

    assert ApiEventsRetentionWorker.retention_days() == 30
  end
end
