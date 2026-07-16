mod scenario;

mod state_prepare;

mod state_send_request;

mod state_send_body;

mod state_recv_response;

mod state_await_100;

mod state_recv_body;

mod state_redirect;

mod state_cleanup;

trait TestSliceExt {
    fn as_str(&self) -> &str;
}

impl TestSliceExt for [u8] {
    fn as_str(&self) -> &str {
        std::str::from_utf8(self).unwrap()
    }
}
