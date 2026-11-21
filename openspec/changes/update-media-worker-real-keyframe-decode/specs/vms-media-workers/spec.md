## ADDED Requirements

### Requirement: Real keyframe decoding with recorded undecodable outcomes
The media worker SHALL decode each granted, verified sampled IDR keyframe from its real coded bitstream and SHALL NOT produce a frame it did not decode. It SHALL decode H.264 Constrained Baseline, Main and High profile keyframes that are 8-bit 4:2:0 and frame coded with equal Cb and Cr quantization offsets, with CAVLC or CABAC entropy coding, the 8x8 transform, scaling matrices and multiple slices, apply SPS cropping, and convert to RGB using the VUI matrix and range (defaulting to limited range, and to BT.709 above 576 lines or BT.601 otherwise). A granted, verified keyframe it cannot decode SHALL be recorded in the result envelope's `undecodable_keyframes` with its fragment sequence, codec and a bounded reason (`unsupported_codec`, `malformed_bitstream`, `limit_exceeded` or `invalid_container`), and the remaining keyframes of the block SHALL still be indexed.

#### Scenario: Main or High profile CABAC keyframe decodes to its real pixels
- **WHEN** a sampled fragment holds a High profile CABAC IDR keyframe using the 8x8 transform and equal Cb and Cr quantization offsets
- **THEN** the worker SHALL decode the keyframe to the picture the bitstream encodes, at the SPS cropped size and in the VUI colour space

#### Scenario: Unsupported codec is recorded, never fabricated
- **WHEN** a sampled fragment holds an HEVC keyframe, or an H.264 keyframe outside the supported profiles, chroma format, bit depth or frame coding, or whose active PPS specifies unequal Cb and Cr offsets
- **THEN** the worker SHALL record the keyframe in `undecodable_keyframes` with reason `unsupported_codec`
- **AND** the worker SHALL NOT emit a frame, detections or embeddings for that keyframe

#### Scenario: One undecodable keyframe does not fail the block
- **WHEN** one sampled keyframe in a granted, verified block is malformed and the others decode
- **THEN** the worker SHALL publish the decoded keyframes' results, record the malformed keyframe with reason `malformed_bitstream`, and acknowledge the job

#### Scenario: Oversized or excessive input is refused before decoding
- **WHEN** a granted, verified fragment exceeds a decoder limit because either the sample entry or the active SPS exceeds 4096 pixels in width or height, the access unit exceeds 4 MiB, the sample exceeds 4096 NAL units, the picture exceeds 1024 IDR slices, or a parameter set exceeds 4096 bytes
- **THEN** the worker SHALL record the keyframe with reason `limit_exceeded` without passing it to the decoder

#### Scenario: Sampled fragment exceeds the read-grant limit
- **WHEN** any sampled fragment exceeds the read-grant service's 4 MiB byte limit
- **THEN** the grant service SHALL reject the entire request before verification or decoding
- **AND** the worker SHALL handle the rejection as a job-level failure
