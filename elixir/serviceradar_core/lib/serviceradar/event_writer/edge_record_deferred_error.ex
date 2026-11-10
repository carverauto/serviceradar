defmodule ServiceRadar.EventWriter.EdgeRecordDeferredError do
  @moduledoc "A committed recovery receipt whose remaining work requires broker redelivery."
  defexception [:state]

  @impl true
  def message(%__MODULE__{state: state}), do: "recovery receipt committed; projection #{state}"
end
