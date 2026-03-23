defmodule ServiceRadar.Camera.RelayTerminationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelayTermination

  test "classifies failures from failed relay sessions" do
    assert RelayTermination.kind(%{status: :failed, failure_reason: "agent_offline"}) == :failure

    assert RelayTermination.kind_string(%{status: :failed, failure_reason: "agent_offline"}) ==
             "failure"
  end

  test "classifies viewer idle shutdowns" do
    assert RelayTermination.kind(%{status: :closed, close_reason: "viewer idle timeout"}) ==
             :viewer_idle
  end

  test "classifies transport drain shutdowns" do
    assert RelayTermination.kind(%{
             status: :closed,
             close_reason: "camera relay drain acknowledged"
           }) ==
             :transport_drain
  end

  test "classifies manual shutdowns" do
    assert RelayTermination.kind(%{
             status: :closing,
             close_reason: "viewer closed device details"
           }) ==
             :manual_stop
  end

  test "classifies source completion separately from manual shutdown" do
    assert RelayTermination.kind(%{
             status: :closed,
             close_reason: "camera relay source completed"
           }) ==
             :source_complete
  end

  test "returns nil for active sessions without a terminal reason" do
    assert RelayTermination.kind(%{status: :active, close_reason: nil, failure_reason: nil}) ==
             nil
  end
end
