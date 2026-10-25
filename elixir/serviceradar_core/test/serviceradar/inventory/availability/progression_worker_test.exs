defmodule ServiceRadar.Inventory.Availability.ProgressionWorkerTest do
  @moduledoc """
  Owner of the automatic progression's decision (`ProgressionWorker.step/3`, design
  Decision 10, "Automatic progression"): one table over every mode and control.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Availability.ProgressionWorker

  @cases [
    # {mode, control, facts, step}
    {:legacy, :auto, %{restore_pending: false}, :enter_shadow},
    {:legacy, :auto, %{restore_pending: true}, :none},
    {:legacy, :hold_shadow, %{restore_pending: false}, :enter_shadow},
    {:legacy, :hold_shadow, %{restore_pending: true}, :none},
    {:legacy, :hold_legacy, %{restore_pending: false}, :none},
    {:shadow, :auto, %{ready: true, resolved: true}, :enter_cutover},
    {:shadow, :auto, %{ready: false, resolved: true, resolve_outstanding: false}, :none},
    {:shadow, :auto, %{ready: false, resolved: false, resolve_outstanding: false}, :resolve},
    {:shadow, :auto, %{ready: false, resolved: false, resolve_outstanding: true}, :none},
    {:shadow, :hold_shadow, %{ready: true, resolved: true}, :none},
    {:shadow, :hold_shadow, %{ready: false, resolved: false, resolve_outstanding: false},
     :resolve},
    {:shadow, :hold_legacy, %{ready: true, resolved: true}, :enter_legacy},
    {:cutover, :auto, %{reconcile_outstanding: true}, :none},
    {:cutover, :auto, %{reconcile_outstanding: false}, :resume_cutover},
    {:cutover, :hold_shadow, %{reconcile_outstanding: true}, :enter_legacy},
    {:cutover, :hold_legacy, %{reconcile_outstanding: true}, :enter_legacy},
    {:authoritative, :auto, %{}, :none},
    {:authoritative, :hold_shadow, %{}, :enter_legacy},
    {:authoritative, :hold_legacy, %{}, :enter_legacy}
  ]

  test "takes one step per mode and control" do
    for {mode, control, facts, step} <- @cases do
      assert ProgressionWorker.step(mode, control, facts) == step,
             "#{mode} under #{control} with #{inspect(facts)}"
    end
  end

  test "an invalid pin holds every mode, ready or not" do
    for mode <- [:legacy, :shadow, :cutover, :authoritative] do
      assert ProgressionWorker.step(mode, :invalid, %{ready: true, restore_pending: false}) ==
               :none
    end
  end
end
