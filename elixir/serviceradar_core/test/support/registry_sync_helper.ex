defmodule ServiceRadar.RegistrySyncHelper do
  @moduledoc false

  def start_registry_unlinked(_registry) do
    ServiceRadar.ProcessRegistry.child_specs()
    |> Enum.reduce_while(nil, fn
      {module, opts}, _last_pid ->
        case module.start_link(opts) do
          {:ok, pid} ->
            Process.unlink(pid)
            {:cont, pid}

          {:error, {:already_started, pid}} ->
            {:cont, pid}

          other ->
            {:halt, other}
        end

      other, _last_pid ->
        {:halt, {:error, {:unsupported_child_spec, other}}}
    end)
    |> case do
      pid when is_pid(pid) -> {:ok, pid}
      other -> other
    end
  end
end
