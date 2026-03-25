defmodule Boombox.Pipeline do
  @moduledoc false
  use Membrane.Pipeline

  @type opts_map :: %{
          input: Boombox.input() | Boombox.elixir_input(),
          output: Boombox.output() | Boombox.elixir_output()
        }
  @type procs :: %{pipeline: pid(), supervisor: pid()}

  @spec start_link(opts_map()) :: procs()
  def start_link(opts) do
    opts = Map.put(opts, :parent, self())

    {:ok, supervisor, pipeline} =
      Membrane.Pipeline.start_link(Boombox.Pipeline, opts)

    Process.monitor(supervisor)
    %{supervisor: supervisor, pipeline: pipeline}
  end

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:boombox, %Boombox.InternalBin{
        input: opts.input,
        output: opts.output,
        parent: opts.parent
      })

    {[spec: spec], %{parent: opts.parent}}
  end

  @impl true
  def handle_child_notification(:external_resource_ready, _element, _context, state) do
    send(state.parent, :external_resource_ready)
    {[], state}
  end

  @impl true
  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[terminate: :normal], state}
  end
end
