defmodule ServiceRadarWebNG.TestSupport.ProvisioningIdempotencyStub do
  @moduledoc false

  def run(identity, params, create, read) do
    send(self(), {:idempotent_request, identity, params})

    case Process.get({__MODULE__, :replay}) do
      nil -> create.()
      id -> read.(id)
    end
  end
end
