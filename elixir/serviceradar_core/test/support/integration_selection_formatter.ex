defmodule ServiceRadar.IntegrationSelectionFormatter do
  @moduledoc false

  use GenServer

  @output_env "SERVICERADAR_INTEGRATION_SELECTION_OUTPUT"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(_opts), do: {:ok, %{output_path: output_path!(), selected: MapSet.new()}}

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _reason}}}, state),
    do: {:noreply, state}

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    identity = identity!(test)

    if MapSet.member?(state.selected, identity) do
      raise ArgumentError, "duplicate selected test identity: #{identity}"
    end

    {:noreply, %{state | selected: MapSet.put(state.selected, identity)}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    state.selected
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&atomic_write!(state.output_path, &1 <> if(&1 == "", do: "", else: "\n")))

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp output_path! do
    case System.get_env(@output_env) do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> raise ArgumentError, "#{@output_env} must name the formatter output file"
          path -> path
        end

      nil ->
        raise ArgumentError, "#{@output_env} must name the formatter output file"
    end
  end

  defp identity!(%ExUnit.Test{module: module, name: name})
       when is_atom(module) and is_atom(name) do
    module_name = inspect(module)
    test_name = Atom.to_string(name)

    if String.contains?(module_name, ["\n", "\r", "|"]) or
         String.contains?(test_name, ["\n", "\r", "|"]) do
      raise ArgumentError,
            "ambiguous selected test identity: #{inspect(%{module: module_name, name: test_name})}"
    end

    "#{module_name}|#{test_name}"
  end

  defp identity!(%ExUnit.Test{} = test) do
    raise ArgumentError,
          "selected test identity requires atom module and name: #{inspect(%{module: test.module, name: test.name})}"
  end

  defp atomic_write!(path, contents) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}"
      )

    try do
      File.write!(temporary_path, contents)
      File.rename!(temporary_path, path)
    after
      File.rm(temporary_path)
    end
  end
end
