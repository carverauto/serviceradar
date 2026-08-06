defmodule Boombox.Server do
  @moduledoc false
  # This module provides a GenServer interface for Boombox. To run Boombox the server needs to be
  # called with `{:run, boombox_opts}` - it can be done by calling `run/2`, sending a
  # `{:call, :run, boombox_opts}` message to the server or calling the server directly with
  # `GenServer.call/3`. The return value signals what mode Boombox is in. Once Boombox is running
  # it can be interacted with through appropriate functions, GenServer calls and messages:
  #   * Function calls - `consume_packet/2`, `finish_consuming/1` and `produce_packet/1` are functions
  #                      that can be used for communication with the server.
  #   * GenServer calls - `{:consume_packet, packet}`, `:finish_consuming` and `:produce_packet` are
  #                        terms that the server can be called with. These calls will behave the same
  #                        way as their respective functions mentioned above.
  #   * Messages - `{:call, sender, {:consume_packet, packet}}`, `{:call, sender, :finish_consuming}`
  #                and `{:call, sender, :produce_packet}` messages will cause the server to handle the
  #                call specified by the third element of the tuple and send a `{:response, response}`
  #                tuple to the `sender` when finished.
  # The packets that Boombox is consuming and producing are in the form of
  # `t:serialized_boombox_packet/0` or `t:Boombox.Packet.t/0`, depending on set options.
  #
  # Avaliable actions:
  # write buffer to boombox synchronously
  # write buffer to boombox asynchronously
  # read buffer from boombox synchronously
  # receive buffer from boombox asynchronously (message)
  # close boombox for wrtiting
  # close boombox for reading

  use GenServer

  require Logger

  alias Boombox.Packet

  @type t :: GenServer.server()

  @type communication_medium :: :calls | :messages
  @type flow_control :: :push | :pull

  @type opts :: [
          name: GenServer.name(),
          packet_serialization: boolean(),
          stop_application: boolean(),
          communication_medium: communication_medium(),
          parent_pid: pid()
        ]

  @type boombox_opts :: [
          input: Boombox.input() | {:writer | :message, Boombox.in_raw_data_opts()},
          output: Boombox.output() | {:reader | :message, Boombox.out_raw_data_opts()}
        ]

  @typedoc """
  Mode in which Boombox is operating:
    * `:consuming` - Boombox consumes packets provided with `consume_packet/2` calls,
                     `{:consume_packet, packet}` GenServer calls or receiving
                     `{:call, sender, {:consume_packet, packet}.
    * `:producing` - Boombox produces packets in response to `produce_packet/1` calls,
                     being called directly with `:produce_packet` or receiving
                     `{:call, sender, :produce_packet}` messages.
    * `:standalone` - Boombox neither consumes nor produces packets.
  """
  @type boombox_mode :: :consuming | :producing | :standalone

  @typedoc """
  Serialized audio payload that can be present in a serialized packet.
  Consists of raw data along with audio specific metadata.
  """
  @type serialized_audio_payload :: %{
          data: binary(),
          sample_format: Membrane.RawAudio.SampleFormat.t(),
          sample_rate: pos_integer(),
          channels: pos_integer()
        }

  @typedoc """
  Serialized video payload that can be present in a serialized packet.
  Consists of raw data along with video specific metadata.
  """
  @type serialized_video_payload :: %{
          data: binary(),
          width: pos_integer(),
          height: pos_integer(),
          channels: pos_integer()
        }

  @typedoc """
  Serialized `t:Boombox.Packet.t/0`. Data in this form is sent by the server when demanded from
  and is expected by the server when it demands it.

  This serialization was designed to accomodate constraints set by
  [Pyrlang](https://github.com/Pyrlang/Pyrlang) and to enable interoperability with Python.

  ### Fields
    * `:payload` - record containing either video or audio data.
    * `:timestamp` - timestamp of the packet in milliseconds.
  """
  @type serialized_boombox_packet :: %{
          payload: {:audio, serialized_audio_payload()} | {:video, serialized_video_payload()},
          timestamp: integer()
        }

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            packet_serialization: boolean(),
            stop_application: boolean(),
            boombox_mode: Boombox.Server.boombox_mode() | nil,
            communication_medium: Boombox.Server.communication_medium(),
            parent_pid: pid(),
            membrane_sink: pid() | nil,
            membrane_source: pid() | nil,
            membrane_source_demands: %{audio: non_neg_integer(), video: non_neg_integer()},
            pipeline_supervisor: pid() | nil,
            pipeline: pid() | nil,
            current_client: GenServer.from() | Process.dest() | nil,
            pipeline_termination_reason: term(),
            termination_requested: boolean()
          }

    @enforce_keys [
      :packet_serialization,
      :stop_application,
      :communication_medium,
      :parent_pid
    ]

    defstruct @enforce_keys ++
                [
                  boombox_mode: nil,
                  membrane_sink: nil,
                  membrane_source: nil,
                  membrane_source_demands: %{audio: 0, video: 0},
                  pipeline_supervisor: nil,
                  pipeline: nil,
                  current_client: nil,
                  pipeline_termination_reason: nil,
                  termination_requested: false
                ]
  end

  @doc """
  Starts the server and links it to the current process, for more information see `GenServer.start_link/3`
  """
  @spec start_link(opts()) :: {:ok, t()} | {:error, {:already_started, t()}}
  def start_link(opts) do
    genserver_opts = Keyword.take(opts, [:name])
    opts = Keyword.put(opts, :parent_pid, self())
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Starts the server, for more information see `GenServer.start/3`
  """
  @spec start(opts()) :: {:ok, t()} | {:error, {:already_started, t()}}
  def start(opts) do
    genserver_opts = Keyword.take(opts, [:name])
    opts = Keyword.put(opts, :parent_pid, self())
    GenServer.start(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Runs Boombox with provided options and enables the usage of other functionalities for communicating
  with it. Availability of different functionalities depends on the mode (`t:boombox_mode/0`) in which
  Boombox is operating.

  All endpoints work the same way as in `Boombox.run/2` with the exception of `:wrtier` and
  `:reader` endpoints. When run with `:writer` input, Boombox will operate in `:consuming`
  mode, and when run with `:reader` output it will operate in `:procuding` mode.
  Otherwise, Boombox will operate in `:standalone` mode.
  """
  @spec run(t(), boombox_opts()) :: boombox_mode()
  def run(server, boombox_opts) do
    GenServer.call(server, {:run, boombox_opts})
  end

  @doc """
  Makes Boombox consume provided packet. Returns `:ok` if more packets can be provided, and
  `:finished` when Boombox finished consuming and will not accept any more packets. Returns
  synchronously once the packet has been processed by Boombox.
  Can be called only when Boombox is in `:consuming` mode.
  """
  @spec consume_packet(t(), serialized_boombox_packet() | Boombox.Packet.t()) ::
          :ok | :finished | {:error, :incompatible_mode}
  def consume_packet(server, packet) do
    GenServer.call(server, {:consume_packet, packet})
  end

  @doc """
  Informs Boombox that it will not be provided any more packets and should terminate
  accordingly.
  Can be called only when Boombox is in `:consuming` mode.
  """
  @spec finish_consuming(t()) :: :ok | {:error, :incompatible_mode | :already_finished}
  def finish_consuming(server) do
    if Process.alive?(server) do
      GenServer.call(server, :finish_consuming)
    else
      {:error, :already_finished}
    end
  end

  @doc """
  Requests a packet from Boombox. If returned with `:ok`, then this function can be called
  again to request the next packet, and if returned with `:finished`, then Boombox finished it's
  operation and will not produce any more packets.
  Can be called only when Boombox is in `:producing` mode.
  """
  @spec produce_packet(t()) ::
          {:ok, serialized_boombox_packet() | Boombox.Packet.t()}
          | :finished
          | {:error, :incompatible_mode}
  def produce_packet(server) do
    GenServer.call(server, :produce_packet)
  end

  @doc """
  Informs Boombox that no more packets will be read and shouldn't be produced.
  Can be called only when Boombox is in `:producing` mode.
  """
  @spec finish_producing(t()) :: :ok | {:error, :incompatible_mode | :already_finished}
  def finish_producing(server) do
    if Process.alive?(server) do
      GenServer.call(server, :finish_producing)
    else
      {:error, :already_finished}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %State{
       packet_serialization: Keyword.get(opts, :packet_serialization, false),
       stop_application: Keyword.get(opts, :stop_application, false),
       communication_medium: Keyword.get(opts, :communication_medium, :calls),
       parent_pid: Keyword.fetch!(opts, :parent_pid)
     }}
  end

  @impl true
  def handle_call(request, from, state) do
    handle_request(request, from, state)
  end

  # Imitating calls with messages
  @impl true
  def handle_info({:call, sender, request}, state) do
    case handle_request(request, sender, state) do
      {:reply, reply, state} ->
        reply(sender, reply)
        {:noreply, state}

      {:stop, reason, reply, state} ->
        reply(sender, reply)
        {:stop, reason, state}

      other ->
        other
    end
  end

  # Message API - writing packets
  @impl true
  def handle_info(
        {:boombox_packet, packet},
        %State{communication_medium: :messages, boombox_mode: :consuming} = state
      ) do
    packet =
      if state.packet_serialization,
        do: deserialize_packet(packet),
        else: packet

    send(state.membrane_source, {:boombox_packet, self(), packet})

    {:noreply, state}
  end

  # Message API - closing for writing
  @impl true
  def handle_info(
        :boombox_close,
        %State{communication_medium: :messages, boombox_mode: :consuming} = state
      ) do
    send(state.membrane_source, {:boombox_eos, self()})
    {:noreply, state}
  end

  @impl true
  def handle_info({boombox_elixir_element, pid}, %State{} = state)
      when boombox_elixir_element in [:boombox_elixir_source, :boombox_elixir_sink] do
    reply(state.current_client, state.boombox_mode)

    state = %State{state | current_client: nil}

    state =
      case boombox_elixir_element do
        :boombox_elixir_source -> %State{state | membrane_source: pid}
        :boombox_elixir_sink -> %State{state | membrane_sink: pid}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:boombox_demand, source, kind, value},
        %State{membrane_source: source} = state
      ) do
    %State{} = state = update_in(state.membrane_source_demands[kind], &(&1 + value))

    if state.current_client != nil and
         Enum.all?(state.membrane_source_demands, fn {_kind, value} -> value > 0 end) do
      reply(state.current_client, :ok)

      {:noreply, %State{state | current_client: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:boombox_packet, sink, packet},
        %State{membrane_sink: sink, communication_medium: :calls} = state
      ) do
    if state.current_client != nil do
      packet =
        if state.packet_serialization,
          do: serialize_packet(packet),
          else: packet

      reply(state.current_client, {:ok, packet})
      {:noreply, %State{state | current_client: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:boombox_packet, sink, packet},
        %State{membrane_sink: sink, communication_medium: :messages} = state
      ) do
    packet =
      if state.packet_serialization,
        do: serialize_packet(packet),
        else: packet

    send(state.parent_pid, {:boombox_packet, self(), packet})

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %State{pipeline_supervisor: pid} = state
      ) do
    reason =
      case reason do
        :normal -> :normal
        reason -> {:boombox_crash, reason}
      end

    case state.communication_medium do
      :calls ->
        cond do
          state.current_client != nil ->
            reply(state.current_client, :finished)
            {:stop, reason, state}

          state.termination_requested ->
            {:stop, reason, state}

          true ->
            {:noreply, %State{state | pipeline_termination_reason: reason}}
        end

      :messages ->
        send(state.parent_pid, {:boombox_finished, self()})
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info(info, state) do
    Logger.warning("Ignoring message #{inspect(info)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.stop_application do
      # Stop the application after the process terminates, allowing for the process to exit with the original
      # reason, not :shutdown coming from Application.
      pid = self()

      spawn(fn ->
        Process.monitor(pid)

        receive do
          {:DOWN, _ref, :process, ^pid, ^reason} ->
            Application.stop(:boombox)
        end
      end)
    end
  end

  @spec handle_request({:run, boombox_opts()}, GenServer.from() | Process.dest(), State.t()) ::
          {:noreply, State.t()}
  defp handle_request({:run, boombox_opts}, from, %State{} = state) do
    boombox_mode = get_boombox_mode(boombox_opts)

    %{supervisor: pipeline_supervisor, pipeline: pipeline} =
      boombox_opts
      |> Map.new()
      |> Boombox.Pipeline.start_link()

    {:noreply,
     %State{
       state
       | boombox_mode: boombox_mode,
         pipeline_supervisor: pipeline_supervisor,
         pipeline: pipeline,
         current_client: from
     }}
  end

  @spec handle_request(:get_pid, GenServer.from() | Process.dest(), State.t()) ::
          {:reply, pid(), State.t()}
  defp handle_request(:get_pid, _from, state) do
    {:reply, self(), state}
  end

  defp handle_request(_request, _from, %State{pipeline: nil} = state) do
    {:reply, {:error, :boombox_not_running}, state}
  end

  @spec handle_request(
          {:consume_packet, serialized_boombox_packet() | Boombox.Packet.t()},
          GenServer.from() | Process.dest(),
          State.t()
        ) ::
          {:reply, :ok | {:error, :incompatible_mode | :boombox_not_running}, State.t()}
          | {:noreply, State.t()}
          | {:stop, term(), :finished, State.t()}
  defp handle_request(
         {:consume_packet, packet},
         from,
         %State{boombox_mode: :consuming} = state
       ) do
    packet =
      if state.packet_serialization,
        do: deserialize_packet(packet),
        else: packet

    send(state.membrane_source, {:boombox_packet, self(), packet})
    %State{} = state = update_in(state.membrane_source_demands[packet.kind], &(&1 - 1))

    cond do
      state.pipeline_termination_reason != nil ->
        {:stop, state.pipeline_termination_reason, :finished, state}

      state.membrane_source_demands[packet.kind] == 0 ->
        {:noreply, %State{state | current_client: from}}

      true ->
        {:reply, :ok, state}
    end
  end

  defp handle_request(
         {:consume_packet, _packet},
         _from,
         %State{boombox_mode: _other_mode} = state
       ) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(:finish_consuming, GenServer.from() | Process.dest(), State.t()) ::
          {:reply, :ok | {:error, :incompatible_mode}, State.t()}
          | {:stop, term(), :ok, State.t()}
  defp handle_request(:finish_consuming, _from, %State{boombox_mode: :consuming} = state) do
    if state.pipeline_termination_reason != nil do
      {:stop, state.pipeline_termination_reason, :ok, state}
    else
      send(state.membrane_source, {:boombox_eos, self()})
      {:reply, :ok, %State{state | termination_requested: true}}
    end
  end

  defp handle_request(:finish_consuming, _from, %State{boombox_mode: _other_mode} = state) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(:produce_packet, GenServer.from() | Process.dest(), State.t()) ::
          {:reply, {:error, :incompatible_mode | :boombox_not_running}, State.t()}
          | {:noreply, State.t()}
          | {:stop, term(), :finished, State.t()}
  defp handle_request(:produce_packet, from, %State{boombox_mode: :producing} = state) do
    if state.pipeline_termination_reason != nil do
      {:stop, state.pipeline_termination_reason, :finished, state}
    else
      send(state.membrane_sink, {:boombox_demand, self()})
      {:noreply, %State{state | current_client: from}}
    end
  end

  defp handle_request(:produce_packet, _from, %State{boombox_mode: _other_mode} = state) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(:finish_producing, GenServer.from() | Process.dest(), State.t()) ::
          {:reply, :ok | {:error, :incompatible_mode}, State.t()}
  defp handle_request(:finish_producing, _from, %State{boombox_mode: :producing} = state) do
    if state.pipeline_termination_reason != nil do
      {:stop, state.pipeline_termination_reason, :ok, state}
    else
      Membrane.Pipeline.terminate(state.pipeline, asynchronous?: true)
      {:reply, :ok, %State{state | termination_requested: true}}
    end
  end

  defp handle_request(:finish_producing, _from, %State{boombox_mode: _other_mode} = state) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(term(), GenServer.from() | Process.dest(), State.t()) ::
          {:reply, {:error, :invalid_request}, State.t()}
  defp handle_request(_invalid_request, _from, state) do
    {:reply, {:error, :invalid_request}, state}
  end

  @spec reply(GenServer.from() | Process.dest(), term()) :: :ok
  defp reply(dest, reply_content) when is_pid(dest) or is_port(dest) or is_atom(dest) do
    send(dest, {:response, reply_content})
  end

  defp reply({name, node} = dest, reply_content) when is_atom(name) and is_atom(node) do
    send(dest, {:response, reply_content})
  end

  defp reply({pid, _tag} = genserver_from, reply_content) when is_pid(pid) do
    GenServer.reply(genserver_from, reply_content)
  end

  @spec get_boombox_mode(boombox_opts()) :: boombox_mode()
  defp get_boombox_mode(boombox_opts) do
    cond do
      elixir_endpoint?(boombox_opts[:input]) and elixir_endpoint?(boombox_opts[:output]) ->
        raise ArgumentError, "Using an elixir endpoint on both input and output is not supported"

      elixir_endpoint?(boombox_opts[:input]) ->
        :consuming

      elixir_endpoint?(boombox_opts[:output]) ->
        :producing

      true ->
        :standalone
    end
  end

  defp elixir_endpoint?({type, _opts}) when type in [:stream, :reader, :writer, :message],
    do: true

  defp elixir_endpoint?(_io), do: false

  @spec deserialize_packet(serialized_boombox_packet()) :: Packet.t()
  defp deserialize_packet(%{payload: {:audio, payload}} = serialized_packet) do
    %Boombox.Packet{
      kind: :audio,
      payload: payload.data,
      pts: Membrane.Time.milliseconds(serialized_packet.timestamp),
      format: %{
        audio_format: payload.sample_format,
        audio_rate: payload.sample_rate,
        audio_channels: payload.channels
      }
    }
  end

  defp deserialize_packet(%{payload: {:video, payload}} = serialized_packet) do
    {:ok, img} =
      Vix.Vips.Image.new_from_binary(
        payload.data,
        payload.width,
        payload.height,
        payload.channels,
        :VIPS_FORMAT_UCHAR
      )

    %Boombox.Packet{
      kind: :video,
      payload: img,
      pts: Membrane.Time.milliseconds(serialized_packet.timestamp)
    }
  end

  @spec serialize_packet(Packet.t()) :: serialized_boombox_packet()
  defp serialize_packet(%Packet{kind: :audio} = packet) do
    serialized_payload =
      {:audio,
       %{
         data: packet.payload,
         sample_format: packet.format.audio_format,
         sample_rate: packet.format.audio_rate,
         channels: packet.format.audio_channels
       }}

    %{
      payload: serialized_payload,
      timestamp: Membrane.Time.as_milliseconds(packet.pts, :round)
    }
  end

  defp serialize_packet(%Packet{kind: :video} = packet) do
    {:ok, tensor} = Vix.Vips.Image.write_to_tensor(packet.payload)
    {height, width, channels} = tensor.shape

    serialized_payload =
      {:video,
       %{
         data: tensor.data,
         width: width,
         height: height,
         channels: channels
       }}

    %{
      payload: serialized_payload,
      timestamp: Membrane.Time.as_milliseconds(packet.pts, :round)
    }
  end
end
