defmodule Boombox.InternalBin.RTP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Boombox.InternalBin.Ready
  alias Membrane.RTP

  @supported_encodings [audio: [:AAC, :Opus], video: [:H264, :H265]]

  @encoding_specific_params_specs %{
    input: %{
      AAC: [aac_bitrate_mode: [require?: true], audio_specific_config: [require?: true]],
      H264: [pps: [require?: false, default: nil], sps: [require?: false, default: nil]],
      H265: [
        vps: [require?: false, default: nil],
        pps: [require?: false, default: nil],
        sps: [require?: false, default: nil]
      ]
    },
    output: %{
      AAC: [aac_bitrate_mode: [require?: true]]
    }
  }

  @type parsed_input_encoding_specific_params ::
          %{aac_bitrate_mode: RTP.AAC.Utils.mode(), audio_specific_config: binary()}
          | %{vps: binary() | nil, pps: binary() | nil, sps: binary() | nil}
          | %{pps: binary() | nil, sps: binary() | nil}
          | %{}

  @type parsed_output_encoding_specific_params ::
          %{aac_bitrate_mode: RTP.AAC.Utils.mode()}
          | %{}

  @type parsed_input_track_config :: %{
          encoding_name: RTP.encoding_name(),
          encoding_specific_params: parsed_input_encoding_specific_params(),
          payload_type: RTP.payload_type(),
          clock_rate: RTP.clock_rate()
        }

  @type parsed_output_track_config :: %{
          encoding_name: RTP.encoding_name(),
          encoding_specific_params: parsed_output_encoding_specific_params(),
          payload_type: RTP.payload_type(),
          clock_rate: RTP.clock_rate()
        }

  @type parsed_in_opts :: %{
          port: :inet.port_number(),
          track_configs: %{
            optional(:audio) => parsed_input_track_config(),
            optional(:video) => parsed_input_track_config()
          }
        }

  @type parsed_out_opts :: %{
          address: :inet.ip_address(),
          port: :inet.port_number(),
          track_configs: %{
            optional(:audio) => parsed_output_track_config(),
            optional(:video) => parsed_output_track_config()
          },
          transcoding_policy: :always | :if_needed | :never
        }

  @type parsed_track_config :: parsed_input_track_config() | parsed_output_track_config()

  @spec create_input(Boombox.in_rtp_opts()) :: Ready.t()
  def create_input(opts) do
    parsed_options = validate_and_parse_options(:input, opts)
    payload_type_mapping = get_payload_type_mapping(parsed_options.track_configs)

    spec =
      child(:udp_source, %Membrane.UDP.Source{local_port_no: opts[:port]})
      |> child(:rtp_demuxer, %Membrane.RTP.Demuxer{payload_type_mapping: payload_type_mapping})

    track_builders =
      Map.new(parsed_options.track_configs, fn {media_type, track_config} ->
        {depayloader, parser} =
          case track_config.encoding_name do
            :H264 ->
              ppss = List.wrap(track_config.encoding_specific_params.pps)
              spss = List.wrap(track_config.encoding_specific_params.sps)
              {Membrane.RTP.H264.Depayloader, %Membrane.H264.Parser{ppss: ppss, spss: spss}}

            :AAC ->
              audio_specific_config = track_config.encoding_specific_params.audio_specific_config
              bitrate_mode = track_config.encoding_specific_params.aac_bitrate_mode

              {%Membrane.RTP.AAC.Depayloader{mode: bitrate_mode},
               %Membrane.AAC.Parser{audio_specific_config: audio_specific_config}}

            :OPUS ->
              {Membrane.RTP.Opus.Depayloader, Membrane.Opus.Parser}

            :H265 ->
              vpss = List.wrap(track_config.encoding_specific_params.vps)
              ppss = List.wrap(track_config.encoding_specific_params.pps)
              spss = List.wrap(track_config.encoding_specific_params.sps)

              {Membrane.RTP.H265.Depayloader,
               %Membrane.H265.Parser{vpss: vpss, ppss: ppss, spss: spss}}
          end

        spec =
          get_child(:rtp_demuxer)
          |> via_out(:output, options: [stream_id: {:encoding_name, track_config.encoding_name}])
          |> child({:jitter_buffer, media_type}, %Membrane.RTP.JitterBuffer{
            clock_rate: track_config.clock_rate
          })
          |> child({:rtp_depayloader, media_type}, depayloader)
          |> child({:rtp_in_parser, media_type}, parser)

        {media_type, spec}
      end)

    %Ready{spec_builder: spec, track_builders: track_builders}
  end

  @spec link_output(
          Boombox.out_rtp_opts(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          boolean()
        ) :: Ready.t()
  def link_output(opts, track_builders, spec_builder, is_input_realtime) do
    opts = validate_and_parse_options(:output, opts)

    spec = [
      spec_builder,
      child(:rtp_muxer, Membrane.RTP.Muxer)
      |> child(:udp_rtp_sink, %Membrane.UDP.Sink{
        destination_address: opts.address,
        destination_port_no: opts.port
      }),
      Enum.map(track_builders, fn {media_type, builder} ->
        track_config = opts.track_configs[media_type]

        {output_stream_format, parser, payloader} =
          case track_config.encoding_name do
            :H264 ->
              {%Membrane.H264{stream_structure: :annexb, alignment: :nalu},
               %Membrane.H264.Parser{output_stream_structure: :annexb, output_alignment: :nalu},
               Membrane.RTP.H264.Payloader}

            :AAC ->
              {%Membrane.AAC{encapsulation: :none},
               %Membrane.AAC.Parser{out_encapsulation: :none},
               %Membrane.RTP.AAC.Payloader{
                 mode: track_config.encoding_specific_params.aac_bitrate_mode,
                 frames_per_packet: 1
               }}

            :OPUS ->
              {Membrane.Opus, %Membrane.Opus.Parser{delimitation: :undelimit},
               Membrane.RTP.Opus.Payloader}

            :H265 ->
              {%Membrane.H265{stream_structure: :annexb, alignment: :nalu},
               %Membrane.H265.Parser{output_stream_structure: :annexb, output_alignment: :nalu},
               Membrane.RTP.H265.Payloader}
          end

        builder
        |> child({:rtp_transcoder, media_type}, %Membrane.Transcoder{
          output_stream_format: output_stream_format,
          transcoding_policy: opts.transcoding_policy
        })
        |> child({:rtp_out_parser, media_type}, parser)
        |> child({:rtp_payloader, media_type}, payloader)
        |> then(
          &if is_input_realtime,
            do: &1,
            else: child(&1, {:realtimer, media_type}, Membrane.Realtimer)
        )
        |> via_in(:input,
          options: [
            encoding: track_config.encoding_name,
            payload_type: track_config.payload_type,
            clock_rate: track_config.clock_rate
          ]
        )
        |> get_child(:rtp_muxer)
      end)
    ]

    %Ready{actions: [spec: spec]}
  end

  @spec validate_and_parse_options(:input, Boombox.in_rtp_opts()) :: parsed_in_opts()
  @spec validate_and_parse_options(:output, Boombox.out_rtp_opts()) :: parsed_out_opts()
  defp validate_and_parse_options(direction, opts) do
    transport_opts =
      case direction do
        :input ->
          if Keyword.has_key?(opts, :port) do
            %{port: opts[:port]}
          else
            raise "Receiving port not specified in RTP options"
          end

        :output ->
          parse_output_target(opts)
      end

    parsed_track_configs =
      [:audio, :video]
      |> Enum.filter(fn
        :video -> opts[:video_encoding] != nil
        :audio -> opts[:audio_encoding] != nil
      end)
      |> Map.new(fn media_type ->
        {media_type, validate_and_parse_track_config(direction, media_type, opts)}
      end)

    if parsed_track_configs == %{} do
      raise "No RTP media configured"
    end

    parsed_opts = transport_opts |> Map.put(:track_configs, parsed_track_configs)

    case direction do
      :input ->
        parsed_opts

      :output ->
        parsed_opts
        |> Map.put(:transcoding_policy, Keyword.get(opts, :transcoding_policy, :if_needed))
    end
  end

  @spec parse_output_target(
          target: String.t(),
          address: :inet.ip4_address() | String.t(),
          port: :inet.port_number()
        ) :: %{address: :inet.ip4_address(), port: :inet.port_number()}
  defp parse_output_target(opts) do
    case Map.new(opts) do
      %{target: target} ->
        [address_string, port_string] = String.split(target, ":")
        {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(address_string))
        %{address: address, port: String.to_integer(port_string)}

      %{address: address, port: port} when is_binary(address) ->
        {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(address))
        %{address: address, port: port}

      %{address: address, port: port} when is_tuple(address) ->
        %{address: address, port: port}

      _invalid_target ->
        raise "RTP output target address and port not specified"
    end
  end

  @spec validate_and_parse_track_config(:input, :video | :audio, Boombox.in_rtp_opts()) ::
          parsed_input_track_config()
  @spec validate_and_parse_track_config(:output, :video | :audio, Boombox.out_rtp_opts()) ::
          parsed_output_track_config()
  defp validate_and_parse_track_config(direction, media_type, opts) do
    {encoding_name, payload_type, clock_rate} =
      case media_type do
        :audio -> {opts[:audio_encoding], opts[:audio_payload_type], opts[:audio_clock_rate]}
        :video -> {opts[:video_encoding], opts[:video_payload_type], opts[:video_clock_rate]}
      end

    if encoding_name not in @supported_encodings[media_type] do
      raise "Encoding #{inspect(encoding_name)} for #{inspect(media_type)} media type not supported"
    end

    %{
      payload_format: %RTP.PayloadFormat{encoding_name: encoding_name},
      payload_type: payload_type,
      clock_rate: clock_rate
    } =
      RTP.PayloadFormat.resolve(
        encoding_name: encoding_name,
        payload_type: payload_type,
        clock_rate: clock_rate
      )

    if payload_type == nil do
      raise "payload_type for encoding #{inspect(encoding_name)} not provided with no default value registered"
    end

    if clock_rate == nil do
      raise "clock_rate for encoding #{inspect(encoding_name)} and payload_type #{inspect(payload_type)} not provided with no default value registered"
    end

    encoding_specific_params_specs =
      Map.get(@encoding_specific_params_specs[direction], encoding_name, [])

    {:ok, encoding_specific_params} =
      Keyword.intersect(encoding_specific_params_specs, opts)
      |> Bunch.Config.parse(encoding_specific_params_specs)

    %{
      encoding_name: encoding_name,
      encoding_specific_params: encoding_specific_params,
      payload_type: payload_type,
      clock_rate: clock_rate
    }
  end

  @spec get_payload_type_mapping(%{audio: parsed_track_config(), video: parsed_track_config()}) ::
          RTP.PayloadFormat.payload_type_mapping()
  defp get_payload_type_mapping(track_configs) do
    Map.new(track_configs, fn {_media_type, track_config} ->
      {track_config.payload_type,
       %{encoding_name: track_config.encoding_name, clock_rate: track_config.clock_rate}}
    end)
  end
end
