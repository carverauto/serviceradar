use std::io::Write;
use std::marker::PhantomData;

use http::{Method, Request, Response, StatusCode};

use crate::client::state::{
    Await100, Cleanup, Prepare, RecvBody, RecvResponse, Redirect, SendBody, SendRequest,
};
use crate::client::{Await100Result, Call, SendRequestResult};
use crate::client::{RecvBodyResult, RecvResponseResult};

pub struct Scenario {
    request: Request<()>,
    headers_amend: Vec<(String, String)>,
    send_body: Vec<u8>,
    response: Response<()>,
    recv_body: Vec<u8>,
}

impl Scenario {
    pub fn builder() -> ScenarioBuilder<()> {
        ScenarioBuilder::new()
    }
}

impl Scenario {
    pub fn to_prepare(&self) -> Call<Prepare> {
        // The unwraps here are ok because the user is not supposed to
        // construct tests that test the Scenario builder itself.
        let mut call = Call::new(self.request.clone()).unwrap();

        for (key, value) in &self.headers_amend {
            call.header(key, value).unwrap();
        }

        call
    }

    pub fn to_send_request(&self) -> Call<SendRequest> {
        let call = self.to_prepare();

        call.proceed()
    }

    pub fn to_send_body(&self) -> Call<SendBody> {
        let mut call = self.to_send_request();

        // Write the prelude and discard
        call.write(&mut vec![0; 1024]).unwrap();

        match call.proceed() {
            Ok(Some(SendRequestResult::SendBody(v))) => v,
            _ => unreachable!("Incorrect scenario not leading to_send_body()"),
        }
    }

    pub fn to_await_100(&self) -> Call<Await100> {
        let mut call = self.to_send_request();

        // Write the prelude and discard
        call.write(&mut vec![0; 1024]).unwrap();

        match call.proceed() {
            Ok(Some(SendRequestResult::Await100(v))) => v,
            _ => unreachable!("Incorrect scenario not leading to_await_100()"),
        }
    }

    pub fn to_recv_response(&self) -> Call<RecvResponse> {
        let mut call = self.to_send_request();

        // Write the prelude and discard
        call.write(&mut vec![0; 1024]).unwrap();

        if call.inner().state.writer.has_body() {
            let mut call = if call.inner().await_100_continue {
                // Go via Await100
                let call = match call.proceed() {
                    Ok(Some(SendRequestResult::Await100(v))) => v,
                    _ => unreachable!(),
                };

                // Proceed straight out of Await100
                match call.proceed() {
                    Ok(Await100Result::SendBody(v)) => v,
                    _ => unreachable!(),
                }
            } else {
                match call.proceed() {
                    Ok(Some(SendRequestResult::SendBody(v))) => v,
                    _ => unreachable!(),
                }
            };

            let mut input = &self.send_body[..];
            let mut output = vec![0; 1024];

            while !input.is_empty() {
                let (input_used, _) = call.write(input, &mut output).unwrap();
                input = &input[input_used..];
            }

            call.write(&[], &mut output).unwrap();

            call.proceed().unwrap()
        } else {
            match call.proceed() {
                Ok(Some(SendRequestResult::RecvResponse(v))) => v,
                _ => unreachable!(),
            }
        }
    }

    pub fn to_recv_body(&self) -> Call<RecvBody> {
        let mut call = self.to_recv_response();

        let input = write_response(&self.response);

        // use crate::client::test::TestSliceExt;
        // println!("{:?}", input.as_slice().as_str());

        call.try_response(&input, true).unwrap();

        match call.proceed() {
            Some(RecvResponseResult::RecvBody(v)) => v,
            _ => unreachable!("Incorrect scenario not leading to_recv_body()"),
        }
    }

    pub fn to_redirect(&self) -> Call<Redirect> {
        let mut call = self.to_recv_response();

        let input = write_response(&self.response);

        call.try_response(&input, true).unwrap();

        match call.proceed().unwrap() {
            RecvResponseResult::Redirect(v) => v,
            RecvResponseResult::RecvBody(mut state) => {
                let mut output = vec![0; 1024];

                state.read(&self.recv_body, &mut output).unwrap();

                match state.proceed() {
                    Some(RecvBodyResult::Redirect(v)) => v,
                    _ => unreachable!("Incorrect scenario not leading to_redirect()"),
                }
            }
            _ => unreachable!("Incorrect scenario not leading to_redirect()"),
        }
    }

    pub fn to_cleanup(&self) -> Call<Cleanup> {
        let mut call = self.to_recv_response();

        let input = write_response(&self.response);

        call.try_response(&input, true).unwrap();

        match call.proceed().unwrap() {
            RecvResponseResult::Redirect(v) => v.proceed(),
            RecvResponseResult::RecvBody(mut call) => {
                let mut output = vec![0; 1024];

                call.read(&self.recv_body, &mut output).unwrap();

                match call.proceed() {
                    Some(RecvBodyResult::Redirect(v)) => v.proceed(),
                    Some(RecvBodyResult::Cleanup(v)) => v,
                    _ => unreachable!("Incorrect scenario not leading to_redirect()"),
                }
            }
            RecvResponseResult::Cleanup(v) => v,
        }
    }
}

pub fn write_response(r: &Response<()>) -> Vec<u8> {
    let mut input = Vec::<u8>::new();

    let s = r.status();

    write!(
        &mut input,
        "{:?} {} {}\r\n",
        r.version(),
        s.as_u16(),
        s.canonical_reason().unwrap()
    )
    .unwrap();

    for (k, v) in r.headers().iter() {
        write!(&mut input, "{}: {}\r\n", k.as_str(), v.to_str().unwrap()).unwrap();
    }

    write!(&mut input, "\r\n").unwrap();

    input
}

#[derive(Default)]
pub struct ScenarioBuilder<T> {
    request: Request<()>,
    headers_amend: Vec<(String, String)>,
    send_body: Vec<u8>,
    response: Response<()>,
    recv_body: Vec<u8>,
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
            headers_amend: self.headers_amend,
            send_body: vec![],
            response: Response::default(),
            recv_body: vec![],
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

    pub fn send_body<B: AsRef<[u8]>>(mut self, body: B, chunked: bool) -> Self {
        let body = body.as_ref().to_vec();
        let len = body.len();
        self.send_body = body;

        let (k, v) = if chunked {
            ("transfer-encoding".to_string(), "chunked".to_string())
        } else {
            ("content-length".to_string(), len.to_string())
        };

        self.headers_amend.push((k, v));

        self
    }

    pub fn redirect(self, status: StatusCode, location: &str) -> ScenarioBuilder<WithRes> {
        let r = Response::builder()
            .status(status)
            .header("location", location)
            .body(())
            .unwrap();
        self.response(r)
    }

    pub fn response(mut self, response: Response<()>) -> ScenarioBuilder<WithRes> {
        let ScenarioBuilder {
            request,
            headers_amend,
            send_body,
            recv_body,
            ..
        } = self;

        ScenarioBuilder {
            request,
            headers_amend,
            send_body,
            response,
            recv_body,
            _ph: PhantomData,
        }
    }

    pub fn build(self) -> Scenario {
        Scenario {
            request: self.request,
            send_body: self.send_body,
            headers_amend: self.headers_amend,
            response: self.response,
            recv_body: self.recv_body,
        }
    }
}

impl ScenarioBuilder<WithRes> {
    pub fn recv_body<B: AsRef<[u8]>>(mut self, body: B, chunked: bool) -> Self {
        let body = body.as_ref().to_vec();
        let len = body.len();
        self.recv_body = body;

        let (k, v) = if chunked {
            ("transfer-encoding", "chunked".to_string())
        } else {
            ("content-length", len.to_string())
        };

        self.response.headers_mut().append(k, v.try_into().unwrap());

        self
    }

    pub fn build(self) -> Scenario {
        Scenario {
            request: self.request,
            send_body: self.send_body,
            headers_amend: self.headers_amend,
            response: self.response,
            recv_body: self.recv_body,
        }
    }
}
