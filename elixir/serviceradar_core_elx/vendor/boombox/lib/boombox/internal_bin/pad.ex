defmodule Boombox.InternalBin.Pad do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad

  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.Bin.{Action, CallbackContext}
  alias Membrane.Connector

  @type new_tracks_notification_status ::
          :not_resolved
          | :will_be_sent
          | :sent
          | :never_sent

  # The lifecycle of the new_tracks_notification_status and the execution of Boombox.InternalBin.link_output function
  #
  # BEGIN: InternalBin handle_playing
  #   |
  #   |
  #   |                                                         state output != membrane_pad or
  #   \/                                                 there are some pads linked before handle_playing
  # new_tracks_notification_status == :not_resolved ----------------------------------------------------------> new_tracks_notification_status == :never_sent
  #   |
  #   |     state.output == :membrane_pad and
  #   | there are no pads linked during handle_playing
  #   |
  #   \/
  # new_tracks_notification_status == :will_be_sent
  #   |
  #   |    sending {:new_tracks, tracks}
  #   | notification in link_output function
  #   |
  #   \/
  # new_tracks_notification_status == :sent
  #   |
  #   |
  #   |       |-----------------------------------------------------------|
  #   |       |                                                           |
  #   \/      \/         not all required pads are linked                 |
  # handle_pad_added  --------------------------------------> wait on the next handle_pad_added
  #   |
  #   | all tracks from {:new_tracks, tracks}
  #   |    have their related pad linked
  #   |
  #   \/
  # state.status == :output_linked

  @spec resolve_new_tracks_notification_status(
          Boombox.InternalBin.State.t(),
          CallbackContext.t()
        ) :: Boombox.InternalBin.State.t()
  def resolve_new_tracks_notification_status(state, %{playback: :playing} = ctx) do
    status =
      if state.output == :membrane_pad and map_size(ctx.pads) == 0,
        do: :will_be_sent,
        else: :never_sent

    %{state | new_tracks_notification_status: status}
  end

  @spec handle_pad_added(
          Membrane.Pad.ref(),
          :audio | :video,
          CallbackContext.t(),
          Boombox.InternalBin.State.t()
        ) ::
          [Action.t()] | no_return()
  def handle_pad_added(pad_ref, kind, ctx, state) do
    if ctx.playback == :playing and state.new_tracks_notification_status != :sent do
      raise """
      Boombox.InternalBin pad #{inspect(pad_ref)} was added while the Boombox.InternalBin playback \
      is already :playing, but {:new_tracks, tracks} notification was not sent yet.

      You can either:
        * link all the pads of Boombox.InternalBin in the same spec where you spawn it,
        * or wait until Boombox.InternalBin returns a notification {:new_tracks, tracks} and then \
        link the pads accodring to the notification.
      """
    end

    spec =
      case Pad.name_by_ref(pad_ref) do
        :input ->
          bin_input(pad_ref)
          |> child({:pad_connector, :input, kind}, Connector)

        :output ->
          child({:pad_connector, :output, kind}, Connector)
          |> bin_output(pad_ref)
      end

    [spec: spec]
  end

  @spec create_input(CallbackContext.t()) :: Ready.t() | Wait.t() | no_return()
  def create_input(ctx) when ctx.playback == :playing and ctx.pads == %{} do
    raise """
    Cannot create input of type #{inspect(__MODULE__)}, as there are no pads available. \
    Link pads to Boombox.InternalBin or set the `:input` option to fix this error.
    """
  end

  def create_input(ctx) when ctx.playback == :playing do
    track_builders =
      ctx.pads
      |> Enum.flat_map(fn
        {Pad.ref(:input, _id), %{options: %{kind: kind}}} ->
          [{kind, get_child({:pad_connector, :input, kind})}]

        {Pad.ref(:output, _id), _pad_data} ->
          []
      end)
      |> Map.new()

    %Ready{track_builders: track_builders}
  end

  def create_input(ctx) when ctx.playback == :stopped do
    %Wait{}
  end

  @spec link_output(
          CallbackContext.t(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          Boombox.InternalBin.State.t()
        ) :: {Ready.t() | Wait.t(), Boombox.InternalBin.State.t()}
  def link_output(ctx, track_builders, spec_builder, state) do
    case state.new_tracks_notification_status do
      _any when ctx.playback == :stopped ->
        {%Wait{}, state}

      :will_be_sent when ctx.playback == :playing ->
        actions = [notify_parent: {:new_tracks, Map.keys(track_builders)}]
        state = %{state | new_tracks_notification_status: :sent}
        {%Wait{actions: actions}, state}

      :sent when ctx.playback == :playing ->
        if map_size(ctx.pads) == map_size(track_builders),
          do: do_link_output(ctx, track_builders, spec_builder, state),
          else: {%Wait{}, state}

      :never_sent when ctx.playback == :playing ->
        do_link_output(ctx, track_builders, spec_builder, state)
    end
  end

  defp do_link_output(ctx, track_builders, spec_builder, state) do
    validate_pads_and_tracks!(ctx, track_builders)

    linked_tracks =
      track_builders
      |> Enum.map(fn {kind, builder} ->
        pad_options =
          ctx.pads
          |> Enum.find_value(fn
            {Pad.ref(:output, _id), %{options: %{kind: ^kind} = options}} -> options
            _pad_entry -> nil
          end)

        builder
        |> child(%Membrane.Transcoder{
          output_stream_format: &resolve_stream_format(&1, pad_options, state),
          transcoding_policy: pad_options.transcoding_policy
        })
        |> get_child({:pad_connector, :output, kind})
      end)

    spec = [spec_builder, linked_tracks]
    {%Ready{actions: [spec: spec]}, state}
  end

  defp resolve_stream_format(%input_codec{}, %{kind: pad_kind, codec: pad_codec}, state) do
    default_codec =
      case pad_kind do
        :audio -> if webrtc_input?(state), do: Membrane.Opus, else: Membrane.AAC
        :video -> Membrane.H264
      end

    pad_codecs = Bunch.listify(pad_codec || default_codec)

    if input_codec in pad_codecs,
      do: input_codec,
      else: List.first(pad_codecs)
  end

  defp validate_pads_and_tracks!(ctx, track_builders) do
    output_pads =
      ctx.pads
      |> Enum.filter(fn {Pad.ref(name, _id), _data} ->
        name == :output
      end)
      |> Map.new(fn {pad_ref, %{options: %{kind: kind}}} ->
        {kind, pad_ref}
      end)

    raise_if_key_not_present(track_builders, output_pads, fn kind ->
      "Boombox.Bin has no output pad of kind #{inspect(kind)}, but it has a track \
      of this kind. Please add an output pad of this kind to the Boombox.Bin."
    end)

    raise_if_key_not_present(output_pads, track_builders, fn kind ->
      "Boombox.Bin has no track of kind #{inspect(kind)}, but it has an output pad \
      of this kind. Please add a track of this kind to the Boombox.Bin."
    end)
  end

  defp raise_if_key_not_present(map_from, map_in, error_log_generator) do
    map_from
    |> Enum.each(fn {kind, _value} ->
      if not is_map_key(map_in, kind) do
        raise error_log_generator.(kind)
      end
    end)
  end

  defp webrtc_input?(state) do
    case state.input do
      {:webrtc, _signaling} -> true
      {:webrtc, _signaling, _opts} -> true
      _other -> false
    end
  end
end
