defmodule ServiceRadar.Edge.ProxmoxConsoleBroker do
  @moduledoc """
  Broker boundary for Proxmox browser console byte streams.

  The browser websocket handler talks to this module instead of directly to
  agent transport details. The Go edge-side PTY bridge will implement this
  contract in a later stack slice.
  """

  @callback start_link(map(), pid(), keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary()) :: :ok | {:error, term()}
  @callback resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback close(pid(), term()) :: :ok

  def start_link(_session, _owner, _opts \\ []), do: {:error, :console_broker_unavailable}

  def send_input(_broker, _data), do: {:error, :console_broker_unavailable}

  def resize(_broker, _cols, _rows), do: {:error, :console_broker_unavailable}

  def close(_broker, _reason), do: :ok
end
