defmodule ServiceRadarCoreElx.CameraMediaIngressSupervisor do
  @moduledoc """
  Supervises per-session camera relay ingress processes on core-elx nodes.
  """

  use DynamicSupervisor

  alias ServiceRadarCoreElx.CameraMediaIngressSession

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_session(session, opts \\ []) when is_map(session) do
    child_spec = %{
      id: {CameraMediaIngressSession, session.relay_session_id},
      start: {CameraMediaIngressSession, :start_link, [session, opts]},
      restart: :temporary,
      shutdown: 5_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
