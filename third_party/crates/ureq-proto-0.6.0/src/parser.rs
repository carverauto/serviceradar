use http::{Method, Request, Response, StatusCode, Version};
use httparse::Status;

use crate::Error;

/// Parse bytes into a complete response.
///
/// Complete means that the last HTTP header is followed by an `\r\n`.
///
/// If the result is `None`, the bytes did not contain a full response. That
/// typically means you need to read more bytes and append to the in input buffer
/// before trying again.
///
/// The first `usize` in the resulting pair, is the number of bytes required from
/// the input buffer to form the response.
///
/// The const `N` is the number of headers to max expect. If the input has more
/// headers than `N` you get an error [`Error::HttpParseTooManyHeaders`].
pub fn try_parse_response<const N: usize>(
    input: &[u8],
) -> Result<Option<(usize, Response<()>)>, Error> {
    let mut headers = [httparse::EMPTY_HEADER; N]; // 100 headers ~3kb

    let mut res = httparse::Response::new(&mut headers);

    let maybe_input_used = match res.parse(input) {
        Ok(v) => v,
        Err(e) => {
            return Err(if e == httparse::Error::TooManyHeaders {
                // For expect-100 we use this value to detect that the server
                // sent a regular response instead of a 100-continue.
                Error::HttpParseTooManyHeaders
            } else {
                e.into()
            });
        }
    };

    let Status::Complete(input_used) = maybe_input_used else {
        return Ok(None);
    };

    let version = {
        // unwrap: Looking at the impl of parse(), version cannot be None.
        let v = res.version.unwrap_or(1);
        match v {
            0 => Version::HTTP_10,
            1 => Version::HTTP_11,
            _ => return Err(Error::UnsupportedVersion),
        }
    };

    let status = {
        // unwrap: Looking at the impl of parse(), code cannot be None.
        let v = res.code.unwrap_or(000);
        // unwrap: Looking at the impl of parse(), the status is 3 digits and cant fail.
        StatusCode::from_u16(v).unwrap()
    };

    let mut builder = Response::builder().version(version).status(status);

    for h in res.headers {
        builder = builder.header(h.name, h.value);
    }

    let response = builder.body(()).expect("a valid response");

    Ok(Some((input_used, response)))
}

/// Try parsing as much as possible of a response.
///
/// To get a result we need at least the complete initial status row,
/// but we don't need complete headers.
///
/// The const `N` is the number of headers to max expect. If the input has more
/// headers than `N` you get an error [`Error::HttpParseTooManyHeaders`].
pub fn try_parse_partial_response<const N: usize>(
    input: &[u8],
) -> Result<Option<Response<()>>, Error> {
    let mut headers = vec![httparse::EMPTY_HEADER; N]; // 100 headers ~3kb

    let mut res = httparse::Response::new(&mut headers);

    match res.parse(input) {
        Ok(_) => {}
        Err(e) => {
            return Err(if e == httparse::Error::TooManyHeaders {
                // For expect-100 we use this value to detect that the server
                // sent a regular response instead of a 100-continue.
                Error::HttpParseTooManyHeaders
            } else {
                e.into()
            });
        }
    };

    let version = {
        match res.version {
            Some(0) => Version::HTTP_10,
            Some(1) => Version::HTTP_11,
            _ => return Ok(None),
        }
    };

    let status = {
        let v = match res.code {
            Some(v) => v,
            None => return Ok(None),
        };
        // unwrap: Looking at the impl of parse(), the status is 3 digits and cant fail.
        StatusCode::from_u16(v).unwrap_or_default()
    };

    let mut builder = Response::builder().version(version).status(status);

    for h in res.headers {
        if h.name.is_empty() || h.value.is_empty() {
            break;
        }
        builder = builder.header(h.name, h.value);
    }

    let response = builder.body(()).expect("a valid response");

    Ok(Some(response))
}

/// Parse bytes into a complete request.
///
/// Complete means that the last HTTP header is followed by an `\r\n`.
///
/// If the result is `None`, the bytes did not contain a full request. That
/// typically means you need to read more bytes and append to the in input buffer
/// before trying again.
///
/// The first `usize` in the resulting pair, is the number of bytes required from
/// the input buffer to form the request.
///
/// The const `N` is the number of headers to max expect. If the input has more
/// headers than `N` you get an error [`Error::HttpParseTooManyHeaders`].
pub fn try_parse_request<const N: usize>(
    input: &[u8],
) -> Result<Option<(usize, Request<()>)>, Error> {
    let mut headers = [httparse::EMPTY_HEADER; N]; // 100 headers ~3kb

    let mut req = httparse::Request::new(&mut headers);

    let maybe_input_used = match req.parse(input) {
        Ok(v) => v,
        Err(e) => {
            return Err(if e == httparse::Error::TooManyHeaders {
                // For expect-100 we use this value to detect that the server
                // sent a regular response instead of a 100-continue.
                Error::HttpParseTooManyHeaders
            } else {
                e.into()
            });
        }
    };

    let Status::Complete(input_used) = maybe_input_used else {
        return Ok(None);
    };

    let version = {
        // unwrap: Looking at the impl of parse(), version cannot be None.
        let v = req.version.unwrap_or(1);
        match v {
            0 => Version::HTTP_10,
            1 => Version::HTTP_11,
            _ => return Err(Error::UnsupportedVersion),
        }
    };

    let method = {
        // unwrap: Looking at the impl of parse(), method cannot be None.
        let v = req.method.unwrap_or("GET");
        // unwrap: Looking at the impl of parse(), method will be something.
        Method::from_bytes(v.as_bytes()).unwrap_or_default()
    };

    let uri = req.path.unwrap_or("/");

    let mut builder = Request::builder().uri(uri).version(version).method(method);

    for h in req.headers {
        builder = builder.header(h.name, h.value);
    }

    let request = builder
        .body(())
        .map_err(|e| Error::HttpParseFail(e.to_string()))?;

    Ok(Some((input_used, request)))
}

#[cfg(test)]
mod test {
    use crate::parser::{try_parse_request, try_parse_response};

    #[test]
    fn ensure_no_half_response() {
        let bytes = "HTTP/1.1 200 OK\r\n\
            Content-Type: text/plain\r\n\
            Content-Length: 100\r\n\r\n";

        try_parse_response::<0>(bytes.as_bytes()).expect_err("too many headers");
    }

    #[test]
    fn error_on_invalid_authority() {
        let bytes = "GET example\".com HTTP/1.1\r\n\r\n";
        try_parse_request::<0>(bytes.as_bytes()).expect_err("invalid URI character");
    }
}
