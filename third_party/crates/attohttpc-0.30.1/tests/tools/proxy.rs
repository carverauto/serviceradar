// This code has been taken from the hyper project and slightly modified: https://github.com/hyperium/hyper/blob/master/examples/http_proxy.rs
// It's needed to create a proxy server for testing.

use axum_server::tls_rustls::RustlsConfig;
use bytes::Bytes;
use http::{Method, Request, Response};
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Empty, Full};
use hyper::client::conn::http1::Builder as ClientBuilder;
use hyper::service::service_fn;
use hyper::upgrade::Upgraded;
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder;
use std::net::SocketAddr;
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsAcceptor;

pub async fn start_proxy_server(tls: bool) -> anyhow::Result<u16> {
    create_proxy(tls, false).await
}

pub async fn start_refusing_proxy_server(tls: bool) -> anyhow::Result<u16> {
    create_proxy(tls, true).await
}

// Code below is derived from these examples:
// Hyper proxy: https://github.com/hyperium/hyper/blob/master/examples/http_proxy.rs
// Hyper TLS server: https://github.com/rustls/hyper-rustls/blob/main/examples/server.rs

async fn proxy_allow(
    req: Request<hyper::body::Incoming>,
) -> Result<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error> {
    if Method::CONNECT == req.method() {
        if let Some(addr) = host_addr(req.uri()) {
            tokio::task::spawn(async move {
                match hyper::upgrade::on(req).await {
                    Ok(upgraded) => {
                        if let Err(e) = tunnel(upgraded, addr).await {
                            eprintln!("server io error: {}", e);
                        };
                    }
                    Err(e) => eprintln!("upgrade error: {}", e),
                }
            });

            Ok(Response::new(empty()))
        } else {
            eprintln!("CONNECT host is not socket addr: {:?}", req.uri());
            let mut resp = Response::new(full("CONNECT must be to a socket address"));
            *resp.status_mut() = http::StatusCode::BAD_REQUEST;
            Ok(resp)
        }
    } else {
        let host = req.uri().host().expect("uri has no host");
        let port = req.uri().port_u16().unwrap_or(80);

        let stream = TcpStream::connect((host, port)).await.unwrap();
        let io = TokioIo::new(stream);

        let (mut sender, conn) = ClientBuilder::new()
            .preserve_header_case(true)
            .title_case_headers(true)
            .handshake(io)
            .await?;
        tokio::task::spawn(async move {
            if let Err(err) = conn.await {
                println!("Connection failed: {:?}", err);
            }
        });

        let resp = sender.send_request(req).await?;
        Ok(resp.map(|b| b.boxed()))
    }
}

async fn proxy_deny(
    _req: Request<hyper::body::Incoming>,
) -> Result<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error> {
    let mut resp = Response::new(full("bad request"));
    *resp.status_mut() = http::StatusCode::BAD_REQUEST;
    Ok(resp)
}

fn host_addr(uri: &http::Uri) -> Option<String> {
    uri.authority().map(|auth| auth.to_string())
}

fn empty() -> BoxBody<Bytes, hyper::Error> {
    Empty::<Bytes>::new().map_err(|never| match never {}).boxed()
}

fn full<T: Into<Bytes>>(chunk: T) -> BoxBody<Bytes, hyper::Error> {
    Full::new(chunk.into()).map_err(|never| match never {}).boxed()
}

async fn tunnel(upgraded: Upgraded, addr: String) -> std::io::Result<()> {
    let mut server = TcpStream::connect(addr).await?;
    let mut upgraded = TokioIo::new(upgraded);
    tokio::io::copy_bidirectional(&mut upgraded, &mut server).await?;
    Ok(())
}

async fn create_proxy(tls: bool, deny: bool) -> anyhow::Result<u16> {
    let addr = SocketAddr::from(([127, 0, 0, 1], 0));
    let listener = TcpListener::bind(addr).await?;
    let port = listener.local_addr().unwrap().port();

    if tls {
        let config = RustlsConfig::from_pem(include_bytes!("cert.pem").to_vec(), include_bytes!("key.pem").to_vec())
            .await
            .unwrap();
        let tls_acceptor = TlsAcceptor::from(config.get_inner());

        tokio::spawn(async move {
            loop {
                let (tcp_stream, _remote_addr) = listener.accept().await.unwrap();
                let tls_acceptor = tls_acceptor.clone();
                tokio::spawn(async move {
                    let tls_stream = match tls_acceptor.accept(tcp_stream).await {
                        Ok(tls_stream) => tls_stream,
                        Err(err) => {
                            eprintln!("failed to perform tls handshake: {err:#}");
                            return;
                        }
                    };
                    if let Err(err) = Builder::new(TokioExecutor::new())
                        .serve_connection_with_upgrades(
                            TokioIo::new(tls_stream),
                            service_fn(move |req| async move {
                                match deny {
                                    true => proxy_deny(req).await,
                                    false => proxy_allow(req).await,
                                }
                            }),
                        )
                        .await
                    {
                        eprintln!("failed to serve connection: {err:#}");
                    }
                });
            }
        });
    } else {
        tokio::spawn(async move {
            loop {
                let (tcp_stream, _remote_addr) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    if let Err(err) = Builder::new(TokioExecutor::new())
                        .serve_connection_with_upgrades(
                            TokioIo::new(tcp_stream),
                            service_fn(move |req| async move {
                                match deny {
                                    true => proxy_deny(req).await,
                                    false => proxy_allow(req).await,
                                }
                            }),
                        )
                        .await
                    {
                        eprintln!("failed to serve connection: {err:#}");
                    }
                });
            }
        });
    }

    Ok(port)
}
