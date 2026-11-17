defmodule ServiceRadar.Camera.StreamAddressReductionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.StreamAddressReduction

  # Invented addresses only: documentation IP ranges, example.com hosts, made-up
  # aliases and credentials.
  @origin "rtsps://192.0.2.10:7441"

  @strings [
    {"an origin stays", @origin, @origin},
    {"an rtsps path becomes the origin", "rtsps://192.0.2.10:7441/AbCdEf", @origin},
    {"rtsp userinfo and path go", "rtsp://viewer:secret@cam01.example.com/live",
     "rtsp://cam01.example.com"},
    {"the scheme's letter case is kept", "RTSPS://192.0.2.10:7441/AbCdEf",
     "RTSPS://192.0.2.10:7441"},
    {"an ipv6 host keeps its port", "rtsp://[2001:db8::1]:554/stream",
     "rtsp://[2001:db8::1]:554"},
    {"https userinfo goes and the path stays", "https://viewer:secret@files.example.com/a?b=1",
     "https://files.example.com/a?b=1"},
    {"https without userinfo stays", "https://files.example.com/a?b=1",
     "https://files.example.com/a?b=1"},
    {"an address inside text is reduced", "dial rtsps://192.0.2.10:7441/AbCdEf failed",
     "dial rtsps://192.0.2.10:7441 failed"},
    {"escaped solidus is detected and written unescaped", "rtsps:\\/\\/192.0.2.10:7441\\/AbCdEf",
     @origin},
    {"unicode escapes in any case are detected",
     "rtsps:\\u002f\\u002F192.0.2.10:7441\\u002fAbCdEf", @origin},
    {"an escaped at-sign is userinfo", "https:\\/\\/viewer:pw\\u0040files.example.com\\/x",
     "https://files.example.com/x"},
    {"an escaped origin alone is not rewritten", "rtsps:\\/\\/192.0.2.10:7441",
     "rtsps:\\/\\/192.0.2.10:7441"},
    {"text without an address stays", "camera 01: connected", "camera 01: connected"},
    {"bytes that are not UTF-8 stay", <<0xFF, 0xFE, ?:>>, <<0xFF, 0xFE, ?:>>}
  ]

  test "reduces addresses in strings" do
    for {name, input, expected} <- @strings do
      assert StreamAddressReduction.reduce(input) == expected, name
    end
  end

  test "removes alias keys in any letter case at any depth, keeping other keys" do
    payload = %{
      "rtsp_alias" => "AbCdEf",
      "RTSPS_ALIAS" => "AbCdEf",
      :rtspAlias => "AbCdEf",
      "keep" => [%{"rtspsAlias" => "AbCdEf", "width" => 1920}]
    }

    assert StreamAddressReduction.reduce(payload) == %{"keep" => [%{"width" => 1920}]}
  end

  test "reduces inside JSON-encoded strings and re-encodes only what changed" do
    inner = Jason.encode!(%{"url" => "rtsps://192.0.2.10:7441/AbCdEf", "rtspsAlias" => "AbCdEf"})
    double = Jason.encode!(inner)
    clean = Jason.encode!(%{"url" => @origin, "fps" => 30})

    reduced = StreamAddressReduction.reduce(%{"double" => double, "clean" => clean})

    assert reduced["clean"] == clean
    assert reduced["double"] |> Jason.decode!() |> Jason.decode!() == %{"url" => @origin}
  end

  test "a value still JSON-encoded past four decodes becomes the marker; four decodes do not" do
    encode = fn value, times ->
      Enum.reduce(1..times, value, fn _, acc -> Jason.encode!(acc) end)
    end

    deep = encode.(%{"fps" => 30}, 5)
    within = encode.(%{"url" => "rtsps://192.0.2.10:7441/AbCdEf"}, 4)

    reduced = StreamAddressReduction.reduce(%{"deep" => deep, "within" => within})

    assert Enum.reduce(1..4, reduced["deep"], fn _, acc -> Jason.decode!(acc) end) ==
             StreamAddressReduction.depth_marker()

    assert Enum.reduce(1..4, reduced["within"], fn _, acc -> Jason.decode!(acc) end) ==
             %{"url" => @origin}
  end

  test "origin/1 keeps only scheme, host and port of any URL, and nothing of other values" do
    for {input, expected} <- [
          {@origin, @origin},
          {"rtsps://192.0.2.10:7441/AbCdEf", @origin},
          {" rtsp://viewer:secret@cam01.example.com/live?x=1 ", "rtsp://cam01.example.com"},
          {"https://viewer:secret@files.example.com:8443/a?b=1#c",
           "https://files.example.com:8443"},
          {"rtsps:\\/\\/192.0.2.10:7441\\/AbCdEf", @origin},
          {"rtsp://[2001:db8::1]:554/stream", "rtsp://[2001:db8::1]:554"},
          {"dial rtsps://192.0.2.10:7441/AbCdEf failed", nil},
          {"rtsps://", nil},
          {"camera 01", nil},
          {"", nil},
          {nil, nil},
          {42, nil}
        ] do
      assert StreamAddressReduction.origin(input) == expected, inspect(input)
    end
  end

  test "a reduced value is a fixed point, and structs are left alone" do
    observed_at = ~U[2026-01-01 00:00:00Z]

    inputs =
      Enum.map(@strings, &elem(&1, 1)) ++
        [
          %{"at" => observed_at, "u" => "rtsps://192.0.2.10:7441/AbCdEf"},
          Jason.encode!(Jason.encode!(Jason.encode!(Jason.encode!(Jason.encode!("x")))))
        ]

    for input <- inputs do
      reduced = StreamAddressReduction.reduce(input)
      assert StreamAddressReduction.reduce(reduced) == reduced
    end

    assert %{"at" => ^observed_at} = StreamAddressReduction.reduce(%{"at" => observed_at})
  end
end
