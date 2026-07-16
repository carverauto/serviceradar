use super::scenario::Scenario;

#[test]
fn proceed_without_amended_headers() {
    let scenario = Scenario::builder().get("https://q.test").build();

    let call = scenario.to_prepare();

    let inner = call.inner();
    let request = &inner.request;

    assert_eq!(request.headers_vec(), []);

    call.proceed();
}

#[test]
fn proceed_with_amended_headers() {
    let scenario = Scenario::builder().get("https://q.test").build();

    let mut call = scenario.to_prepare();

    call.header("Cookie", "name=bar").unwrap();
    call.header("Cookie", "name2=baz").unwrap();

    let inner = call.inner();
    let request = &inner.request;

    assert_eq!(
        request.headers_vec(),
        [
            //
            ("cookie", "name=bar"),
            ("cookie", "name2=baz"),
        ]
    );

    call.proceed();
}
