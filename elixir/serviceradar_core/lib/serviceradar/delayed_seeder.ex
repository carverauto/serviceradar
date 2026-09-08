defmodule ServiceRadar.DelayedSeeder do
  @moduledoc false

  defmacro __using__(opts) do
    delay_ms = Keyword.get(opts, :delay_ms, 5_000)
    callback = Keyword.get(opts, :callback, :seed)

    quote bind_quoted: [delay_ms: delay_ms, callback: callback] do
      use GenServer

      @seed_delay_ms delay_ms
      @seed_callback callback

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl true
      def init(_opts) do
        Process.send_after(self(), :seed, @seed_delay_ms)
        {:ok, %{}}
      end

      @impl true
      def handle_info(:seed, state) do
        apply(__MODULE__, @seed_callback, [])
        {:noreply, state}
      end

      defp repo_enabled? do
        Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
          is_pid(Process.whereis(ServiceRadar.Repo))
      end
    end
  end
end
