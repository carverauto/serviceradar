use std::io::Write;
use std::marker::PhantomData;

use http::{Method, Request, Response};

use crate::server::state::{
    Cleanup, ProvideResponse, RecvBody, RecvRequest, Send100, SendBody, SendResponse,
};
use crate::server::{RecvRequestResult, Reply, SendResponseResult};

pub struct Scenario {
    request: Request<()>,
    request_body: Vec<u8>,
    response: Response<()>,
    response_body: Vec<u8>,
}

impl Scenario {
    pub fn builder() -> ScenarioBuilder<()> {
        ScenarioBuilder::new()
    }
}

impl Scenario {
    pub fn to_recv_request(&self) -> Reply<RecvRequest> {
        // Create a new Reply in the RecvRequest state

        Reply::new().unwrap()
    }

    pub fn to_send_100(&self) -> Reply<Send100> {
        let mut reply = self.to_recv_request();

        // Write the request and proceed to Send100
        let input = write_request(&self.request);
        let (_, request) = reply.try_request(&input).unwrap();
        assert!(request.is_some());

        match reply.proceed().unwrap() {
            RecvRequestResult::Send100(v) => v,
            _ => unreachable!("Incorrect scenario not leading to_send_100()"),
        }
    }

    pub fn to_recv_body(&self) -> Reply<RecvBody> {
        // For tests that need a Reply in the RecvBody state, we'll create one directly
        // This is a simplified version that doesn't go through the full state machine
        let mut reply = self.to_recv_request();

        // Write the request and proceed to RecvBody
        let input = write_request(&self.request);
        let (_, request) = reply.try_request(&input).unwrap();
        assert!(request.is_some());

        // If the request has an Expect: 100-continue header, we need to go through Send100
        if self
            .request
            .headers()
            .get("expect")
            .is_some_and(|v| v == "100-continue")
        {
            match reply.proceed().unwrap() {
                RecvRequestResult::Send100(reply) => {
                    // Accept the 100-continue and proceed to RecvBody
                    let mut output = vec![0; 1024];
                    let (_, reply) = reply.accept(&mut output).unwrap();
                    reply
                }
                _ => unreachable!("Expect: 100-continue header should lead to Send100"),
            }
        } else {
            // Otherwise, proceed directly to RecvBody
            match reply.proceed().unwrap() {
                RecvRequestResult::RecvBody(reply) => reply,
                _ => unreachable!("Request without body should lead to ProvideResponse"),
            }
        }
    }

    pub fn to_provide_response(&self) -> Reply<ProvideResponse> {
        // For tests that need a Reply in the ProvideResponse state, we'll create one directly
        // This is a simplified version that doesn't go through the full state machine
        let mut reply = self.to_recv_request();

        // Write the request and proceed
        let input = write_request(&self.request);
        let (_, request) = reply.try_request(&input).unwrap();
        assert!(request.is_some());

        // If the request has an Expect: 100-continue header, we need to go through Send100
        if self
            .request
            .headers()
            .get("expect")
            .is_some_and(|v| v == "100-continue")
        {
            match reply.proceed().unwrap() {
                RecvRequestResult::Send100(reply) => {
                    // Accept the 100-continue and proceed to RecvBody
                    let mut output = vec![0; 1024];
                    let (_, mut reply) = reply.accept(&mut output).unwrap();

                    // Write the request body and proceed to ProvideResponse
                    let (_, _) = reply.read(&self.request_body, &mut vec![0; 1024]).unwrap();

                    // If the body is chunked, we need to send the end marker
                    if !self.request_body.is_empty()
                        && !self.request_body.ends_with(b"\r\n0\r\n\r\n")
                    {
                        let end_marker = b"0\r\n\r\n";
                        let (_, _) = reply.read(end_marker, &mut vec![0; 1024]).unwrap();
                    }

                    reply.proceed().unwrap()
                }
                _ => unreachable!("Expect: 100-continue header should lead to Send100"),
            }
        } else if !self.request_body.is_empty() {
            // If the request has a body, we need to go through RecvBody
            match reply.proceed().unwrap() {
                RecvRequestResult::RecvBody(mut reply) => {
                    // Write the request body and proceed to ProvideResponse
                    let (_, _) = reply.read(&self.request_body, &mut vec![0; 1024]).unwrap();

                    // If the body is chunked, we need to send the end marker
                    if !self.request_body.is_empty()
                        && !self.request_body.ends_with(b"\r\n0\r\n\r\n")
                    {
                        let end_marker = b"0\r\n\r\n";
                        let (_, _) = reply.read(end_marker, &mut vec![0; 1024]).unwrap();
                    }

                    reply.proceed().unwrap()
                }
                _ => unreachable!("Request with body should lead to RecvBody"),
            }
        } else {
            // Otherwise, proceed directly to ProvideResponse
            match reply.proceed().unwrap() {
                RecvRequestResult::ProvideResponse(reply) => reply,
                _ => unreachable!("Request without body should lead to ProvideResponse"),
            }
        }
    }

    pub fn to_send_response(&self) -> Reply<SendResponse> {
        // For tests that need a Reply in the SendResponse state, we'll create one directly
        let reply = self.to_provide_response();

        // Provide the response and proceed to SendResponse
        reply.provide(self.response.clone()).unwrap()
    }

    pub fn to_send_body(&self) -> Reply<SendBody> {
        // For tests that need a Reply in the SendBody state, we'll create one directly
        let mut reply = self.to_send_response();

        // Write the response headers and proceed to SendBody
        let mut output = vec![0; 1024];
        reply.write(&mut output).unwrap();

        match reply.proceed() {
            SendResponseResult::SendBody(reply) => reply,
            SendResponseResult::Cleanup(_) => {
                panic!(
                    "Expected SendBody variant, got Cleanup. This usually means the response doesn't need a body (e.g., HEAD request or 204 response)"
                )
            }
        }
    }

    pub fn to_cleanup(&self) -> Reply<Cleanup> {
        // For tests that need a Reply in the Cleanup state, we'll create one directly
        let mut reply = self.to_send_body();

        // Write the response body and proceed to Cleanup
        let mut output = vec![0; 1024];

        if !self.response_body.is_empty() {
            reply.write(&self.response_body, &mut output).unwrap();
        }

        // Send end marker
        reply.write(&[], &mut output).unwrap();

        reply.proceed()
    }
}

pub fn write_request(r: &Request<()>) -> Vec<u8> {
    let mut output = Vec::<u8>::new();

    write!(
        &mut output,
        "{} {} {:?}\r\n",
        r.method(),
        r.uri().path(),
        r.version()
    )
    .unwrap();

    for (k, v) in r.headers().iter() {
        write!(&mut output, "{}: {}\r\n", k.as_str(), v.to_str().unwrap()).unwrap();
    }

    write!(&mut output, "\r\n").unwrap();

    output
}

#[derive(Default)]
pub struct ScenarioBuilder<T> {
    request: Request<()>,
    request_body: Vec<u8>,
    response: Response<()>,
    response_body: Vec<u8>,
    _ph: PhantomData<T>,
}

pub struct WithReq(());
pub struct WithRes(());

#[allow(unused)]
impl ScenarioBuilder<()> {
    pub fn new() -> Self {
        Default::default()
    }

    pub fn request(self, request: Request<()>) -> ScenarioBuilder<WithReq> {
        ScenarioBuilder {
            request,
            request_body: vec![],
            response: Response::default(),
            response_body: vec![],
            _ph: PhantomData,
        }
    }

    pub fn method(self, method: Method, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::builder().method(method).uri(uri).body(()).unwrap())
    }

    pub fn get(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::get(uri).body(()).unwrap())
    }

    pub fn head(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::head(uri).body(()).unwrap())
    }

    pub fn post(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::post(uri).body(()).unwrap())
    }

    pub fn put(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::put(uri).body(()).unwrap())
    }

    pub fn options(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::options(uri).body(()).unwrap())
    }

    pub fn delete(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::delete(uri).body(()).unwrap())
    }

    pub fn trace(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::trace(uri).body(()).unwrap())
    }

    pub fn connect(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::connect(uri).body(()).unwrap())
    }

    pub fn patch(self, uri: &str) -> ScenarioBuilder<WithReq> {
        self.request(Request::patch(uri).body(()).unwrap())
    }
}

#[allow(unused)]
impl ScenarioBuilder<WithReq> {
    pub fn header(mut self, key: &'static str, value: impl ToString) -> Self {
        self.request
            .headers_mut()
            .append(key, value.to_string().try_into().unwrap());
        self
    }

    pub fn request_body<B: AsRef<[u8]>>(mut self, body: B, chunked: bool) -> Self {
        let body = body.as_ref().to_vec();
        let len = body.len();

        if chunked {
            // Format the body as chunked encoding
            let mut chunked_body = Vec::new();
            write!(&mut chunked_body, "{:x}\r\n", len).unwrap();
            chunked_body.extend_from_slice(&body);
            write!(&mut chunked_body, "\r\n0\r\n\r\n").unwrap();
            self.request_body = chunked_body;

            self.header("transfer-encoding", "chunked")
        } else {
            self.request_body = body;
            self.header("content-length", len.to_string())
        }
    }

    pub fn response(mut self, response: Response<()>) -> ScenarioBuilder<WithRes> {
        let ScenarioBuilder {
            request,
            request_body,
            response_body,
            ..
        } = self;

        ScenarioBuilder {
            request,
            request_body,
            response,
            response_body,
            _ph: PhantomData,
        }
    }

    pub fn build(self) -> Scenario {
        Scenario {
            request: self.request,
            request_body: self.request_body,
            response: Response::default(),
            response_body: vec![],
        }
    }
}

impl ScenarioBuilder<WithRes> {
    pub fn build(self) -> Scenario {
        Scenario {
            request: self.request,
            request_body: self.request_body,
            response: self.response,
            response_body: self.response_body,
        }
    }
}
