defmodule ServiceRadarWebNG.CertificatePolicyCache do
  @moduledoc "Coalesces public signed-policy reads; cached policy is never served after five seconds."
  use GenServer

  alias ServiceRadar.Edge.ComponentCertificateAuthority

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def fetch do
    GenServer.call(__MODULE__, :fetch, 10_000)
  catch
    :exit, _ -> {:error, :policy_unavailable}
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(:fetch, _from, state) do
    now = System.monotonic_time(:millisecond)

    case state do
      {until, envelope} when now < until ->
        {:reply, {:ok, envelope}, state}

      _ ->
        with {:ok, envelope} <- ComponentCertificateAuthority.sign_public_snapshot(),
             payload = envelope.payload |> Base.decode64!() |> Jason.decode!(),
             {:ok, valid_until, 0} <- DateTime.from_iso8601(payload["valid_until"]),
             lifetime = min(5_000, DateTime.diff(valid_until, DateTime.utc_now(), :millisecond)),
             true <- lifetime > 0 do
          {:reply, {:ok, envelope}, {System.monotonic_time(:millisecond) + lifetime, envelope}}
        else
          _ -> {:reply, {:error, :policy_unavailable}, nil}
        end
    end
  end
end
