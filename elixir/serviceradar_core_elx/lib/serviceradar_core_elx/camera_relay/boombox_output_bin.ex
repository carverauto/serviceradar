defmodule ServiceRadarCoreElx.CameraRelay.BoomboxOutputBin do
  @moduledoc """
  Stable wrapper around `Boombox.Bin` for relay-attached output branches.

  `Boombox.Bin` expects its sink-side input pad to exist before it enters playback.
  Wrapping it in a bin with a static input pad avoids the hot-attach race when adding
  analysis branches to an already-playing relay pipeline.
  """

  use Membrane.Bin

  alias Boombox.Bin, as: BoomboxBin
  alias Membrane.Pad

  def_input_pad(:input, accepted_format: _any, availability: :on_request, max_instances: 1)

  def_options(
    output: [
      spec: String.t(),
      description: "Destination accepted by `Boombox.Bin` output option."
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{output: opts.output}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    spec = [
      child(:boombox, %BoomboxBin{output: state.output}, get_if_exists: true),
      pad
      |> bin_input()
      |> via_in(Pad.ref(:input, :video), options: [kind: :video])
      |> get_child(:boombox)
    ]

    {[spec: spec], state}
  end
end
