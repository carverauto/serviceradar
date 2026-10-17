defmodule ServiceRadarCoreElx.CameraRelay.TurnPaddedChannelDataTest do
  # The camera WebRTC peer reaches a browser through a TURN relay pair, and
  # eturnal pads every ChannelData message to four bytes. A payload whose
  # length is not a multiple of four (the tail of a fragmented DTLS
  # ClientHello) must still reach ICE, or the DTLS handshake never starts.
  # ex_turn is pinned to carverauto/ex_turn for this (elixir-webrtc/ex_turn#12);
  # the test guards against a bump back to an unfixed release.
  use ExUnit.Case, async: true

  alias ExSTUN.Message
  alias ExSTUN.Message.Attribute.ErrorCode
  alias ExSTUN.Message.Attribute.Nonce
  alias ExSTUN.Message.Attribute.Realm
  alias ExSTUN.Message.Attribute.Username
  alias ExSTUN.Message.Attribute.XORMappedAddress
  alias ExSTUN.Message.Type
  alias ExTURN.Attribute.Lifetime
  alias ExTURN.Attribute.XORRelayedAddress
  alias ExTURN.Client

  @username "1700000000:viewer"
  @password "turn-secret"
  @realm "turn.example.com"
  @nonce "nonce-1"
  @turn_ip {192, 0, 2, 10}
  @turn_port 3478
  @peer {{192, 0, 2, 20}, 49_200}

  test "a padded ChannelData payload is delivered without its padding" do
    client = channel_bound_client()
    [channel] = Map.keys(client.channel_addr)

    # 263 bytes: the tail of a 1413-byte ClientHello after a 1175-byte fragment.
    payload = <<22, 254, 253>> <> :binary.copy(<<0xAB>>, 260)
    padded = <<channel::16, byte_size(payload)::16, payload::binary, 0>>

    assert {:data, @peer, ^payload, %Client{}} =
             Client.handle_message(client, {:socket_data, @turn_ip, @turn_port, padded})
  end

  defp channel_bound_client do
    uri = ExSTUN.URI.parse!("turn:192.0.2.10:3478?transport=udp")
    {:ok, client} = Client.new(uri, @username, @password)

    {:send, _dst, msg, client} = Client.allocate(client)
    {:ok, req} = Message.decode(msg)

    challenge =
      req.transaction_id
      |> Message.new(%Type{class: :error_response, method: :allocate}, [
        %Nonce{value: @nonce},
        %Realm{value: @realm},
        %ErrorCode{code: 401}
      ])
      |> Message.encode()

    {:send, _dst, msg, client} = reply(client, challenge)
    {:ok, req} = Message.decode(msg)

    allocated =
      success(req, :allocate, [
        %XORRelayedAddress{address: @turn_ip, port: 49_300},
        %Lifetime{value: 600},
        %XORMappedAddress{address: {198, 51, 100, 7}, port: 40_000}
      ])

    {:allocation_created, _relay, client} = reply(client, allocated)

    {peer_ip, peer_port} = @peer
    {:send, _dst, msg, client} = Client.create_channel(client, peer_ip, peer_port)
    {:ok, req} = Message.decode(msg)
    {:channel_created, @peer, client} = reply(client, success(req, :channel_bind, []))

    client
  end

  defp reply(client, packet), do: Client.handle_message(client, {:socket_data, @turn_ip, @turn_port, packet})

  defp success(req, method, attributes) do
    {:ok, %Username{value: username}} = Message.get_attribute(req, Username)
    key = Message.lt_key(username, @password, @realm)
    :ok = Message.authenticate(req, key)

    req.transaction_id
    |> Message.new(%Type{class: :success_response, method: method}, attributes)
    |> Message.with_integrity(key)
    |> Message.encode()
  end
end
