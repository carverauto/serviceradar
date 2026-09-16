defmodule ServiceRadarWebNG.TestSupport.NetworkCredentialRuleLifecycleStub do
  @moduledoc false

  def delete_rule(id, opts) do
    send(self(), {:delete_rule, id, opts})
    Process.get({__MODULE__, :result}, :ok)
  end
end
