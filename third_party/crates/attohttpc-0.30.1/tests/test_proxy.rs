#![cfg(not(any(feature = "tls-rustls-webpki-roots-ring", feature = "tls-rustls-native-roots-ring")))]

mod tools;

use url::Url;

#[tokio::test(flavor = "multi_thread")]
async fn test_http_url_with_http_proxy() -> Result<(), anyhow::Error> {
    let remote_port = tools::start_hello_world_server(false).await?;
    let remote_url = format!("http://localhost:{remote_port}");

    let proxy_port = tools::start_proxy_server(false).await?;
    let proxy_url = Url::parse(&format!("http://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let resp = sess.get(remote_url).danger_accept_invalid_certs(true).send().unwrap();

    assert_eq!(resp.text().unwrap(), "hello");

    Ok(())
}

#[cfg(any(feature = "tls-native", feature = "__rustls"))]
#[tokio::test(flavor = "multi_thread")]
async fn test_http_url_with_https_proxy() -> Result<(), anyhow::Error> {
    let remote_port = tools::start_hello_world_server(false).await?;
    let remote_url = format!("http://localhost:{remote_port}");

    let proxy_port = tools::start_proxy_server(true).await?;
    let proxy_url = Url::parse(&format!("https://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let resp = sess.get(remote_url).danger_accept_invalid_certs(true).send().unwrap();

    assert_eq!(resp.text().unwrap(), "hello");

    Ok(())
}

#[cfg(any(feature = "tls-native", feature = "__rustls"))]
#[tokio::test(flavor = "multi_thread")]
async fn test_https_url_with_http_proxy() -> Result<(), anyhow::Error> {
    let remote_port = tools::start_hello_world_server(true).await?;
    let remote_url = format!("https://localhost:{remote_port}");

    let proxy_port = tools::start_proxy_server(false).await?;
    let proxy_url = Url::parse(&format!("http://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let resp = sess.get(remote_url).danger_accept_invalid_certs(true).send().unwrap();

    assert_eq!(resp.text().unwrap(), "hello");

    Ok(())
}

#[cfg(any(feature = "tls-native", feature = "__rustls"))]
#[tokio::test(flavor = "multi_thread")]
async fn test_https_url_with_https_proxy() -> Result<(), anyhow::Error> {
    let remote_port = tools::start_hello_world_server(true).await?;
    let remote_url = format!("https://localhost:{remote_port}");

    let proxy_port = tools::start_proxy_server(true).await?;
    let proxy_url = Url::parse(&format!("https://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let resp = sess.get(remote_url).danger_accept_invalid_certs(true).send().unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    assert_eq!(resp.text().unwrap(), "hello");

    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn test_http_url_with_http_proxy_refusal() -> Result<(), anyhow::Error> {
    let proxy_port = tools::start_refusing_proxy_server(false).await?;
    let proxy_url = Url::parse(&format!("http://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let resp = sess
        .get("http://localhost")
        .danger_accept_invalid_certs(true)
        .send()
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    assert_eq!(resp.text().unwrap(), "bad request");

    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn test_https_url_with_http_proxy_refusal() -> Result<(), anyhow::Error> {
    let proxy_port = tools::start_refusing_proxy_server(false).await?;
    let proxy_url = Url::parse(&format!("http://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let res = sess.get("https://localhost").danger_accept_invalid_certs(true).send();

    let err = res.err().unwrap();
    match err.kind() {
        attohttpc::ErrorKind::ConnectError { status_code, body } => {
            assert_eq!(status_code.as_u16(), 400);
            assert_eq!(body, b"bad request");
        }
        _ => panic!("wrong error"),
    }

    Ok(())
}

#[cfg(any(feature = "tls-native", feature = "__rustls"))]
#[tokio::test(flavor = "multi_thread")]
async fn test_http_url_with_https_proxy_refusal() -> Result<(), anyhow::Error> {
    let proxy_port = tools::start_refusing_proxy_server(true).await?;
    let proxy_url = Url::parse(&format!("https://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let resp = sess
        .get("http://localhost")
        .danger_accept_invalid_certs(true)
        .send()
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    assert_eq!(resp.text().unwrap(), "bad request");

    Ok(())
}

#[cfg(any(feature = "tls-native", feature = "__rustls"))]
#[tokio::test(flavor = "multi_thread")]
async fn test_https_url_with_https_proxy_refusal() -> Result<(), anyhow::Error> {
    let proxy_port = tools::start_refusing_proxy_server(true).await?;
    let proxy_url = Url::parse(&format!("https://localhost:{proxy_port}")).unwrap();

    let settings = attohttpc::ProxySettingsBuilder::new()
        .http_proxy(proxy_url.clone())
        .https_proxy(proxy_url)
        .build();

    let mut sess = attohttpc::Session::new();
    sess.proxy_settings(settings);

    let res = sess.get("https://localhost").danger_accept_invalid_certs(true).send();

    let err = res.err().unwrap();
    match err.kind() {
        attohttpc::ErrorKind::ConnectError { status_code, body } => {
            assert_eq!(status_code.as_u16(), 400);
            assert_eq!(body, b"bad request");
        }
        _ => panic!("wrong error: {}", err),
    }

    Ok(())
}
