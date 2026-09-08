defmodule Boombox.Utils.CLI do
  @moduledoc false

  # first element of the tuple is switch type, and the second is the elixir type
  @arg_types [
    mp4: {:string, :string},
    webrtc: {:string, :string},
    rtmp: {:string, :string},
    hls: {:string, :string},
    transport: {:string, :string},
    rtp: {:boolean, nil},
    port: {:integer, :integer},
    address: {:string, :string},
    target: {:string, :string},
    video_encoding: {:string, :atom},
    video_payload_type: {:integer, :integer},
    video_clock_rate: {:integer, :integer},
    audio_encoding: {:string, :atom},
    audio_payload_type: {:integer, :integer},
    audio_clock_rate: {:integer, :integer},
    aac_bitrate_mode: {:string, :atom},
    audio_specific_config: {:string, :binary},
    pps: {:string, :binary},
    sps: {:string, :binary},
    vps: {:string, :binary},
    whip: {:string, :string},
    token: {:string, :string},
    transcoding_policy: {:string, :atom},
    pace_control: {:boolean, :boolean},
    is_live: {:boolean, :boolean},
    variant_selection_policy: {:string, :atom},
    mode: {:string, :atom}
  ]

  @spec parse_argv([String.t()]) ::
          {:args, input: Boombox.input(), output: Boombox.output()} | {:script, String.t()}
  def parse_argv(argv) do
    OptionParser.parse(argv, strict: [script: :string], aliases: [s: :script, S: :script])
    |> case do
      {[], _argv, _switches} ->
        {:args, parse_args(argv)}

      result ->
        [script: script] = handle_option_parser_result(result)
        {:script, script}
    end
  end

  defp parse_args(argv) do
    aliases = [i: :input, o: :output]
    i_type = [get_switch_type(argv, :input, aliases), :keep]
    o_type = [get_switch_type(argv, :output, aliases), :keep]

    switches =
      [input: i_type, output: o_type] ++
        Keyword.new(@arg_types, fn {key, {switch_type, _elixir_type}} ->
          {key, [switch_type, :keep]}
        end)

    {input, output} =
      OptionParser.parse(argv, strict: switches, aliases: aliases)
      |> handle_option_parser_result()
      |> case do
        [input: _value] ++ _rest = parsed ->
          Enum.split_while(parsed, fn {k, _v} -> k != :output end)

        [output: _value] ++ _rest = parsed ->
          Enum.split_while(parsed, fn {k, _v} -> k != :input end)

        _other ->
          cli_exit_error()
      end

    [resolve_endpoint(input), resolve_endpoint(output)]
  end

  @spec get_switch_type([String.t()], atom(), Keyword.t()) :: :boolean | :string
  defp get_switch_type(argv, option, aliases) do
    with [] <- OptionParser.parse(argv, strict: [{option, :string}], aliases: aliases) |> elem(0),
         [] <- OptionParser.parse(argv, strict: [{option, :boolean}], aliases: aliases) |> elem(0) do
      cli_exit_error("#{option} not provided")
    else
      [{^option, true}] -> :boolean
      [{^option, string}] when is_binary(string) -> :string
    end
  end

  @spec resolve_endpoint(Keyword.t()) :: {:input, Boombox.input()} | {:output, Boombox.output()}
  defp resolve_endpoint(parsed) do
    case parsed do
      [{direction, true}, {endpoint, true}] ->
        {direction, endpoint}

      [{direction, true}, {endpoint, value}] ->
        {direction, {endpoint, value}}

      [{direction, true}, {endpoint, true} | opts] ->
        {direction, {endpoint, translate_opts(opts)}}

      [{direction, true}, {endpoint, value} | opts] ->
        {direction, {endpoint, value, translate_opts(opts)}}

      [{direction, value}] ->
        {direction, value}

      [{direction, value} | opts] ->
        {direction, {value, translate_opts(opts)}}

      _other ->
        cli_exit_error()
    end
  end

  @spec handle_option_parser_result({Keyword.t(), [String.t()], Keyword.t()}) :: Keyword.t()
  defp handle_option_parser_result(result) do
    case result do
      {parsed, [], []} -> parsed
      {_parsed, _argv, [{s, _v} | _switches]} -> cli_exit_error("unexpected option '#{s}'")
      {_parsed, [arg | _argv], []} -> cli_exit_error("unexpected value '#{arg}'")
    end
  end

  @spec translate_opts(Keyword.t()) :: Keyword.t()
  defp translate_opts(opts) do
    Keyword.new(opts, fn {opt, value} ->
      case @arg_types[opt] do
        {:string, :atom} -> {opt, String.to_atom(value)}
        {:string, :binary} -> {opt, decode_binary_opt(value)}
        {type, type} -> {opt, value}
      end
    end)
  end

  @spec decode_binary_opt(String.t()) :: binary()
  defp decode_binary_opt(opt_value) do
    case Base.decode16(opt_value, case: :mixed) do
      {:ok, value} -> value
      :error -> cli_exit_error("bad base16 string '#{inspect(opt_value)}'")
    end
  end

  @spec cli_exit_error() :: no_return
  @spec cli_exit_error(String.t() | nil) :: no_return
  defp cli_exit_error(description \\ nil) do
    description = if description, do: "Error: #{description}\n\n"

    IO.puts("""
    #{description}\
    Usage: boombox -i [input] -o [output]

    Examples:

    boombox -i rtmp://localhost:5432 -o output/index.m3u8
    boombox -i --webrtc ws://localhost:8829 -o file.mp4
    """)

    System.halt(1)
  end
end
