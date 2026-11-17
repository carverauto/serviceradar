//! One record on its way from an input thread to the NATS output: the length
//! of its ruleset digest in one byte, the digest, and then a serialized
//! `ExportLogsServiceRequest` holding the record. A record encoded before any
//! ruleset was active has an empty digest and is the GELF JSON to publish.

/// Frames `request`, the serialized record normalized by the ruleset `digest`.
pub(crate) fn encode(digest: &str, request: &[u8]) -> Result<Vec<u8>, &'static str> {
    let length = u8::try_from(digest.len()).or(Err("The Zen ruleset digest is too long"))?;
    let mut frame = Vec::with_capacity(1 + digest.len() + request.len());
    frame.push(length);
    frame.extend_from_slice(digest.as_bytes());
    frame.extend_from_slice(request);
    Ok(frame)
}

/// The ruleset digest and serialized request of a frame.
pub(crate) fn decode(frame: &[u8]) -> Result<(&str, &[u8]), &'static str> {
    const MALFORMED: &str = "A normalized record frame is malformed";
    let (length, rest) = frame.split_first().ok_or(MALFORMED)?;
    let (digest, request) = rest
        .split_at_checked(usize::from(*length))
        .ok_or(MALFORMED)?;
    Ok((std::str::from_utf8(digest).or(Err(MALFORMED))?, request))
}
