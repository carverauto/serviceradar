defmodule ServiceRadar.EventWriter.HealthTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Health

  describe "status/0" do
    test "returns status map when EventWriter is disabled" do
      status = Health.status()

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :running)
      assert Map.has_key?(status, :timestamp)
      assert %DateTime{} = status.timestamp
    end
  end

  describe "check/0" do
    test "returns :ok when EventWriter is disabled" do
      # By default, EventWriter is disabled
      assert Health.check() == :ok
    end
  end

  describe "healthy?/0" do
    test "returns true when EventWriter is disabled (disabled is healthy)" do
      assert Health.healthy?() == true
    end
  end
end
