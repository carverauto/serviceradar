defmodule ServiceRadarCoreElx.CameraRelay.TurnClientPinTest do
  # The camera WebRTC peer reaches a browser through a TURN relay pair.
  # ex_turn is pinned to carverauto/ex_turn for fixes that no Hex release
  # carries yet; each test guards against a bump back to an unfixed release.
  #
  # * eturnal pads every ChannelData message to four bytes. A payload whose
  #   length is not a multiple of four (the tail of a fragmented DTLS
  #   ClientHello) must still reach ICE, or the DTLS handshake never starts
  #   (elixir-webrtc/ex_turn#12).
  # * ICE binds a channel to each port of a peer back to back. Binds still in
  #   flight must not share a channel number, or the server refuses the second
  #   ("Channel already bound to a different peer") (elixir-webrtc/ex_turn#13).
  # * One refused peer must not fail the allocation: the client used to go to
  #   :error, and ex_ice then crashed the viewer's ICE agent with a MatchError
  #   on its next send (elixir-webrtc/ex_turn#15).
  use ExUnit.Case, async: true

  alias ExSTUN.Message
  alias ExSTUN.Message.Attribute.ErrorCode
  alias ExSTUN.Message.Attribute.Nonce
  alias ExSTUN.Message.Attribute.Realm
  alias ExSTUN.Message.Attribute.Username
  alias ExSTUN.Message.Attribute.XORMappedAddress
  alias ExSTUN.Message.Type
  alias ExTURN.Attribute.ChannelNumber
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
  @other_peer {{192, 0, 2, 20}, 49_201}

  test "a padded ChannelData payload is delivered without its padding" do
    client = channel_bound_client()
    [channel] = Map.keys(client.channel_addr)

    # 263 bytes: the tail of a 1413-byte ClientHello after a 1175-byte fragment.
    payload = <<22, 254, 253>> <> :binary.copy(<<0xAB>>, 260)
    padded = <<channel::16, byte_size(payload)::16, payload::binary, 0>>

    assert {:data, @peer, ^payload, %Client{}} =
             Client.handle_message(client, {:socket_data, @turn_ip, @turn_port, padded})
  end

  test "channel binds in flight for two ports of one peer carry distinct channel numbers" do
    client = allocated_client()
    {peer_ip, peer_port} = @peer
    {other_ip, other_port} = @other_peer

    {:send, _dst, first, client} = Client.create_channel(client, peer_ip, peer_port)
    {:send, _dst, second, _client} = Client.create_channel(client, other_ip, other_port)

    assert channel_number(first) != channel_number(second)
  end

  test "a channel bind the server refuses leaves the allocation usable for the bound peer" do
    # A successful ChannelBind also installs the permission for that peer.
    client = channel_bound_client()
    {other_ip, other_port} = @other_peer

    {:send, _dst, msg, client} = Client.create_channel(client, other_ip, other_port)
    {:ok, req} = Message.decode(msg)

    assert {:ok, %Client{state: :allocated} = client} =
             reply(client, error(req, :channel_bind, 403))

    assert {:send, {@turn_ip, @turn_port}, _data, %Client{}} = Client.send(client, @peer, "media")
  end

  defp allocated_client do
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
    client
  end

  defp channel_bound_client do
    client = allocated_client()
    {peer_ip, peer_port} = @peer
    {:send, _dst, msg, client} = Client.create_channel(client, peer_ip, peer_port)
    {:ok, req} = Message.decode(msg)
    {:channel_created, @peer, client} = reply(client, success(req, :channel_bind, []))

    client
  end

  defp channel_number(packet) do
    {:ok, msg} = Message.decode(packet)
    {:ok, %ChannelNumber{value: number}} = Message.get_attribute(msg, ChannelNumber)
    number
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

  # An error response authenticated with the long-term key, as eturnal sends
  # for a peer its blacklist_peers policy refuses.
  defp error(req, method, code) do
    {:ok, %Username{value: username}} = Message.get_attribute(req, Username)
    key = Message.lt_key(username, @password, @realm)

    req.transaction_id
    |> Message.new(%Type{class: :error_response, method: method}, [%ErrorCode{code: code}])
    |> Message.with_integrity(key)
    |> Message.encode()
  end
end
