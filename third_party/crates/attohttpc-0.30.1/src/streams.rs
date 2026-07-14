#[cfg(test)]
use std::io::Cursor;
use std::io::{self, Read, Write};
#[cfg(not(windows))]
#[cfg(not(feature = "single-threaded"))]
use std::net::Shutdown;
use std::net::TcpStream;
#[cfg(windows)]
use std::os::{
    raw::c_int,
    windows::{io::AsRawSocket, raw::SOCKET},
};
use std::sync::mpsc;
#[cfg(not(feature = "single-threaded"))]
use std::thread;
use std::time::Instant;

use base64::Engine;

use url::{Host, Url};

use crate::happy;
use crate::parsing::buffers::BufReaderWrite;
use crate::parsing::response::parse_response_head;
use crate::request::BaseSettings;
use crate::tls::{TlsHandshaker, TlsStream};
use crate::{ErrorKind, Result};

pub struct ConnectInfo<'a> {
    pub url: &'a Url,
    pub proxy: Option<&'a Url>,
    pub base_settings: &'a BaseSettings,
    pub deadline: Option<Instant>,
}

#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum BaseStream {
    Plain {
        stream: TcpStream,
        timeout: Option<mpsc::Sender<()>>,
    },
    Tls {
        stream: TlsStream<TcpStream>,
        timeout: Option<mpsc::Sender<()>>,
    },
    Tunnel {
        stream: Box<TlsStream<BufReaderWrite<BaseStream>>>,
    },
    #[cfg(test)]
    Mock(Cursor<Vec<u8>>),
}

impl BaseStream {
    pub fn connect(info: &ConnectInfo) -> Result<BaseStream> {
        let connect_url = info.proxy.unwrap_or(info.url);

        let host = connect_url.host().ok_or(ErrorKind::InvalidUrlHost)?;
        let port = connect_url.port_or_known_default().ok_or(ErrorKind::InvalidUrlPort)?;

        debug!("trying to connect to {}:{}", host, port);

        let stream = match connect_url.scheme() {
            "http" => BaseStream::connect_tcp(&host, port, info)
                .map(|(stream, timeout)| BaseStream::Plain { stream, timeout }),
            "https" => BaseStream::connect_tls(&host, port, info),
            _ => Err(ErrorKind::InvalidBaseUrl.into()),
        }?;

        if let Some(proxy_url) = info.proxy {
            if info.url.scheme() == "https" {
                return BaseStream::initiate_tunnel(stream, proxy_url, info.url, info.base_settings);
            }
        }

        Ok(stream)
    }

    fn initiate_tunnel(
        mut stream: BaseStream,
        proxy_url: &Url,
        remote_url: &Url,
        base_settings: &BaseSettings,
    ) -> Result<BaseStream> {
        let remote_host = remote_url.host_str().ok_or(ErrorKind::InvalidUrlHost)?;
        let remote_port = remote_url.port_or_known_default().ok_or(ErrorKind::InvalidUrlPort)?;
        let proxy_host = proxy_url.host_str().ok_or(ErrorKind::InvalidUrlHost)?;
        let proxy_port = proxy_url.port_or_known_default().ok_or(ErrorKind::InvalidUrlPort)?;

        debug!(
            "tunnelling to {}:{} via {}:{}",
            remote_host, remote_port, proxy_host, proxy_port,
        );

        write!(stream, "CONNECT {remote_host}:{remote_port} HTTP/1.1\r\n")?;
        write!(stream, "Host: {proxy_host}:{proxy_port}\r\n")?;
        write!(stream, "Connection: close\r\n")?;
        if proxy_url.has_authority() {
            let username = proxy_url.username();
            let auth = match proxy_url.password() {
                Some(password) => format!("{username}:{password}"),
                None => format!("{username}:"),
            };
            let basic_auth = base64::engine::general_purpose::STANDARD.encode(auth);
            write!(stream, "Proxy-Authorization: Basic {basic_auth}\r\n")?;
        }
        write!(stream, "\r\n")?;

        let mut stream = BufReaderWrite::new(stream);
        let (status, _) = parse_response_head(&mut stream, base_settings.max_headers)?;

        debug!("tunnel response status code is {}", status);

        if !status.is_success() {
            // Error initializaing tunnel, get status code and up to 10 KiB of data from the body.
            let mut buf = Vec::with_capacity(2048);
            stream.take(10 * 1024).read_to_end(&mut buf)?;
            let err = ErrorKind::ConnectError {
                status_code: status,
                body: buf,
            };
            return Err(err.into());
        }

        let mut handshaker = TlsHandshaker::new();
        apply_base_settings(&mut handshaker, base_settings);
        let stream = handshaker.handshake(remote_host, stream)?;

        Ok(BaseStream::Tunnel {
            stream: Box::new(stream),
        })
    }

    fn connect_tcp(host: &Host<&str>, port: u16, info: &ConnectInfo) -> Result<(TcpStream, Option<mpsc::Sender<()>>)> {
        let stream = happy::connect(host, port, info.base_settings.connect_timeout, info.deadline)?;
        #[cfg(not(target_os = "wasi"))]
        stream.set_read_timeout(Some(info.base_settings.read_timeout))?;
        #[cfg(not(feature = "single-threaded"))]
        let timeout = info
            .deadline
            .map(|deadline| -> Result<mpsc::Sender<()>> {
                #[cfg(not(windows))]
                let stream = stream.try_clone()?;
                #[cfg(windows)]
                let socket = stream.as_raw_socket();

                let (tx, rx) = mpsc::channel();
                thread::spawn(move || {
                    let shutdown = match deadline.checked_duration_since(Instant::now()) {
                        Some(timeout) => rx.recv_timeout(timeout) == Err(mpsc::RecvTimeoutError::Timeout),
                        None => rx.try_recv() == Err(mpsc::TryRecvError::Empty),
                    };

                    if shutdown {
                        drop(rx);

                        #[cfg(not(windows))]
                        let _ = stream.shutdown(Shutdown::Both);

                        #[cfg(windows)]
                        extern "system" {
                            fn closesocket(socket: SOCKET) -> c_int;
                        }

                        #[cfg(windows)]
                        unsafe {
                            closesocket(socket);
                        }
                    }
                });
                Ok(tx)
            })
            .transpose()?;
        #[cfg(feature = "single-threaded")]
        let timeout: Option<mpsc::Sender<()>> = None;
        Ok((stream, timeout))
    }

    fn connect_tls(host: &Host<&str>, port: u16, info: &ConnectInfo) -> Result<BaseStream> {
        let (stream, timeout) = BaseStream::connect_tcp(host, port, info)?;
        let mut handshaker = TlsHandshaker::new();
        apply_base_settings(&mut handshaker, info.base_settings);
        let stream = handshaker.handshake(&host.to_string(), stream)?;
        Ok(BaseStream::Tls { stream, timeout })
    }

    #[cfg(test)]
    pub fn mock(bytes: Vec<u8>) -> BaseStream {
        BaseStream::Mock(Cursor::new(bytes))
    }
}

impl Read for BaseStream {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            BaseStream::Plain { stream, timeout } => read_timeout(stream, buf, timeout),
            BaseStream::Tls { stream, timeout } => read_timeout(stream, buf, timeout),
            BaseStream::Tunnel { stream } => stream.read(buf),
            #[cfg(test)]
            BaseStream::Mock(s) => s.read(buf),
        }
    }
}

impl Write for BaseStream {
    #[inline]
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            BaseStream::Plain { stream, .. } => stream.write(buf),
            BaseStream::Tls { stream, .. } => stream.write(buf),
            BaseStream::Tunnel { stream } => stream.write(buf),
            #[cfg(test)]
            _ => Ok(0),
        }
    }

    #[inline]
    fn flush(&mut self) -> io::Result<()> {
        match self {
            BaseStream::Plain { stream, .. } => stream.flush(),
            BaseStream::Tls { stream, .. } => stream.flush(),
            BaseStream::Tunnel { stream } => stream.flush(),
            #[cfg(test)]
            _ => Ok(()),
        }
    }
}

fn read_timeout(stream: &mut impl Read, buf: &mut [u8], timeout: &Option<mpsc::Sender<()>>) -> io::Result<usize> {
    match stream.read(buf) {
        Ok(0) => {
            #[cfg(unix)]
            if let Some(timeout) = timeout {
                // On Unix we get a 0 read when the connection is shutdown by the timeout thread.
                if !buf.is_empty() && timeout.send(()).is_err() {
                    return Err(io::ErrorKind::TimedOut.into());
                }
            }
            Ok(0)
        }
        Ok(read) => Ok(read),
        Err(err) => {
            #[cfg(windows)]
            if let Some(timeout) = timeout {
                // On Windows we get a ConnectionAborted when the connection is shutdown by the timeout thread.
                if err.kind() == io::ErrorKind::ConnectionAborted && timeout.send(()).is_err() {
                    return Err(io::ErrorKind::TimedOut.into());
                }
            }
            Err(err)
        }
    }
}

fn apply_base_settings(handshaker: &mut TlsHandshaker, base_settings: &BaseSettings) {
    handshaker.danger_accept_invalid_certs(base_settings.accept_invalid_certs);
    handshaker.danger_accept_invalid_hostnames(base_settings.accept_invalid_hostnames);
    for cert in &base_settings.root_certificates.0 {
        handshaker.add_root_certificate(cert.clone());
    }
}
