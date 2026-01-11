defmodule ServiceRadar.RegistrySyncHelper do
  @moduledoc false

  def start_registry_unlinked(registry) do
    case registry.start_link([]) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      other ->
        other
    end
  end
end
