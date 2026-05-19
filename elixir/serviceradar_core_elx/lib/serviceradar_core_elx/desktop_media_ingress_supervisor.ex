defmodule ServiceRadarCoreElx.DesktopMediaIngressSupervisor do
  @moduledoc """
  Supervises per-session desktop media ingress processes on core-elx nodes.
  """

  use DynamicSupervisor

  alias ServiceRadarCoreElx.DesktopMediaIngressSession

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_session(session, opts \\ []) when is_map(session) do
    child_spec = %{
      id: {DesktopMediaIngressSession, session.desktop_session_id},
      start: {DesktopMediaIngressSession, :start_link, [session, opts]},
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
