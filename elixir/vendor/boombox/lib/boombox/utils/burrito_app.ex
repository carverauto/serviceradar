if Code.ensure_loaded?(Burrito) do
  defmodule Boombox.Utils.BurritoApp do
    @moduledoc false

    use Application

    @dialyzer {:no_return, {:start, 2}}
    @impl true
    def start(_type, _args) do
      Boombox.run_cli(Burrito.Util.Args.argv())
      System.halt()
    end
  end
end
