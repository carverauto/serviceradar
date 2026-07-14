use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    num::Wrapping,
};

use crate::{
    pdu::{self, Pdu},
    Error, MessageType, Oid, Result, Value, Version, BUFFER_SIZE,
};
use tokio::net::{lookup_host, ToSocketAddrs, UdpSocket};

#[cfg(feature = "v3")]
use crate::v3;

/// Asynchronous SNMP client
pub struct AsyncSession {
    version: Version,
    socket: UdpSocket,
    community: Vec<u8>,
    req_id: Wrapping<i32>,
    send_pdu: pdu::Buf,
    #[cfg(not(feature = "heap_buffers"))]
    recv_buf: [u8; BUFFER_SIZE],
    #[cfg(feature = "heap_buffers")]
    recv_buf: Box<[u8]>,
    #[cfg(feature = "v3")]
    security: Option<v3::Security>,
}

impl AsyncSession {
    pub async fn new_v1<SA>(
        destination: SA,
        community: &[u8],
        starting_req_id: i32,
    ) -> io::Result<Self>
    where
        SA: ToSocketAddrs,
    {
        Self::new(Version::V1, destination, community, starting_req_id).await
    }

    pub async fn new_v2c<SA>(
        destination: SA,
        community: &[u8],
        starting_req_id: i32,
    ) -> io::Result<Self>
    where
        SA: ToSocketAddrs,
    {
        Self::new(Version::V2C, destination, community, starting_req_id).await
    }

    #[cfg(feature = "v3")]
    pub async fn new_v3<SA>(
        destination: SA,
        starting_req_id: i32,
        security: v3::Security,
    ) -> io::Result<Self>
    where
        SA: ToSocketAddrs,
    {
        let mut session = Self::new(Version::V3, destination, &[], starting_req_id).await?;
        session.community.clone_from(&security.username);
        session.security = Some(security);
        Ok(session)
    }

    async fn new<SA>(
        version: Version,
        destination: SA,
        community: &[u8],
        starting_req_id: i32,
    ) -> io::Result<Self>
    where
        SA: ToSocketAddrs,
    {
        let socket = match lookup_host(destination).await?.next() {
            Some(SocketAddr::V4(addr)) => {
                let s = UdpSocket::bind((Ipv4Addr::new(0, 0, 0, 0), 0)).await?;
                s.connect(addr).await?;
                s
            }
            Some(SocketAddr::V6(addr)) => {
                let s = UdpSocket::bind((Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 0), 0)).await?;
                s.connect(addr).await?;
                s
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "No address found",
                ));
            }
        };
        Ok(Self {
            version,
            socket,
            community: community.to_vec(),
            req_id: Wrapping(starting_req_id),
            send_pdu: pdu::Buf::default(),
            #[cfg(not(feature = "heap_buffers"))]
            recv_buf: [0; BUFFER_SIZE],
            #[cfg(feature = "heap_buffers")]
            recv_buf: vec![0u8; BUFFER_SIZE].into_boxed_slice(),
            #[cfg(feature = "v3")]
            security: None,
        })
    }

    /// Returns the version of the session, e.g. Version::V1.
    /// This is useful for determining whether bulk get is supported.
    pub fn version(&self) -> Version {
        self.version
    }

    #[cfg(not(feature = "v3"))]
    #[allow(clippy::unused_self, clippy::unused_async)]
    pub async fn init(&mut self) -> Result<()> {
        Ok(())
    }

    #[cfg(feature = "v3")]
    pub async fn init(&mut self) -> Result<()> {
        if let Some(ref mut security) = self.security {
            security.reset_engine_id();
            security.reset_engine_counters();
            // send a request to get the engine id
            let req_id = self.req_id.0;
            v3::build_init(req_id, &mut self.send_pdu);
            self.req_id += Wrapping(1);
            if let Err(e) = Pdu::from_bytes_inner(
                Self::send_and_recv(&self.socket, &self.send_pdu, &mut self.recv_buf).await?,
                Some(security),
            ) {
                if e != Error::AuthUpdated {
                    return Err(e);
                }
            }
            if security.need_init() {
                return Err(Error::AuthFailure(v3::AuthErrorKind::NotAuthenticated));
            }
        }
        Ok(())
    }

    /// Checks if KeyExtension affects this session privacy and then re-inits session with different KeyExtension
    ///
    /// # Returns
    /// 'Ok(Some(new_key_extension))' When new_key_extension method was set
    /// 'Ok(None)' When security disabled
    /// or Auth type is not AuthPriv
    /// or when Auth-Priv pair is not the one that needs key extension
    /// or when KeyExtension was not set for the session.
    /// 'Err(error)' when 'init()' failed with error returned from 'init()'
    #[cfg(feature = "v3")]
    pub async fn try_another_key_extension_method(&mut self) -> Result<Option<v3::KeyExtension>> {
        if let Some(ref mut security) = self.security {
            if let Some(new_method) = security.another_key_extension_method() {
                security.authoritative_state = v3::AuthoritativeState::default();
                self.init().await?;
                return Ok(Some(new_method));
            }
        }
        Ok(None)
    }

    #[cfg(not(feature = "v3"))]
    #[allow(clippy::unused_self)]
    fn prepare(&mut self) {}

    #[cfg(feature = "v3")]
    fn prepare(&mut self) {
        if let Some(ref mut security) = self.security {
            security.correct_authoritative_engine_time();
        }
    }

    async fn send_and_recv<'a>(
        socket: &UdpSocket,
        pdu: &pdu::Buf,
        out: &'a mut [u8],
    ) -> Result<&'a [u8]> {
        if let Ok(_pdu_len) = socket.send(pdu).await {
            match socket.recv(out).await {
                Ok(len) => Ok(&out[..len]),
                Err(_) => Err(Error::Receive),
            }
        } else {
            Err(Error::Send)
        }
    }

    pub async fn get(&mut self, oid: &Oid<'_>) -> Result<Pdu> {
        self.prepare();
        let req_id = self.req_id.0;
        pdu::build_get(
            self.version,
            self.community.as_slice(),
            req_id,
            oid,
            &mut self.send_pdu,
            #[cfg(feature = "v3")]
            self.security.as_ref(),
        )?;
        let resp = Pdu::from_bytes_inner(
            Self::send_and_recv(&self.socket, &self.send_pdu, &mut self.recv_buf).await?,
            #[cfg(feature = "v3")]
            self.security.as_mut(),
        )?;
        self.req_id += Wrapping(1);
        resp.validate(MessageType::Response, req_id, &self.community)?;
        Ok(resp)
    }

    pub async fn get_many(&mut self, oids: &[&Oid<'_>]) -> Result<Pdu> {
        self.prepare();
        let req_id = self.req_id.0;
        pdu::build_get_many(
            self.version,
            self.community.as_slice(),
            req_id,
            oids,
            &mut self.send_pdu,
            #[cfg(feature = "v3")]
            self.security.as_ref(),
        )?;
        let resp = Pdu::from_bytes_inner(
            Self::send_and_recv(&self.socket, &self.send_pdu, &mut self.recv_buf).await?,
            #[cfg(feature = "v3")]
            self.security.as_mut(),
        )?;
        self.req_id += Wrapping(1);
        resp.validate(MessageType::Response, req_id, &self.community)?;
        Ok(resp)
    }

    pub async fn getnext(&mut self, oid: &Oid<'_>) -> Result<Pdu> {
        self.prepare();
        let req_id = self.req_id.0;
        pdu::build_getnext(
            self.version,
            self.community.as_slice(),
            req_id,
            oid,
            &mut self.send_pdu,
            #[cfg(feature = "v3")]
            self.security.as_ref(),
        )?;
        let resp = Pdu::from_bytes_inner(
            Self::send_and_recv(&self.socket, &self.send_pdu, &mut self.recv_buf).await?,
            #[cfg(feature = "v3")]
            self.security.as_mut(),
        )?;
        self.req_id += Wrapping(1);
        resp.validate(MessageType::Response, req_id, &self.community)?;
        Ok(resp)
    }

    pub async fn getbulk(
        &mut self,
        oids: &[&Oid<'_>],
        non_repeaters: u32,
        max_repetitions: u32,
    ) -> Result<Pdu> {
        self.prepare();
        let req_id = self.req_id.0;
        pdu::build_getbulk(
            self.version,
            self.community.as_slice(),
            req_id,
            oids,
            non_repeaters,
            max_repetitions,
            &mut self.send_pdu,
            #[cfg(feature = "v3")]
            self.security.as_ref(),
        )?;
        let resp = Pdu::from_bytes_inner(
            Self::send_and_recv(&self.socket, &self.send_pdu, &mut self.recv_buf).await?,
            #[cfg(feature = "v3")]
            self.security.as_mut(),
        )?;
        self.req_id += Wrapping(1);
        resp.validate(MessageType::Response, req_id, &self.community)?;
        Ok(resp)
    }

    pub async fn set(&mut self, values: &[(&Oid<'_>, Value<'_>)]) -> Result<Pdu> {
        self.prepare();
        let req_id = self.req_id.0;
        pdu::build_set(
            self.version,
            self.community.as_slice(),
            req_id,
            values,
            &mut self.send_pdu,
            #[cfg(feature = "v3")]
            self.security.as_ref(),
        )?;
        let resp = Pdu::from_bytes_inner(
            Self::send_and_recv(&self.socket, &self.send_pdu, &mut self.recv_buf).await?,
            #[cfg(feature = "v3")]
            self.security.as_mut(),
        )?;
        self.req_id += Wrapping(1);
        resp.validate(MessageType::Response, req_id, &self.community)?;
        Ok(resp)
    }
}
