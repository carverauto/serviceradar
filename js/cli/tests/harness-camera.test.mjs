import assert from "node:assert/strict"
import test from "node:test"

import {CAMERA_API_ERRORS, createHarnessCameraApi} from "../harness/camera.js"

const request = {camera_source_id: "cam-1", stream_profile_id: "main"}

function fakeDocument() {
  return {
    createElement: () => ({style: {}, remove() {}, getContext: () => null}),
  }
}

test("harness camera mock plays attached tiles and logs open and close", () => {
  const calls = []
  const camera = createHarnessCameraApi({onCall: (line) => calls.push(line), documentRef: fakeDocument()})
  const states = []

  const handle = camera.open(request)
  handle.onState((event) => states.push(event.state))
  const children = []
  handle.attach({appendChild: (child) => children.push(child)})

  assert.equal(children.length, 1)
  assert.equal(handle.state, "playing")

  handle.close()

  assert.deepEqual(states, ["requesting", "playing", "closed"])
  assert.deepEqual(calls, ["camera open cam-1", "camera close cam-1"])
  assert.equal(camera.activeCount(), 0)
})

test("harness camera mock keeps the production session cap and error codes", () => {
  const camera = createHarnessCameraApi({documentRef: fakeDocument()})

  for (let i = 0; i < 9; i += 1) camera.open(request)

  assert.throws(() => camera.open(request), (error) => error.code === CAMERA_API_ERRORS.SESSION_LIMIT)
  assert.throws(
    () => createHarnessCameraApi().open({camera_source_id: "cam-1"}),
    (error) => error.code === CAMERA_API_ERRORS.INVALID_REQUEST
  )

  camera.closeAll()
  assert.equal(camera.activeCount(), 0)
})
