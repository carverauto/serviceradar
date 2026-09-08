defmodule ServiceRadar.TestSupport.SynchronousStatefulAlertEvaluationQueue do
  @moduledoc false

  def enqueue_events(events) do
    ServiceRadar.Observability.StatefulAlertEngine.evaluate_events(events)
  end
end
