import {describe, expect, it, vi} from "vitest"

import {
  DESKTOP_CONTROL_CHANNEL,
  DESKTOP_MEDIA_ACK_MESSAGE,
  DESKTOP_MEDIA_CHANNEL,
  DESKTOP_MEDIA_MAX_CLOSE_REASON,
  DESKTOP_MEDIA_QUALITY_AUTO,
  DESKTOP_MEDIA_QUALITY_LOW,
  RemoteDesktopWebRTCClient,
  createDesktopMediaProcessor,
  desktopMediaStreamFromTrackEvent,
  isAllowedDesktopIceCandidate,
  validateDesktopOfferSdp,
} from "./webrtc_client"
import {
  DESKTOP_PAYLOAD_METADATA,
  DESKTOP_PAYLOAD_TILE,
  DESKTOP_PAYLOAD_VIDEO,
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

  emitTrack(event) {
    this.handlers.track?.(event)
  }

  emitConnectionState(state) {
    this.connectionState = state
    this.handlers.connectionstatechange?.({})
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
  it("normalizes received video tracks into desktop media streams", () => {
    const videoTrack = {kind: "video"}
    const existingStream = {id: "stream-1"}
    const mediaStreamFactory = vi.fn((tracks) => ({id: "created-stream", tracks}))

    expect(desktopMediaStreamFromTrackEvent({track: {kind: "audio"}, streams: [existingStream]})).toBeNull()
    expect(desktopMediaStreamFromTrackEvent({track: videoTrack, streams: [existingStream]})).toBe(existingStream)
    expect(desktopMediaStreamFromTrackEvent({track: videoTrack, streams: []}, mediaStreamFactory)).toEqual({
      id: "created-stream",
      tracks: [videoTrack],
    })
  })

  it("provides a pluggable desktop media processor boundary", () => {
    const frame = {
      sessionBindingId: "session-boundary",
      mediaSessionId: "media-boundary",
      sequence: 3,
      payload: new Uint8Array([1, 2]),
    }
    const frameParser = vi.fn(() => frame)
    const queueState = vi.fn(() => ({decodeQueueSize: 20, maxDecodeQueueSize: 12}))
    const shouldDropFrame = vi.fn(() => true)
    const processor = createDesktopMediaProcessor({
      frameParser,
      queueState,
      shouldDropFrame,
    })
    const data = new Uint8Array([9, 9])

    expect(processor.process(data)).toEqual({
      frame,
      dropped: true,
      queueState: {decodeQueueSize: 20, maxDecodeQueueSize: 12},
    })
    expect(frameParser).toHaveBeenCalledWith(data)
    expect(shouldDropFrame).toHaveBeenCalledWith(frame, {decodeQueueSize: 20, maxDecodeQueueSize: 12})
    expect(processor.queueState()).toEqual({decodeQueueSize: 20, maxDecodeQueueSize: 12})
  })

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

  it("deletes a late viewer response after an in-flight connection is closed", async () => {
    let resolveCreate
    const createResponse = new Promise((resolve) => {
      resolveCreate = resolve
    })
    const fetchMock = vi
      .fn()
      .mockImplementationOnce(() => createResponse)
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "closed"}}),
      })
    const peerConnectionFactory = vi.fn(() => new MockPeerConnection({}))
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-late/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory,
    })

    const connectPromise = client.connect()
    client.close("desktop viewer unmounted")

    resolveCreate({
      ok: true,
      json: async () => ({
        data: {
          viewer_session_id: "viewer-late",
          offer_sdp: "v=0\r\nm=application",
        },
      }),
    })

    await expect(connectPromise).rejects.toThrow(/connection was closed/)
    expect(peerConnectionFactory).not.toHaveBeenCalled()
    expect(client.viewerSessionId).toBeNull()
    expect(client.peerConnection).toBeNull()
    expect(fetchMock.mock.calls[1]).toEqual([
      "/api/desktop-sessions/session-late/webrtc/session/viewer-late",
      expect.objectContaining({
        method: "DELETE",
        keepalive: true,
        body: JSON.stringify({reason: "desktop viewer closed during creation"}),
      }),
    ])
  })

  it("closes the peer, viewer API session, and UI callback on peer failure", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-peer-failed",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "closed"}}),
      })
    const peer = new MockPeerConnection({})
    const onClose = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-peer-failed/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      onClose,
    })

    await client.connect()
    peer.emitConnectionState("failed")
    await Promise.resolve()

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onClose).toHaveBeenCalledWith("failed")
    expect(peer.closed).toBe(true)
    expect(client.viewerSessionId).toBeNull()
    expect(fetchMock.mock.calls[2]).toEqual([
      "/api/desktop-sessions/session-peer-failed/webrtc/session/viewer-peer-failed",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({reason: "desktop peer connection failed"}),
      }),
    ])
  })

  it("validates desktop WebRTC offer media sections and video codecs", () => {
    expect(validateDesktopOfferSdp("v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n")).toContain(
      "m=application"
    )
    expect(
      validateDesktopOfferSdp("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 97\r\na=rtpmap:96 H264/90000\r\na=rtpmap:97 rtx/90000\r\n")
    ).toContain("H264")
    expect(() => validateDesktopOfferSdp("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n")).toThrow(
      /media type/
    )
    expect(() => validateDesktopOfferSdp("v=0\r\n")).toThrow(/media sections/)
    expect(() =>
      validateDesktopOfferSdp("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 98\r\na=rtpmap:98 H265/90000\r\n")
    ).toThrow(/codec/)
  })

  it("rejects disallowed desktop WebRTC offers before applying remote description", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-bad-offer",
            offer_sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n",
          },
        }),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "closed"}}),
      })
    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-bad-offer/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
    })

    await expect(client.connect()).rejects.toThrow(/media type/)
    await Promise.resolve()
    expect(peer.remoteDescription).toBeUndefined()
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchMock.mock.calls[1]).toEqual([
      "/api/desktop-sessions/session-bad-offer/webrtc/session/viewer-bad-offer",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({reason: "desktop viewer connect failed"}),
      }),
    ])
  })

  it("surfaces received WebRTC video tracks for browser media-track rendering", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-track",
            offer_sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\n",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
    const peer = new MockPeerConnection({})
    const onMediaStream = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-track/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      onMediaStream,
    })
    const mediaStream = {id: "rdp-video-stream"}

    await client.connect()
    peer.emitTrack({track: {kind: "audio"}, streams: [mediaStream]})
    peer.emitTrack({track: {kind: "video"}, streams: [mediaStream]})

    expect(onMediaStream).toHaveBeenCalledTimes(1)
    expect(onMediaStream).toHaveBeenCalledWith(mediaStream, {
      track: {kind: "video"},
      streams: [mediaStream],
    })
  })

  it("parses media channel frames and leaves metadata bytes renderer-owned", async () => {
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
    expect(onFrame.mock.calls[0][0].metadata.byteLength).toBeGreaterThan(0)
    expect(onFrame.mock.calls[0]).toHaveLength(1)
  })

  it("routes media channel data through the processing boundary", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-processor",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {closed: true}}),
      })
    const frame = {
      sessionBindingId: "session-processor",
      mediaSessionId: "media-processor",
      sequence: 4,
      payload: new Uint8Array([1, 2, 3]),
    }
    const processor = {
      process: vi.fn(() => ({frame, dropped: false, queueState: {decodeQueueSize: 0, maxDecodeQueueSize: 8}})),
      queueState: vi.fn(() => ({decodeQueueSize: 1, maxDecodeQueueSize: 8})),
      close: vi.fn(),
    }
    const peer = new MockPeerConnection({})
    const onFrame = vi.fn()
    const mediaProcessorFactory = vi.fn(() => processor)
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-processor/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaProcessorFactory,
      mediaAckFrameInterval: 1,
      onFrame,
    })
    const rawMessage = new Uint8Array([8, 8])

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()
    mediaChannel.emitMessage(rawMessage)

    expect(mediaProcessorFactory).toHaveBeenCalledWith({queueState: expect.any(Function)})
    expect(processor.process).toHaveBeenCalledWith(rawMessage)
    expect(onFrame).toHaveBeenCalledWith(frame)
    expect(processor.queueState).toHaveBeenCalled()
    expect(JSON.parse(controlChannel.sent[0])).toMatchObject({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-processor",
      media_session_id: "media-processor",
      last_accepted_seq: 4,
      credit_bytes: 3,
    })

    client.close()
    expect(processor.close).toHaveBeenCalled()
  })

  it("fails closed when desktop media processing rejects a frame", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-malformed",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {closed: true}}),
      })
    const processorError = new Error("malformed desktop media")
    const processor = {
      process: vi.fn(() => {
        throw processorError
      }),
      queueState: vi.fn(),
      close: vi.fn(),
    }
    const peer = new MockPeerConnection({})
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    const onError = vi.fn()
    const onFrame = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-malformed/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaProcessorFactory: () => processor,
      onError,
      onFrame,
    })

    await client.connect()
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    mediaChannel.emitMessage(new Uint8Array([0xde, 0xad]))

    expect(onError).toHaveBeenCalledWith(processorError)
    expect(onFrame).not.toHaveBeenCalled()
    expect(processor.close).toHaveBeenCalled()
    expect(mediaChannel.closed).toBe(true)
    expect(controlChannel.closed).toBe(true)
    expect(peer.closed).toBe(true)
    expect(fetchMock.mock.calls[2]).toEqual([
      "/api/desktop-sessions/session-malformed/webrtc/session/viewer-malformed",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({reason: "desktop media frame processing failed"}),
      }),
    ])
  })

  it("fails closed when desktop control processing rejects a frame", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-control-malformed",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {closed: true}}),
      })
    const peer = new MockPeerConnection({})
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    const onControlMessage = vi.fn()
    const onError = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-control-malformed/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      onControlMessage,
      onError,
    })

    await client.connect()
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.emitMessage("{")

    expect(onError.mock.calls[0][0]).toBeInstanceOf(SyntaxError)
    expect(onControlMessage).not.toHaveBeenCalled()
    expect(mediaChannel.closed).toBe(true)
    expect(controlChannel.closed).toBe(true)
    expect(peer.closed).toBe(true)
    expect(fetchMock.mock.calls[2]).toEqual([
      "/api/desktop-sessions/session-control-malformed/webrtc/session/viewer-control-malformed",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({reason: "desktop control frame processing failed"}),
      }),
    ])
  })

  it("ignores stale data channel messages after the viewer session is closed", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-stale",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {closed: true}}),
      })
    const processor = {
      process: vi.fn(),
      queueState: vi.fn(),
      close: vi.fn(),
    }
    const peer = new MockPeerConnection({})
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    const onControlMessage = vi.fn()
    const onFrame = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-stale/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaProcessorFactory: () => processor,
      onControlMessage,
      onFrame,
    })

    await client.connect()
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    client.close("test closed")

    mediaChannel.emitMessage(new Uint8Array([0xde, 0xad]))
    controlChannel.emitMessage(JSON.stringify({type: "quality", level: "low"}))

    expect(processor.process).not.toHaveBeenCalled()
    expect(onFrame).not.toHaveBeenCalled()
    expect(onControlMessage).not.toHaveBeenCalled()
    expect(fetchMock.mock.calls).toHaveLength(3)
    expect(fetchMock.mock.calls[2]).toEqual([
      "/api/desktop-sessions/session-stale/webrtc/session/viewer-stale",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({reason: "test closed"}),
      }),
    ])
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

  it("keeps pending media acknowledgements bound to their media session", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-bindings",
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
      signalingPath: "/api/desktop-sessions/session-bindings/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckCreditBytes: 65_536,
      mediaAckFrameInterval: 10,
      onAck,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-a",
        mediaSessionId: "media-a",
        sequence: 1,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2, 3]),
      })
    )
    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-b",
        mediaSessionId: "media-b",
        sequence: 2,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([4, 5, 6, 7]),
      })
    )

    expect(controlChannel.sent).toHaveLength(0)

    controlChannel.open()

    expect(controlChannel.sent.map((message) => JSON.parse(message))).toEqual([
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-a",
        media_session_id: "media-a",
        last_accepted_seq: 1,
        credit_bytes: 3,
      },
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-b",
        media_session_id: "media-b",
        last_accepted_seq: 2,
        credit_bytes: 4,
      },
    ])
    expect(onAck).toHaveBeenCalledTimes(2)
    expect(onAck.mock.calls.map(([ack]) => ack)).toEqual(
      controlChannel.sent.map((message) => JSON.parse(message))
    )
  })

  it("drops stale non-critical media frames before metadata parsing", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-drop",
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
    const onFrameDropped = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-drop/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckFrameInterval: 1,
      mediaQueueState: () => ({decodeQueueSize: 20, maxDecodeQueueSize: 12}),
      onFrame,
      onFrameDropped,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-drop",
        mediaSessionId: "media-drop",
        sequence: 12,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        metadata: new Uint8Array([0x7b]),
        payload: new Uint8Array([1, 2, 3]),
      })
    )

    expect(onFrame).not.toHaveBeenCalled()
    expect(onFrameDropped).toHaveBeenCalledTimes(1)
    expect(onFrameDropped.mock.calls[0][0].sequence).toBe(12)
    expect(JSON.parse(controlChannel.sent[0])).toEqual({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-drop",
      media_session_id: "media-drop",
      last_accepted_seq: 12,
      credit_bytes: 4,
      quality_level: DESKTOP_MEDIA_QUALITY_LOW,
      pause: true,
    })
  })

  it("sends pause and resume hints with media acknowledgements under browser backpressure", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-pressure",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    const queueStates = [
      {decodeQueueSize: 20, maxDecodeQueueSize: 12},
      {decodeQueueSize: 18, maxDecodeQueueSize: 12},
      {decodeQueueSize: 4, maxDecodeQueueSize: 12},
    ]
    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-pressure/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckCreditBytes: 65_536,
      mediaAckFrameInterval: 10,
      mediaQueueState: () => queueStates.shift() || {decodeQueueSize: 0, maxDecodeQueueSize: 12},
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-pressure",
        mediaSessionId: "media-pressure",
        sequence: 20,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1]),
      })
    )
    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-pressure",
        mediaSessionId: "media-pressure",
        sequence: 21,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([2]),
      })
    )
    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-pressure",
        mediaSessionId: "media-pressure",
        sequence: 22,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([3]),
      })
    )

    expect(controlChannel.sent.map((message) => JSON.parse(message))).toEqual([
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-pressure",
        media_session_id: "media-pressure",
        last_accepted_seq: 20,
        credit_bytes: 1,
        quality_level: DESKTOP_MEDIA_QUALITY_LOW,
        pause: true,
      },
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-pressure",
        media_session_id: "media-pressure",
        last_accepted_seq: 22,
        credit_bytes: 2,
        quality_level: DESKTOP_MEDIA_QUALITY_AUTO,
        resume: true,
      },
    ])
  })

  it("pauses media when the bounded render queue reaches capacity", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-pressure-full",
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
      signalingPath: "/api/desktop-sessions/session-pressure-full/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckFrameInterval: 10,
      mediaQueueState: () => ({decodeQueueSize: 12, maxDecodeQueueSize: 12}),
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-pressure-full",
        mediaSessionId: "media-pressure-full",
        sequence: 24,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2]),
      })
    )

    expect(controlChannel.sent.map((message) => JSON.parse(message))).toEqual([
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-pressure-full",
        media_session_id: "media-pressure-full",
        last_accepted_seq: 24,
        credit_bytes: 2,
        quality_level: DESKTOP_MEDIA_QUALITY_LOW,
        pause: true,
      },
    ])
  })

  it("uses post-enqueue queue state when deciding browser media backpressure", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-pressure-after-enqueue",
            offer_sdp: "v=0\r\nm=application",
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })

    let queuedFrames = 11
    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-pressure-after-enqueue/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckFrameInterval: 10,
      mediaQueueState: () => ({decodeQueueSize: queuedFrames, maxDecodeQueueSize: 12}),
      onFrame: () => {
        queuedFrames += 1
      },
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-pressure-after-enqueue",
        mediaSessionId: "media-pressure-after-enqueue",
        sequence: 25,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2]),
      })
    )

    expect(controlChannel.sent.map((message) => JSON.parse(message))).toEqual([
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-pressure-after-enqueue",
        media_session_id: "media-pressure-after-enqueue",
        last_accepted_seq: 25,
        credit_bytes: 2,
        quality_level: DESKTOP_MEDIA_QUALITY_LOW,
        pause: true,
      },
    ])
  })

  it("flushes pending media credit with a close reason before closing channels", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-close-pending",
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
        json: async () => ({data: {signaling_state: "closed"}}),
      })

    const peer = new MockPeerConnection({})
    const onAck = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-close-pending/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckCreditBytes: 65_536,
      mediaAckFrameInterval: 10,
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
        sessionBindingId: "session-close-pending",
        mediaSessionId: "media-close-pending",
        sequence: 30,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2, 3]),
      })
    )

    expect(controlChannel.sent).toHaveLength(0)

    client.close("viewer closed")
    await Promise.resolve()

    expect(JSON.parse(controlChannel.sent[0])).toEqual({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-close-pending",
      media_session_id: "media-close-pending",
      last_accepted_seq: 30,
      credit_bytes: 3,
      close_reason: "viewer closed",
    })
    expect(onAck).toHaveBeenCalledWith({
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: "session-close-pending",
      media_session_id: "media-close-pending",
      last_accepted_seq: 30,
      credit_bytes: 3,
      close_reason: "viewer closed",
    })
    expect(controlChannel.closed).toBe(true)
  })

  it("sends a control-only close acknowledgement after media credit is already flushed", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-close-flushed",
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
        json: async () => ({data: {signaling_state: "closed"}}),
      })

    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-close-flushed/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckCreditBytes: 65_536,
      mediaAckFrameInterval: 1,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-close-flushed",
        mediaSessionId: "media-close-flushed",
        sequence: 31,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1, 2, 3]),
      })
    )

    client.close("viewer closed")
    await Promise.resolve()

    expect(controlChannel.sent.map((message) => JSON.parse(message))).toEqual([
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-close-flushed",
        media_session_id: "media-close-flushed",
        last_accepted_seq: 31,
        credit_bytes: 3,
      },
      {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: "session-close-flushed",
        media_session_id: "media-close-flushed",
        last_accepted_seq: 31,
        credit_bytes: 0,
        close_reason: "viewer closed",
      },
    ])
  })

  it("caps final media close acknowledgement reasons", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-close-long",
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
        json: async () => ({data: {signaling_state: "closed"}}),
      })

    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-close-long/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckFrameInterval: 1,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-close-long",
        mediaSessionId: "media-close-long",
        sequence: 32,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1]),
      })
    )

    const longReason = ` ${"x".repeat(DESKTOP_MEDIA_MAX_CLOSE_REASON + 20)} `
    client.close(longReason)
    await Promise.resolve()

    const closeAck = JSON.parse(controlChannel.sent[1])
    const deleteBody = JSON.parse(fetchMock.mock.calls[2][1].body)

    expect(closeAck.close_reason).toBe("x".repeat(DESKTOP_MEDIA_MAX_CLOSE_REASON))
    expect(deleteBody.reason).toBe("x".repeat(DESKTOP_MEDIA_MAX_CLOSE_REASON))
  })

  it("caps final media close acknowledgement reasons by UTF-8 bytes", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-close-wide",
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
        json: async () => ({data: {signaling_state: "closed"}}),
      })

    const peer = new MockPeerConnection({})
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-close-wide/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaAckFrameInterval: 1,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    const controlChannel = new MockDataChannel(DESKTOP_CONTROL_CHANNEL)
    peer.emitDataChannel(mediaChannel)
    peer.emitDataChannel(controlChannel)
    controlChannel.open()

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-close-wide",
        mediaSessionId: "media-close-wide",
        sequence: 33,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        payload: new Uint8Array([1]),
      })
    )

    client.close("é".repeat(DESKTOP_MEDIA_MAX_CLOSE_REASON))
    await Promise.resolve()

    const closeAck = JSON.parse(controlChannel.sent[1])

    expect(new TextEncoder().encode(closeAck.close_reason).byteLength).toBeLessThanOrEqual(
      DESKTOP_MEDIA_MAX_CLOSE_REASON
    )
    expect(closeAck.close_reason).toBe("é".repeat(DESKTOP_MEDIA_MAX_CLOSE_REASON / 2))
  })

  it("does not drop keyframes or metadata frames when queues are saturated", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-critical",
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
    const onFrameDropped = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-critical/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      mediaQueueState: () => ({decodeQueueSize: 20, maxDecodeQueueSize: 12}),
      onFrame,
      onFrameDropped,
    })

    await client.connect()
    const mediaChannel = new MockDataChannel(DESKTOP_MEDIA_CHANNEL)
    peer.emitDataChannel(mediaChannel)

    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-critical",
        mediaSessionId: "media-critical",
        sequence: 13,
        payloadFamily: DESKTOP_PAYLOAD_VIDEO,
        encoding: "h264_annexb",
        keyframe: true,
        width: 640,
        height: 480,
        payload: new Uint8Array([1, 2, 3]),
      })
    )
    mediaChannel.emitMessage(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-critical",
        mediaSessionId: "media-critical",
        sequence: 14,
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        metadata: {cursor: "visible"},
      })
    )

    expect(onFrame).toHaveBeenCalledTimes(2)
    expect(onFrameDropped).not.toHaveBeenCalled()
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
      toJSON: () => ({candidate: "candidate:1 1 udp 1 8.8.8.8 5000 typ srflx", sdpMid: "0"}),
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

  it("filters unsafe ICE candidates before posting them to the server", async () => {
    expect(isAllowedDesktopIceCandidate("candidate:1 1 udp 1 8.8.8.8 5000 typ srflx")).toBe(true)
    expect(isAllowedDesktopIceCandidate("candidate:1 1 udp 1 10.0.0.1 5000 typ host")).toBe(false)
    expect(isAllowedDesktopIceCandidate("candidate:1 1 udp 1 127.0.0.1 5000 typ host")).toBe(false)
    expect(isAllowedDesktopIceCandidate("candidate:1 1 udp 1 host.local 5000 typ host")).toBe(false)
    expect(isAllowedDesktopIceCandidate("candidate:1 1 udp 1 ::1 5000 typ host")).toBe(false)

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-ice-filter",
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

    const peer = new MockPeerConnection({})
    const onStatus = vi.fn()
    const client = new RemoteDesktopWebRTCClient({
      signalingPath: "/api/desktop-sessions/session-ice-filter/webrtc/session",
      fetchImpl: fetchMock,
      documentRef: documentStub(),
      peerConnectionFactory: () => peer,
      onStatus,
    })

    await client.connect()
    peer.emitIceCandidate({toJSON: () => ({candidate: "candidate:1 1 udp 1 192.168.1.20 5000 typ host"})})
    peer.emitIceCandidate({toJSON: () => ({candidate: "candidate:2 1 udp 1 8.8.8.8 5000 typ srflx"})})
    await Promise.resolve()

    expect(onStatus).toHaveBeenCalledWith("ice_candidate_rejected")
    expect(fetchMock).toHaveBeenCalledTimes(3)
    expect(fetchMock.mock.calls[2][0]).toBe(
      "/api/desktop-sessions/session-ice-filter/webrtc/session/viewer-ice-filter/candidates"
    )
  })

  it("calls the global fetch with a Window receiver when no fetchImpl is injected", async () => {
    // Browsers enforce the WebIDL receiver check on Window.fetch: invoking a
    // detached reference with any other receiver throws
    // "Failed to execute 'fetch' on 'Window': Illegal invocation" before a
    // request is ever issued, which the RDP launcher surfaces to the operator.
    const originalFetch = globalThis.fetch
    const receivers = []
    const responses = [
      {
        ok: true,
        json: async () => ({
          data: {viewer_session_id: "viewer-default", offer_sdp: "v=0\r\nm=application"},
        }),
      },
      {ok: true, json: async () => ({data: {signaling_state: "answer_applied"}})},
    ]

    globalThis.fetch = function fetch() {
      receivers.push(this)

      if (this !== globalThis) {
        throw new TypeError("Failed to execute 'fetch' on 'Window': Illegal invocation")
      }

      return Promise.resolve(responses.shift())
    }

    try {
      const client = new RemoteDesktopWebRTCClient({
        signalingPath: "/api/desktop-sessions/session-default/webrtc/session",
        documentRef: documentStub(),
        peerConnectionFactory: () => new MockPeerConnection({}),
      })

      const result = await client.connect()

      expect(result.viewerSessionId).toBe("viewer-default")
      expect(receivers).toHaveLength(2)
      expect(receivers.every((receiver) => receiver === globalThis)).toBe(true)
    } finally {
      globalThis.fetch = originalFetch
    }
  })
})
