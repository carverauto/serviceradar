use http::{Method, Response, StatusCode, header};

use crate::Error;
use crate::client::RedirectAuthHeaders;
use crate::client::test::TestSliceExt;

use super::scenario::Scenario;

#[test]
fn without_recv_body() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .redirect(StatusCode::FOUND, "https://b.test")
        .build();

    scenario.to_redirect();
}

#[test]
fn with_recv_body() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .redirect(StatusCode::FOUND, "https://b.test")
        .recv_body(b"hi there", false)
        .build();

    scenario.to_redirect();
}

#[test]
#[should_panic]
fn with_recv_body_0() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .redirect(StatusCode::FOUND, "https://b.test")
        .recv_body(b"", false)
        .build();

    scenario.to_recv_body();
}

#[test]
fn absolute_url() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .redirect(StatusCode::FOUND, "https://b.test")
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://b.test/");
}

#[test]
fn relative_url_absolute_path() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .redirect(StatusCode::FOUND, "/foo.html")
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://a.test/foo.html");
}

#[test]
fn relative_url_relative_path() {
    let scenario = Scenario::builder()
        .get("https://a.test/x/foo.html")
        .redirect(StatusCode::FOUND, "y/bar.html")
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://a.test/x/y/bar.html");
}

#[test]
fn relative_url_parent_relative() {
    let scenario = Scenario::builder()
        .get("https://a.test/x/foo.html")
        .redirect(StatusCode::FOUND, "../bar.html")
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://a.test/bar.html");
}

#[test]
fn relative_url_dot_relative() {
    let scenario = Scenario::builder()
        .get("https://a.test/x/foo.html")
        .redirect(StatusCode::FOUND, "./bar.html")
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://a.test/x/bar.html");
}

#[test]
fn relative_url_dot_dotdot_relative() {
    let scenario = Scenario::builder()
        .get("https://a.test/x/foo.html")
        .redirect(StatusCode::FOUND, "./../bar.html")
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://a.test/bar.html");
}

#[test]
fn relative_url_parent_overflow_relative() {
    let scenario = Scenario::builder()
        .get("https://a.test/x/foo.html")
        .redirect(StatusCode::FOUND, "../../bar.html")
        .build();

    let error = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap_err();

    assert_eq!(
        error,
        Error::BadLocationHeader("../../bar.html".to_string())
    );
}

#[test]
fn last_location_header() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .response(
            Response::builder()
                .status(StatusCode::MOVED_PERMANENTLY)
                .header("location", "https://b.test")
                .header("location", "https://c.test")
                .header("location", "https://d.test")
                .header("location", "https://e.test")
                .body(())
                .unwrap(),
        )
        .build();

    let call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    assert_eq!(&call.uri().to_string(), "https://e.test/");
}

#[test]
fn change_redirect_methods() {
    const METHOD_CHANGES: &[(StatusCode, &[(Method, Option<Method>)])] = &[
        (
            StatusCode::FOUND,
            &[
                (Method::GET, Some(Method::GET)),
                (Method::HEAD, Some(Method::HEAD)),
                (Method::POST, Some(Method::GET)),
                (Method::PUT, Some(Method::GET)),
                (Method::PATCH, Some(Method::GET)),
                (Method::DELETE, Some(Method::GET)),
                (Method::OPTIONS, Some(Method::GET)),
                (Method::CONNECT, Some(Method::GET)),
                (Method::TRACE, Some(Method::GET)),
            ],
        ),
        (
            StatusCode::MOVED_PERMANENTLY,
            &[
                (Method::GET, Some(Method::GET)),
                (Method::HEAD, Some(Method::HEAD)),
                (Method::POST, Some(Method::GET)),
                (Method::PUT, Some(Method::GET)),
                (Method::PATCH, Some(Method::GET)),
                (Method::DELETE, Some(Method::GET)),
                (Method::OPTIONS, Some(Method::GET)),
                (Method::CONNECT, Some(Method::GET)),
                (Method::TRACE, Some(Method::GET)),
            ],
        ),
        (
            StatusCode::TEMPORARY_REDIRECT,
            &[
                (Method::GET, Some(Method::GET)),
                (Method::HEAD, Some(Method::HEAD)),
                (Method::POST, None),
                (Method::PUT, None),
                (Method::PATCH, None),
                (Method::DELETE, None),
                (Method::OPTIONS, Some(Method::OPTIONS)),
                (Method::CONNECT, Some(Method::CONNECT)),
                (Method::TRACE, Some(Method::TRACE)),
            ],
        ),
        (
            StatusCode::PERMANENT_REDIRECT,
            &[
                (Method::GET, Some(Method::GET)),
                (Method::HEAD, Some(Method::HEAD)),
                (Method::POST, None),
                (Method::PUT, None),
                (Method::PATCH, None),
                (Method::DELETE, None),
                (Method::OPTIONS, Some(Method::OPTIONS)),
                (Method::CONNECT, Some(Method::CONNECT)),
                (Method::TRACE, Some(Method::TRACE)),
            ],
        ),
    ];

    for (status, methods) in METHOD_CHANGES {
        for (method_from, method_to) in methods.iter() {
            let scenario = Scenario::builder()
                .method(method_from.clone(), "https://a.test")
                .redirect(*status, "https://b.test")
                .build();

            let maybe_state = scenario
                .to_redirect()
                .as_new_call(RedirectAuthHeaders::Never)
                .unwrap();
            if let Some(state) = maybe_state {
                let inner = state.inner();
                let method = inner.request.method();
                assert_eq!(
                    method,
                    method_to.clone().unwrap(),
                    "{} {} -> {:?}",
                    status,
                    method_from,
                    method_to
                );
            } else {
                assert!(method_to.is_none());
            }
        }
    }
}

#[test]
fn keep_auth_header_never() {
    let scenario = Scenario::builder()
        .get("https://a.test/foo")
        .header("authorization", "some secret")
        .redirect(StatusCode::FOUND, "https://a.test/bar")
        .build();

    let mut call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap()
        .proceed();

    let mut o = vec![0; 1024];

    let n = call.write(&mut o).unwrap();

    let cmp = "\
            GET /bar HTTP/1.1\r\n\
            host: a.test\r\n\
            \r\n";
    assert_eq!(o[..n].as_str(), cmp);
}

#[test]
fn keep_auth_header_same_host() {
    let scenario = Scenario::builder()
        .get("https://a.test:123/foo")
        .header("authorization", "some secret")
        .redirect(StatusCode::FOUND, "https://a.test:234/bar")
        .build();

    let mut call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::SameHost)
        .unwrap()
        .unwrap()
        .proceed();

    let mut o = vec![0; 1024];

    let n = call.write(&mut o).unwrap();

    let cmp = "\
            GET /bar HTTP/1.1\r\n\
            host: a.test:234\r\n\
            authorization: some secret\r\n\
            \r\n";
    assert_eq!(o[..n].as_str(), cmp);
}

#[test]
fn dont_keep_auth_header_different_host() {
    let scenario = Scenario::builder()
        .get("https://a.test/foo")
        .header("authorization", "some secret")
        .redirect(StatusCode::FOUND, "https://b.test/bar")
        .build();

    let mut call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::SameHost)
        .unwrap()
        .unwrap()
        .proceed();

    let mut o = vec![0; 1024];

    let n = call.write(&mut o).unwrap();

    let cmp = "\
            GET /bar HTTP/1.1\r\n\
            host: b.test\r\n\
            \r\n";
    assert_eq!(o[..n].as_str(), cmp);
}

#[test]
fn dont_keep_cookie_header() {
    let scenario = Scenario::builder()
        .get("https://a.test/foo")
        .header("x-my", "ya")
        .header("cookie", "secret=value")
        .redirect(StatusCode::FOUND, "https://b.test/bar")
        .build();

    let mut call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::SameHost)
        .unwrap()
        .unwrap()
        .proceed();

    let mut o = vec![0; 1024];

    let n = call.write(&mut o).unwrap();

    let cmp = "\
            GET /bar HTTP/1.1\r\n\
            host: b.test\r\n\
            x-my: ya\r\n\
            \r\n";
    assert_eq!(o[..n].as_str(), cmp);
}

#[test]
fn dont_keep_content_length() {
    let scenario = Scenario::builder()
        .post("https://a.test/foo")
        .header("x-my", "ya")
        .send_body("123", false)
        .redirect(StatusCode::FOUND, "https://b.test/bar")
        .build();

    let mut call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::SameHost)
        .unwrap()
        .unwrap()
        .proceed();

    let mut o = vec![0; 1024];

    let n = call.write(&mut o).unwrap();

    let cmp = "\
            GET /bar HTTP/1.1\r\n\
            host: b.test\r\n\
            x-my: ya\r\n\
            \r\n";
    assert_eq!(o[..n].as_str(), cmp);
}

#[test]
fn can_set_cookie_on_redirected_request() {
    let scenario = Scenario::builder()
        .get("https://a.test")
        .header("cookie", "not redirected")
        .redirect(StatusCode::FOUND, "https://b.test")
        .build();

    let mut call = scenario
        .to_redirect()
        .as_new_call(RedirectAuthHeaders::Never)
        .unwrap()
        .unwrap();

    call.header(header::COOKIE, "hello").unwrap();

    let mut call = call.proceed();

    let mut o = vec![0; 1024];

    let n = call.write(&mut o).unwrap();

    let cmp = "\
            GET / HTTP/1.1\r\n\
            cookie: hello\r\n\
            host: b.test\r\n\
            \r\n";
    assert_eq!(o[..n].as_str(), cmp);
}
