import {describe, expect, it, vi} from "vitest"

import {
  DESKTOP_CONTROL_CHANNEL,
  DESKTOP_MEDIA_ACK_MESSAGE,
  DESKTOP_MEDIA_CHANNEL,
  RemoteDesktopWebRTCClient,
} from "./webrtc_client"
import {
  DESKTOP_PAYLOAD_TILE,
  encodeDesktopMediaFrame,
} from "./media_frame"

class MockDataChannel {
  constructor(label) {
    this.label = label
    this.readyState = "connecting"
    this.handlers = {}
    this.sent = []
    this.closed = false
  }

  addEventListener(event, callback) {
    this.handlers[event] = callback
  }

  open() {
    this.readyState = "open"
    this.handlers.open?.({})
  }

  emitMessage(data) {
    this.handlers.message?.({data})
  }

  send(data) {
    this.sent.push(data)
  }

  close() {
    this.closed = true
    this.readyState = "closed"
    this.handlers.close?.({})
  }
}

class MockPeerConnection {
  constructor(config) {
    this.config = config
    this.handlers = {}
    this.connectionState = "new"
    this.closed = false
  }

  addEventListener(event, callback) {
    this.handlers[event] = callback
  }

  async setRemoteDescription(description) {
    this.remoteDescription = description
  }

  async createAnswer() {
    return {type: "answer", sdp: "v=0\r\nm=application"}
  }

  async setLocalDescription(description) {
    this.localDescription = description
  }

  emitDataChannel(channel) {
    this.handlers.datachannel?.({channel})
  }

  emitIceCandidate(candidate) {
    this.handlers.icecandidate?.({candidate})
  }

  close() {
    this.closed = true
    this.connectionState = "closed"
  }
}

function documentStub() {
  return {
    querySelector() {
      return {getAttribute: () => "csrf-token"}
    },
  }
}

describe("RemoteDesktopWebRTCClient", () => {
  it("creates a viewer session, applies an answer, and attaches offered channels", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-1",
            offer_sdp: "v=0\r\nm=application",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
            transport: "webrtc_desktop_media",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    const peers = []
    const onOpen = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-1/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: (config) => {
        const peer = new MockPeerConnection(config)
        peers.push(peer)
        return peer
      },
      onOpen,
    })

    const result = await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peers[0].emitDataChannel(mediaChannel)
    peers[0].emitDataChannel(controlChannel)
    mediaChannel.open()
    controlChannel.open()

    expect(result.viewerSessionId).toBe("viewer-1")
    expect(peers[0].remoteDescription).toEqual({type: "offer", sdp: "v=0\r\nm=application"})
    expect(peers[0].localDescription).toEqual({type: "answer", sdp: "v=0\r\nm=application"})
    expect(fetchMock.mock.calls[0][0]).toBe("/api/desktop-sessions/session-1/webrtc/session")
    expect(fetchMock.mock.calls[1][0]).toBe("/api/desktop-sessions/session-1/webrtc/session/viewer-1/answer")
    expect(fetchMock.mock.calls[1][1].headers["x-csrf-token"]).toBe("csrf-token")
    expect(onOpen).toHaveBeenCalledWith(DESKTOP_MEDIA_CHANNEL)
    expect(onOpen).toHaveBeenCalledWith(DESKTOP_CONTROL_CHANNEL)
  })

  it("parses media channel frames and exposes metadata", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-2",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    const peer = new MockPeerConnection({})
    const onFrame = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-2/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      onFrame,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-2",
        mediaSessionId: "media-2",
        sequence: 9,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        metadata: {tileSize: 64},
        payload: new Uint8Array([1, 2, 3]),
      })
    )

    expect(onFrame).toHaveBeenCalledTimes(1)
    expect(onFrame.mock.calls[0][0].sequence).toBe(9)
    expect(onFrame.mock.calls[0][1]).toEqual({tileSize: 64})
  })

  it("acknowledges media frames over the control channel with fresh credit", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-ack",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    const peer = new MockPeerConnection({})
    const onAck = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-ack/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckCreditBytes: 65_536,
      mediaAckFrameInterval: 1,
      onAck,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()
    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-ack",
        mediaSessionId: "media-ack",
        sequence: 10,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2, 3]),
      })
    )

    expect(controlChannel.sent).toHaveLength(1)
    expect(JSON.parse(controlChannel.sent[0])).toEqual({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-ack",
      media_session_id: "media-ack",
      last_accepted_seq: 10,
      credit_bytes: 3,
    })
    expect(onAck).toHaveBeenCalledWith({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-ack",
      media_session_id: "media-ack",
      last_accepted_seq: 10,
      credit_bytes: 3,
    })
  })

  it("coalesces media acknowledgements with consumed byte credit", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-coalesce",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    const peer = new MockPeerConnection({})
    const onAck = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-coalesce/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckCreditBytes: 65_536,
      mediaAckFrameInterval: 2,
      onAck,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-coalesce",
        mediaSessionId: "media-coalesce",
        sequence: 10,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2, 3]),
      })
    )

    expect(controlChannel.sent).toHaveLength(0)

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-coalesce",
        mediaSessionId: "media-coalesce",
        sequence: 11,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([4, 5, 6, 7]),
      })
    )

    expect(controlChannel.sent).toHaveLength(1)
    expect(JSON.parse(controlChannel.sent[0])).toEqual({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-coalesce",
      media_session_id: "media-coalesce",
      last_accepted_seq: 11,
      credit_bytes: 7,
    })
    expect(onAck).toHaveBeenCalledTimes(1)
  })

  it("sends control messages only after the control channel opens", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-3",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-3/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
    })

    await client.connect()
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(controlChannel)

    expect(client.sendControl({type: "quality", level: "low"})).toBe(false)

    controlChannel.open()

    expect(client.sendControl({type: "quality", level: "low"})).toBe(true)
    expect(controlChannel.sent).toEqual([JSON.stringify({type: "quality", level: "low"})])
  })

  it("posts ICE candidates and deletes the viewer session on close", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-4",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "candidate_buffered"}}),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "closed"}}),
      })

    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-4/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
    })

    await client.connect()
    peer.emitIceCandidate({
      toJSON: () => ({candidate: "candidate:1", sdpMid: "0"}),
    })
    await Promise.resolve()
    client.close("done")
    await Promise.resolve()

    expect(fetchMock.mock.calls[2][0]).toBe(
      "/api/desktop-sessions/session-4/webrtc/session/viewer-4/candidates"
    )
    expect(fetchMock.mock.calls[3][0]).toBe("/api/desktop-sessions/session-4/webrtc/session/viewer-4")
    expect(fetchMock.mock.calls[3][1].method).toBe("DELETE")
    expect(peer.closed).toBe(true)
  })
})
