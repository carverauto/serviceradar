defmodule ServiceRadar.Oban.TenantQueuesTest do
  @moduledoc """
  Tests for Oban queue management.

  Verifies that:
  - Queue names are correctly returned
  - Queue types are defined
  - Default concurrency settings exist
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Oban.TenantQueues

  describe "get_queue_name/1" do
    test "returns the queue type as-is" do
      assert TenantQueues.get_queue_name(:default) == :default
      assert TenantQueues.get_queue_name(:alerts) == :alerts
      assert TenantQueues.get_queue_name(:service_checks) == :service_checks
    end
  end

  describe "get_all_queue_names/0" do
    test "returns all queue types" do
      queues = TenantQueues.get_all_queue_names()

      assert is_list(queues)
      assert :default in queues
      assert :alerts in queues
      assert :service_checks in queues
      assert :events in queues
    end
  end

  describe "queue_types/0" do
    test "returns list of queue type atoms" do
      types = TenantQueues.queue_types()

      assert is_list(types)
      assert :default in types
      assert :alerts in types
      assert :service_checks in types
      assert :events in types
      assert :nats_accounts in types
    end
  end

  describe "default_concurrency/0" do
    test "returns concurrency map" do
      concurrency = TenantQueues.default_concurrency()

      assert is_map(concurrency)
      assert Map.has_key?(concurrency, :default)
      assert Map.has_key?(concurrency, :alerts)
      assert is_integer(concurrency.default)
      assert concurrency.default > 0
    end

    test "has concurrency for all queue types" do
      concurrency = TenantQueues.default_concurrency()
      types = TenantQueues.queue_types()

      for type <- types do
        assert Map.has_key?(concurrency, type),
               "Missing concurrency setting for queue type: #{type}"
      end
    end
  end
end
