![boombox_transparent](https://github.com/user-attachments/assets/1c5f25a2-cc27-4349-ae72-91315d43d6a1)

[![Hex.pm](https://img.shields.io/hexpm/v/boombox.svg)](https://hex.pm/packages/boombox)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/boombox)
[![CircleCI](https://circleci.com/gh/membraneframework/boombox.svg?style=svg)](https://circleci.com/gh/membraneframework/boombox)

Boombox is a high-level tool for audio & video streaming based on [Membrane Framework](https://membrane.stream).
It's built for easy transformations between any popular media formats -
containers and streaming protocols alike.

You can also use it as a bridge between Elixir and external media, allowing for seamless
integration with AI pipelines and other projects that interact with raw media streams
directly.

See [examples.livemd](examples.livemd) for examples.

We also maintain a Python package `boomboxlib` that allows for using Boombox in
Python projects directly. For more details see the [python directory](https://github.com/membraneframework/boombox/tree/master/python).

## Usage

The code below receives a stream via RTMP and sends it over HLS:

```elixir
Boombox.run(input: "rtmp://localhost:5432", output: "index.m3u8")
```

The analogous code in Python:

```python
boombox(input="rtmp://localhost:5432", output="index.m3u8")
```

You can use CLI interface too:

```bash
boombox -i "rtmp://localhost:5432" -o "index.m3u8"
```

The code below generates a video with bouncing Membrane logo and sends it over WebRTC:

```elixir
Mix.install([:boombox, :req, :image])

overlay =
  Req.get!("https://avatars.githubusercontent.com/u/25247695?s=200&v=4").body
  |> Vix.Vips.Image.new_from_buffer()
  |> then(fn {:ok, img} -> img end)
  |> Image.trim!()
  |> Image.thumbnail!(100)

bg = Image.new!(640, 480, color: :light_gray)
max_x = Image.width(bg) - Image.width(overlay)
max_y = Image.height(bg) - Image.height(overlay)

Stream.iterate({_x = 300, _y = 0, _dx = 1, _dy = 2, _pts = 0}, fn {x, y, dx, dy, pts} ->
  dx = if (x + dx) in 0..max_x, do: dx, else: -dx
  dy = if (y + dy) in 0..max_y, do: dy, else: -dy
  pts = pts + div(Membrane.Time.seconds(1), _fps = 60)
  {x + dx, y + dy, dx, dy, pts}
end)
|> Stream.map(fn {x, y, _dx, _dy, pts} ->
  img = Image.compose!(bg, overlay, x: x, y: y)
  %Boombox.Packet{kind: :video, payload: img, pts: pts}
end)
|> Boombox.run(
  input: {:stream, video: :image, audio: false},
  output: {:webrtc, "ws://localhost:8830"}
)
```

To receive WebRTC/HLS from boombox in a browser or send WebRTC from a browser to boombox
you can use simple HTML examples in the `boombox_examples_data` folder, for example

```sh
wget https://raw.githubusercontent.com/membraneframework/boombox/v0.1.0/boombox_examples_data/webrtc_to_browser.html
open webrtc_to_browser.html
```

For more examples, see [examples.livemd](examples.livemd).

## Supported formats & protocols

| format | input | output |
|---|---|---|
| MP4 | `"*.mp4"` | `"*.mp4"` |
| MP3 | `"*.mp3"` | `"*.mp3"` |
| AAC | `"*.aac"` | `"*.aac"` |
| Ogg | `"*.ogg"` | `"*.ogg"` |
| H264 | `"*.h264"` | `"*.h264"` |
| H265 | `"*.h265"` | `"*.h265"` |
| WAV | `"*.wav"` | `"*.wav"` |
| IVF | `"*.ivf"` | `"*.ivf"` |
| WebRTC | `{:webrtc, signaling}` | `{:webrtc, signaling}` |
| WHIP | `{:whip, "http://*", token: "token"}` | `{:whip, "http://*", token: "token"}` |
| RTMP | `"rtmp://*"` | _not supported_ |
| RTSP | `"rtsp://*"` | _not supported_ |
| RTP | `{:rtp, opts}` | `{:rtp, opts}` |
| HLS | `"*.m3u8"` | `"*.m3u8"` |
| SRT | `"srt://<ip>:<port>"` | `"srt://<ip>:<port>"` |
| `Enumerable.t()` | `{:stream, opts}` | `{:stream, opts}` |
| function calls | `{:reader, opts}` | `{:writer, opts}` |
| messages | `{:message, opts}` | `{:message, opts}` |
| media player | _not relevant_ | `:player` |

For the full list of input and output options, see [`Boombox.run/2`](https://hexdocs.pm/boombox/Boombox.html#run/2)

## Installation

To use Boombox as an Elixir library, add

```elixir
{:boombox, "~> 0.2.10"}
```

to your dependencies or `Mix.install`.

to use via CLI, run the following:

```sh
wget https://raw.githubusercontent.com/membraneframework/boombox/v0.1.0/bin/boombox
chmod u+x boombox
./boombox
```

Make sure you have [Elixir](https://elixir-lang.org/) installed. The first call to `boombox` will install it in a default directory in the system. The directory can be set with `MIX_INSTALL_DIR` env variable if preferred.

## CLI

The CLI API is a direct mapping of the Elixir API:

* `:input` and `:output` options of `Boombox.run/2` are mapped to `-i` and `-o` CLI arguments respectively.
* Option names, like `:some_option`, are mapped to CLI arguments by removing the colon, adding a leading double hyphen and replacing all underscores with hyphens, like `--some-option`.
* Option values mappings depend on the option's type:
  * String values, like `"some_value"`, are mapped to CLI arguments by stripping the quotes, like `some_value`.
  * Atom values, like `:some_value`, are mapped to CLI arguments by stripping the leading colon, like `some_value`.
  * Integer values are identical in elixir and CLI.
  * Binary values, like `<<161, 63>>`, are represented in CLI as their representation in base 16, like `a13f`.

For example:

```elixir
Boombox.run(input: "file.mp4", output: {:whip, "http://localhost:3721", token: "token"})
Boombox.run(
  input:
    {:rtp,
     port: 50001,
     audio_encoding: :AAC,
     audio_specific_config: <<161, 63>>,
     aac_bitrate_mode: :hbr},
  output: "index.m3u8"
)
```

are equivalent to:

```sh
./boombox -i file.mp4 -o --whip http://localhost:3721 --token token
./boombox -i --rtp --port 50001 --audio-encoding AAC --audio-specific-config a13f --aac-bitrate-mode hbr -o index.m3u8
```

It's also possible to pass an `.exs` script:

```sh
./boombox -s script.exs
```

In the script you can call `Boombox.run(...)` and execute other Elixir code.

The first run of the CLI may take longer than usual, as the necessary artifacts are installed in the system.

## Authors

Boombox is created by Software Mansion.

Since 2012 [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox) is a software agency with experience in building web and mobile apps as well as complex multimedia solutions. We are Core React Native Contributors and experts in live streaming and broadcasting technologies. We can help you build your next dream product – [Hire us](https://swmansion.com/contact/projects).

Copyright 2024, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

Licensed under the [Apache License, Version 2.0](LICENSE)
