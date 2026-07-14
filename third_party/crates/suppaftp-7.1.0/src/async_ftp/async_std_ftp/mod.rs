//! # Async
//!
//! This module contains the definition for async-std async implementation of suppaftp

mod data_stream;
mod tls;

use std::future::Future;
#[cfg(not(feature = "async-secure"))]
use std::marker::PhantomData;
use std::net::SocketAddr;
use std::pin::Pin;
use std::string::String;
use std::time::Duration;

use async_std::io::prelude::BufReadExt;
use async_std::io::{BufReader, Read, Write, copy};
use async_std::net::{TcpListener, TcpStream, ToSocketAddrs};
use chrono::{NaiveDate, NaiveDateTime, NaiveTime};
// export
pub use data_stream::DataStream;
use futures_lite::AsyncWriteExt;
#[cfg(feature = "async-secure")]
pub use tls::AsyncTlsConnector;
#[cfg(feature = "async-std-async-native-tls")]
pub use tls::{AsyncNativeTlsConnector, AsyncNativeTlsStream};
pub use tls::{AsyncNoTlsStream, AsyncStdTlsStream};
#[cfg(feature = "async-std-rustls")]
pub use tls::{AsyncRustlsConnector, AsyncRustlsStream};

use super::super::Status;
use super::super::regex::{EPSV_PORT_RE, MDTM_RE, SIZE_RE};
use super::super::types::{FileType, FtpError, FtpResult, Mode, Response};
use crate::FtpStream;
use crate::command::Command;
#[cfg(feature = "async-secure")]
use crate::command::ProtectionLevel;
use crate::types::Features;

/// A function that creates a new stream for the data connection in passive mode.
///
/// It takes a [`SocketAddr`] and returns a [`TcpStream`].
pub type AsyncStdPassiveStreamBuilder = dyn Fn(SocketAddr) -> Pin<Box<dyn Future<Output = FtpResult<TcpStream>> + Send + Sync>>
    + Send
    + Sync;

/// Stream to interface with the FTP server. This interface is only for the command stream.
pub struct ImplAsyncFtpStream<T>
where
    T: AsyncStdTlsStream + Send,
{
    reader: BufReader<DataStream<T>>,
    mode: Mode,
    nat_workaround: bool,
    welcome_msg: Option<String>,
    active_timeout: Duration,
    passive_stream_builder: Box<AsyncStdPassiveStreamBuilder>,
    /// flags whether a data connection is currently open
    ///
    /// Since it isn't possible to have multiple data connections at the same time,
    /// this flag is used to track whether a data connection is currently open.
    data_connection_open: bool,
    #[cfg(not(feature = "async-secure"))]
    marker: PhantomData<T>,
    #[cfg(feature = "async-secure")]
    tls_ctx: Option<Box<dyn AsyncTlsConnector<Stream = T> + Send + Sync + 'static>>,
    #[cfg(feature = "async-secure")]
    domain: Option<String>,
}

impl<T> ImplAsyncFtpStream<T>
where
    T: AsyncStdTlsStream + Send,
{
    pub async fn connect<A: ToSocketAddrs>(addr: A) -> FtpResult<Self> {
        debug!("Connecting to server");
        let stream = TcpStream::connect(addr)
            .await
            .map_err(FtpError::ConnectionError)?;
        debug!("Established connection with server");
        Self::connect_with_stream(stream).await
    }

    /// Try to connect to the remote server but with the specified timeout
    pub async fn connect_timeout(addr: SocketAddr, timeout: Duration) -> FtpResult<Self> {
        debug!("Connecting to server {addr}");
        let stream = async_std::io::timeout(timeout, async move { TcpStream::connect(addr).await })
            .await
            .map_err(FtpError::ConnectionError)?;

        Self::connect_with_stream(stream).await
    }

    /// Connect using provided configured tcp stream
    pub async fn connect_with_stream(stream: TcpStream) -> FtpResult<Self> {
        debug!("Established connection with server");
        let mut ftp_stream = ImplAsyncFtpStream {
            reader: BufReader::new(DataStream::Tcp(stream)),
            #[cfg(not(feature = "async-secure"))]
            marker: PhantomData {},
            mode: Mode::Passive,
            data_connection_open: false,
            nat_workaround: false,
            passive_stream_builder: Self::default_passive_stream_builder(),
            welcome_msg: None,
            #[cfg(feature = "async-secure")]
            tls_ctx: None,
            #[cfg(feature = "async-secure")]
            domain: None,
            active_timeout: Duration::from_secs(60),
        };
        debug!("Reading server response...");
        match ftp_stream.read_response(Status::Ready).await {
            Ok(response) => {
                let welcome_msg = response.as_string().ok();
                debug!("Server READY; response: {:?}", welcome_msg);
                ftp_stream.welcome_msg = welcome_msg;
                Ok(ftp_stream)
            }
            Err(err) => Err(err),
        }
    }

    /// Switch to secure mode if possible (FTPS), using a provided SSL configuration.
    /// This method does nothing if the connect is already secured.
    ///
    /// ## Example
    ///
    /// ```rust,ignore
    /// use suppaftp::ImplAsyncFtpStream;
    /// use suppaftp::async_native_tls::{TlsConnector, TlsStream};
    /// use std::path::Path;
    ///
    /// // Create a TlsConnector
    /// // NOTE: For custom options see <https://docs.rs/native-tls/0.2.6/native_tls/struct.TlsConnectorBuilder.html>
    /// let mut ctx = TlsConnector::new();
    /// let mut ftp_stream = ImplAsyncFtpStream::connect("127.0.0.1:21").await.unwrap();
    /// let mut ftp_stream = ftp_stream.into_secure(ctx, "localhost").await.unwrap();
    /// ```
    #[cfg(feature = "async-secure")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-secure")))]
    pub async fn into_secure(
        mut self,
        tls_connector: impl AsyncTlsConnector<Stream = T> + Send + Sync + 'static,
        domain: &str,
    ) -> FtpResult<Self> {
        debug!("Initializing TLS auth");
        // Ask the server to start securing data.
        self.perform(Command::Auth).await?;
        self.read_response(Status::AuthOk).await?;
        debug!("TLS OK; initializing ssl stream");
        let stream = tls_connector
            .connect(
                domain,
                self.reader.into_inner().into_tcp_stream().to_owned(),
            )
            .await
            .map_err(|e| FtpError::SecureError(format!("{e}")))?;
        let mut secured_ftp_tream = ImplAsyncFtpStream {
            reader: BufReader::new(DataStream::Ssl(Box::new(stream))),
            mode: self.mode,
            data_connection_open: self.data_connection_open,
            nat_workaround: self.nat_workaround,
            passive_stream_builder: self.passive_stream_builder,
            tls_ctx: Some(Box::new(tls_connector)),
            domain: Some(String::from(domain)),
            welcome_msg: self.welcome_msg,
            active_timeout: self.active_timeout,
        };
        // Set protection buffer size
        secured_ftp_tream.perform(Command::Pbsz(0)).await?;
        secured_ftp_tream.read_response(Status::CommandOk).await?;
        // Change the level of data protectio to Private
        secured_ftp_tream
            .perform(Command::Prot(ProtectionLevel::Private))
            .await?;
        secured_ftp_tream.read_response(Status::CommandOk).await?;
        Ok(secured_ftp_tream)
    }

    /// Connect to remote ftps server using IMPLICIT secure connection.
    ///
    /// > Warning: mind that implicit ftps should be considered deprecated, if you can use explicit mode with `into_secure()`
    ///
    ///
    /// ## Example
    ///
    /// ```rust,ignore
    /// use suppaftp::ImplAsyncFtpStream;
    /// use suppaftp::native_tls::{TlsConnector, TlsStream};
    /// use std::path::Path;
    ///
    /// // Create a TlsConnector
    /// // NOTE: For custom options see <https://docs.rs/native-tls/0.2.6/native_tls/struct.TlsConnectorBuilder.html>
    /// let mut ctx = TlsConnector::new();
    /// let mut ftp_stream = ImplAsyncFtpStream::connect_secure_implicit("127.0.0.1:990", ctx, "localhost").await.unwrap();
    /// ```
    #[cfg(all(feature = "async-secure", feature = "deprecated"))]
    #[cfg_attr(
        docsrs,
        doc(cfg(all(feature = "async-secure", feature = "deprecated")))
    )]
    pub async fn connect_secure_implicit<A: ToSocketAddrs>(
        addr: A,
        tls_connector: impl AsyncTlsConnector<Stream = T> + Send + Sync + 'static,
        domain: &str,
    ) -> FtpResult<Self> {
        debug!("Connecting to server (secure)");
        let stream = TcpStream::connect(addr)
            .await
            .map_err(FtpError::ConnectionError)
            .map(|stream| {
                debug!("Established connection with server");
                Self {
                    reader: BufReader::new(DataStream::Tcp(stream)),
                    mode: Mode::Passive,
                    data_connection_open: false,
                    nat_workaround: false,
                    welcome_msg: None,
                    passive_stream_builder: Self::default_passive_stream_builder(),
                    tls_ctx: None,
                    domain: None,
                    active_timeout: Duration::from_secs(60),
                }
            })?;
        debug!("Established connection with server");
        debug!("TLS OK; initializing ssl stream");
        let stream = tls_connector
            .connect(domain, stream.reader.into_inner().into_tcp_stream())
            .await
            .map_err(|e| FtpError::SecureError(format!("{e}")))?;
        debug!("TLS Steam OK");
        let mut stream = ImplAsyncFtpStream {
            reader: BufReader::new(DataStream::Ssl(stream.into())),
            mode: Mode::Passive,
            nat_workaround: false,
            data_connection_open: false,
            passive_stream_builder: Self::default_passive_stream_builder(),
            tls_ctx: Some(Box::new(tls_connector)),
            domain: Some(String::from(domain)),
            welcome_msg: None,
            active_timeout: Duration::from_secs(60),
        };
        debug!("Reading server response...");
        match stream.read_response(Status::Ready).await {
            Ok(response) => {
                let welcome_msg = response.as_string().ok();
                debug!("Server READY; response: {:?}", welcome_msg);
                stream.welcome_msg = welcome_msg;
            }
            Err(err) => return Err(err),
        }

        Ok(stream)
    }

    /// Enable active mode for data channel
    pub fn active_mode(mut self, listener_timeout: Duration) -> Self {
        self.mode = Mode::Active;
        self.active_timeout = listener_timeout;
        self
    }

    /// Set a custom [`AsyncStdPassiveStreamBuilder`] for passive mode.
    ///
    /// The stream builder is a function that takes a `SocketAddr` and returns a `TcpStream` and it's used
    /// to create the [`TcpStream`] for the data connection in passive mode.
    pub fn passive_stream_builder<F>(mut self, stream_builder: F) -> Self
    where
        F: Fn(SocketAddr) -> Pin<Box<dyn Future<Output = FtpResult<TcpStream>> + Send + Sync>>
            + Send
            + Sync
            + 'static,
    {
        self.passive_stream_builder = Box::new(stream_builder);
        self
    }

    /// Returns welcome message retrieved from server (if available)
    pub fn get_welcome_msg(&self) -> Option<&str> {
        self.welcome_msg.as_deref()
    }

    /// Set mode
    pub fn set_mode(&mut self, mode: Mode) {
        debug!("Changed mode to {:?}", mode);
        self.mode = mode;
    }

    /// Set NAT workaround for passive mode
    pub fn set_passive_nat_workaround(&mut self, nat_workaround: bool) {
        self.nat_workaround = nat_workaround;
    }

    /// Returns a reference to the underlying TcpStream.
    pub fn get_ref(&self) -> &TcpStream {
        self.reader.get_ref().get_ref()
    }

    /// Log in to the FTP server.
    pub async fn login<S: AsRef<str>>(&mut self, user: S, password: S) -> FtpResult<()> {
        debug!("Signin in with user '{}'", user.as_ref());
        self.perform(Command::User(user.as_ref().to_string()))
            .await?;
        let response = self
            .read_response_in(&[Status::LoggedIn, Status::NeedPassword])
            .await?;
        if response.status == Status::NeedPassword {
            debug!("Password is required");
            self.perform(Command::Pass(password.as_ref().to_string()))
                .await?;
            self.read_response(Status::LoggedIn).await?;
        }
        debug!("Login OK");
        Ok(())
    }

    /// Perform clear command channel (CCC).
    /// Once the command is performed, the command channel will be encrypted no more.
    /// The data stream will still be secure.
    #[cfg(feature = "async-secure")]
    #[cfg_attr(docsrs, doc(cfg(feature = "async-secure")))]
    pub async fn clear_command_channel(mut self) -> FtpResult<Self> {
        // Ask the server to stop securing data
        debug!("performing clear command channel");
        self.perform(Command::ClearCommandChannel).await?;
        self.read_response(Status::CommandOk).await?;
        trace!("CCC OK");
        self.reader = BufReader::new(DataStream::Tcp(self.reader.into_inner().into_tcp_stream()));
        Ok(self)
    }

    /// Change the current directory to the path specified.
    pub async fn cwd<S: AsRef<str>>(&mut self, path: S) -> FtpResult<()> {
        debug!("Changing working directory to {}", path.as_ref());
        self.perform(Command::Cwd(path.as_ref().to_string()))
            .await?;
        self.read_response(Status::RequestedFileActionOk)
            .await
            .map(|_| ())
    }

    /// Move the current directory to the parent directory.
    pub async fn cdup(&mut self) -> FtpResult<()> {
        debug!("Going to parent directory");
        self.perform(Command::Cdup).await?;
        self.read_response_in(&[Status::CommandOk, Status::RequestedFileActionOk])
            .await
            .map(|_| ())
    }

    /// Gets the current directory
    pub async fn pwd(&mut self) -> FtpResult<String> {
        debug!("Getting working directory");
        self.perform(Command::Pwd).await?;
        let response = self.read_response(Status::PathCreated).await?;
        let body = response.as_string().map_err(|_| FtpError::BadResponse)?;
        let status = response.status;
        match (body.find('"'), body.rfind('"')) {
            (Some(begin), Some(end)) if begin < end => Ok(body[begin + 1..end].to_string()),
            _ => Err(FtpError::UnexpectedResponse(Response::new(
                status,
                response.body,
            ))),
        }
    }

    /// This does nothing. This is usually just used to keep the connection open.
    pub async fn noop(&mut self) -> FtpResult<()> {
        debug!("Pinging server");
        self.perform(Command::Noop).await?;
        self.read_response(Status::CommandOk).await.map(|_| ())
    }

    /// The EPRT command allows for the specification of an extended address
    /// for the data connection. The extended address MUST consist of the
    /// network protocol as well as the network and transport addresses
    pub async fn eprt(&mut self, address: SocketAddr) -> FtpResult<()> {
        debug!("EPRT with address {address}");
        self.perform(Command::Eprt(address)).await?;
        self.read_response(Status::CommandOk).await.map(|_| ())
    }

    /// This creates a new directory on the server.
    pub async fn mkdir<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<()> {
        debug!("Creating directory at {}", pathname.as_ref());
        self.perform(Command::Mkd(pathname.as_ref().to_string()))
            .await?;
        self.read_response(Status::PathCreated).await.map(|_| ())
    }

    /// Sets the type of file to be transferred. That is the implementation
    /// of `TYPE` command.
    pub async fn transfer_type(&mut self, file_type: FileType) -> FtpResult<()> {
        debug!("Setting transfer type {}", file_type);
        self.perform(Command::Type(file_type)).await?;
        self.read_response(Status::CommandOk).await.map(|_| ())
    }

    /// Quits the current FTP session.
    pub async fn quit(&mut self) -> FtpResult<()> {
        debug!("Quitting stream");
        self.perform(Command::Quit).await?;
        self.read_response(Status::Closing).await.map(|_| ())
    }

    /// Renames the file from_name to to_name
    pub async fn rename<S: AsRef<str>>(&mut self, from_name: S, to_name: S) -> FtpResult<()> {
        debug!(
            "Renaming '{}' to '{}'",
            from_name.as_ref(),
            to_name.as_ref()
        );
        self.perform(Command::RenameFrom(from_name.as_ref().to_string()))
            .await?;
        self.read_response(Status::RequestFilePending).await?;
        self.perform(Command::RenameTo(to_name.as_ref().to_string()))
            .await?;
        self.read_response(Status::RequestedFileActionOk)
            .await
            .map(|_| ())
    }

    /// The implementation of `RETR` command where `filename` is the name of the file
    /// to download from FTP and `reader` is the function which operates with the
    /// data stream opened.
    ///
    /// `reader` is an async pinned closure that takes the [`DataStream<T>`] and returns
    /// both the result `U` and the [`DataStream<T>`] back in a tuple `(U, DataStream<T>)`.
    ///
    /// This is necessary because the stream is then finalized with `finalize_retr_stream()`
    /// within this method.
    ///
    /// > Warning: Don't call [`Self::finalize_retr_stream`] manually, otherwise this will cause an error.
    pub async fn retr<S, F, U>(&mut self, file_name: S, mut reader: F) -> FtpResult<U>
    where
        F: FnMut(
            DataStream<T>,
        ) -> Pin<Box<dyn Future<Output = FtpResult<(U, DataStream<T>)>> + Send>>,
        S: AsRef<str>,
    {
        match self.retr_as_stream(file_name).await {
            Ok(stream) => {
                let (result, stream) = reader(stream).await?;
                self.finalize_retr_stream(stream).await?;
                Ok(result)
            }
            Err(err) => Err(err),
        }
    }

    /// Retrieves the file name specified from the server as a readable stream.
    /// This method is a more complicated way to retrieve a file.
    /// The reader returned should be dropped.
    /// Also you will have to read the response to make sure it has the correct value.
    /// Once file has been read, call `finalize_retr_stream()`
    pub async fn retr_as_stream<S: AsRef<str>>(
        &mut self,
        file_name: S,
    ) -> FtpResult<DataStream<T>> {
        debug!("Retrieving '{}'", file_name.as_ref());
        let data_stream = self
            .data_command(Command::Retr(file_name.as_ref().to_string()))
            .await?;
        self.read_response_in(&[Status::AboutToSend, Status::AlreadyOpen])
            .await?;
        Ok(data_stream)
    }

    /// Finalize retr stream; must be called once the requested file, got previously with `retr_as_stream()` has been read
    pub async fn finalize_retr_stream(&mut self, stream: impl Read) -> FtpResult<()> {
        debug!("Finalizing retr stream");
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(stream);
        self.data_connection_open = false;
        trace!("dropped stream");
        // Then read response
        self.read_response_in(&[Status::ClosingDataConnection, Status::RequestedFileActionOk])
            .await
            .map(|_| ())
    }

    /// Removes the remote pathname from the server.
    pub async fn rmdir<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<()> {
        debug!("Removing directory {}", pathname.as_ref());
        self.perform(Command::Rmd(pathname.as_ref().to_string()))
            .await?;
        self.read_response(Status::RequestedFileActionOk)
            .await
            .map(|_| ())
    }

    /// Remove the remote file from the server.
    pub async fn rm<S: AsRef<str>>(&mut self, filename: S) -> FtpResult<()> {
        debug!("Removing file {}", filename.as_ref());
        self.perform(Command::Dele(filename.as_ref().to_string()))
            .await?;
        self.read_response(Status::RequestedFileActionOk)
            .await
            .map(|_| ())
    }

    /// This stores a file on the server.
    /// r argument must be any struct which implemenents the Read trait
    pub async fn put_file<S, R>(&mut self, filename: S, r: &mut R) -> FtpResult<u64>
    where
        R: Read + std::marker::Unpin,
        S: AsRef<str>,
    {
        // Get stream
        let mut data_stream = self.put_with_stream(filename).await?;
        let bytes = copy(r, &mut data_stream)
            .await
            .map_err(FtpError::ConnectionError)?;
        self.finalize_put_stream(data_stream).await?;
        Ok(bytes)
    }

    /// Send PUT command and returns a BufWriter, which references the file created on the server
    /// The returned stream must be then correctly manipulated to write the content of the source file to the remote destination
    /// The stream must be then correctly dropped.
    /// Once you've finished the write, YOU MUST CALL THIS METHOD: `finalize_put_stream`
    pub async fn put_with_stream<S: AsRef<str>>(
        &mut self,
        filename: S,
    ) -> FtpResult<DataStream<T>> {
        debug!("Put file {}", filename.as_ref());
        let stream = self
            .data_command(Command::Store(filename.as_ref().to_string()))
            .await?;
        self.read_response_in(&[Status::AlreadyOpen, Status::AboutToSend])
            .await?;
        Ok(stream)
    }

    /// Finalize put when using stream
    /// This method must be called once the file has been written and
    /// `put_with_stream` has been used to write the file
    pub async fn finalize_put_stream(&mut self, mut stream: impl Write + Unpin) -> FtpResult<()> {
        debug!("Finalizing put stream");
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        stream.close().await.map_err(FtpError::ConnectionError)?;
        drop(stream);
        self.data_connection_open = false;
        trace!("Stream dropped");
        // Read response
        self.read_response_in(&[Status::ClosingDataConnection, Status::RequestedFileActionOk])
            .await
            .map(|_| ())
    }

    /// Open specified file for appending data. Returns the stream to append data to specified file.
    /// Once you've finished the write, YOU MUST CALL THIS METHOD: `finalize_put_stream`
    pub async fn append_with_stream<S: AsRef<str>>(
        &mut self,
        filename: S,
    ) -> FtpResult<DataStream<T>> {
        debug!("Appending to file {}", filename.as_ref());
        let stream = self
            .data_command(Command::Appe(filename.as_ref().to_string()))
            .await?;
        self.read_response_in(&[Status::AlreadyOpen, Status::AboutToSend])
            .await?;
        Ok(stream)
    }

    /// Append data from reader to file at `filename`
    pub async fn append_file<R>(&mut self, filename: &str, r: &mut R) -> FtpResult<u64>
    where
        R: Read + std::marker::Unpin,
    {
        // Get stream
        let mut data_stream = self.append_with_stream(filename).await?;
        let bytes = copy(r, &mut data_stream)
            .await
            .map_err(FtpError::ConnectionError)?;
        self.finalize_put_stream(Box::new(data_stream)).await?;
        Ok(bytes)
    }

    /// abort the previous FTP service command
    pub async fn abort<R>(&mut self, data_stream: R) -> FtpResult<()>
    where
        R: Read + std::marker::Unpin + 'static,
    {
        debug!("Aborting active file transfer");
        self.perform(Command::Abor).await?;
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(data_stream);
        self.data_connection_open = false;
        trace!("dropped stream");
        self.read_response_in(&[Status::ClosingDataConnection, Status::TransferAborted])
            .await?;
        self.read_response(Status::ClosingDataConnection).await?;
        trace!("Transfer aborted");
        Ok(())
    }

    /// Tell the server to resume the transfer from a certain offset. The offset indicates the amount of bytes to skip
    /// from the beginning of the file.
    /// the REST command does not actually initiate the transfer.
    /// After issuing a REST command, the client must send the appropriate FTP command to transfer the file
    ///
    /// It is possible to cancel the REST command, sending a REST command with offset 0
    pub async fn resume_transfer(&mut self, offset: usize) -> FtpResult<()> {
        debug!("Requesting to resume transfer at offset {}", offset);
        self.perform(Command::Rest(offset)).await?;
        self.read_response(Status::RequestFilePending).await?;
        debug!("Resume transfer accepted");
        Ok(())
    }

    /// Execute `LIST` command which returns the detailed file listing in human readable format.
    /// If `pathname` is omited then the list of files in the current directory will be
    /// returned otherwise it will the list of files on `pathname`.
    pub async fn list(&mut self, pathname: Option<&str>) -> FtpResult<Vec<String>> {
        debug!(
            "Reading {} directory content",
            pathname.unwrap_or("working")
        );

        self.stream_lines(
            Command::List(pathname.map(|x| x.to_string())),
            Status::AboutToSend,
        )
        .await
    }

    /// Execute `NLST` command which returns the list of file names only.
    /// If `pathname` is omited then the list of files in the current directory will be
    /// returned otherwise it will the list of files on `pathname`.
    pub async fn nlst(&mut self, pathname: Option<&str>) -> FtpResult<Vec<String>> {
        debug!(
            "Getting file names for {} directory",
            pathname.unwrap_or("working")
        );
        self.stream_lines(
            Command::Nlst(pathname.map(|x| x.to_string())),
            Status::AboutToSend,
        )
        .await
    }

    /// Execute `MLSD` command which returns the machine-processable listing of a directory.
    /// If `pathname` is omited then the list of files in the current directory will be
    pub async fn mlsd(&mut self, pathname: Option<&str>) -> FtpResult<Vec<String>> {
        debug!(
            "Reading {} directory content",
            pathname.unwrap_or("working")
        );

        self.stream_lines(
            Command::Mlsd(pathname.map(|x| x.to_string())),
            Status::AboutToSend,
        )
        .await
    }

    /// Execute `MLST` command which returns the machine-processable listing of a file.
    /// If `pathname` is omited then the list of files in the current directory will be
    pub async fn mlst(&mut self, pathname: Option<&str>) -> FtpResult<String> {
        debug!("Reading {} path information", pathname.unwrap_or("working"));

        self.perform(Command::Mlst(pathname.map(|x| x.to_string())))
            .await?;
        let response = self
            .read_response_in(&[Status::RequestedFileActionOk])
            .await?;
        // read body at line 1
        let response_str = String::from_utf8_lossy(&response.body).to_string();
        match response_str.lines().nth(1) {
            Some("") => Err(FtpError::BadResponse),
            Some(line) => Ok(line.trim().to_string()),
            None => Err(FtpError::BadResponse),
        }
    }

    /// Retrieves the modification time of the file at `pathname` if it exists.
    pub async fn mdtm<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<NaiveDateTime> {
        debug!("Getting modification time for {}", pathname.as_ref());
        self.perform(Command::Mdtm(pathname.as_ref().to_string()))
            .await?;
        let response: Response = self.read_response(Status::File).await?;
        let body = response.as_string().map_err(|_| FtpError::BadResponse)?;

        match MDTM_RE.captures(&body) {
            Some(caps) => {
                let (year, month, day) = (
                    caps[1].parse::<i32>().unwrap(),
                    caps[2].parse::<u32>().unwrap(),
                    caps[3].parse::<u32>().unwrap(),
                );
                let (hour, minute, second) = (
                    caps[4].parse::<u32>().unwrap(),
                    caps[5].parse::<u32>().unwrap(),
                    caps[6].parse::<u32>().unwrap(),
                );
                let date = match NaiveDate::from_ymd_opt(year, month, day) {
                    Some(d) => d,
                    None => return Err(FtpError::BadResponse),
                };

                let time = match NaiveTime::from_hms_opt(hour, minute, second) {
                    Some(t) => t,
                    None => return Err(FtpError::BadResponse),
                };

                Ok(NaiveDateTime::new(date, time))
            }
            None => Err(FtpError::BadResponse),
        }
    }

    /// Retrieves the size of the file in bytes at `pathname` if it exists.
    pub async fn size<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<usize> {
        debug!("Getting file size for {}", pathname.as_ref());
        self.perform(Command::Size(pathname.as_ref().to_string()))
            .await?;
        let response: Response = self.read_response(Status::File).await?;
        let body = response.as_string().map_err(|_| FtpError::BadResponse)?;

        match SIZE_RE.captures(&body) {
            Some(caps) => Ok(caps[1].parse().unwrap()),
            None => Err(FtpError::BadResponse),
        }
    }

    /// Retrieves the features supported by the server, through the FEAT command.
    pub async fn feat(&mut self) -> FtpResult<Features> {
        debug!("Getting server supported features");
        self.perform(Command::Feat).await?;

        let response = self.read_response(Status::System).await?;

        let first_line = String::from_utf8_lossy(&response.body);
        debug!("FEAT response: {}", first_line);
        let mut feat_lines = vec![first_line.to_string()];

        loop {
            let mut line = Vec::new();
            self.read_line(&mut line).await?;
            let line = String::from_utf8_lossy(&line);
            trace!("FEAT IN: {:?}", line);
            feat_lines.push(line.to_string());
            if crate::command::feat::is_last_line(&line) {
                break;
            }
        }

        crate::command::feat::parse_features(&feat_lines)
    }

    /// Set option `option` with an optional value
    pub async fn opts(
        &mut self,
        option: impl ToString,
        value: Option<impl ToString>,
    ) -> FtpResult<()> {
        debug!("Getting server supported features");
        self.perform(Command::Opts(
            option.to_string(),
            value.map(|x| x.to_string()),
        ))
        .await?;
        self.read_response(Status::CommandOk).await?;

        Ok(())
    }

    /// Execute a command on the server and return the response
    pub async fn site(&mut self, command: impl ToString) -> FtpResult<Response> {
        debug!("Sending SITE command: {}", command.to_string());
        self.perform(Command::Site(command.to_string())).await?;
        self.read_response(Status::CommandOk).await
    }

    /// Perform custom command
    pub async fn custom_command(
        &mut self,
        command: impl ToString,
        expected_code: &[Status],
    ) -> FtpResult<Response> {
        let command = command.to_string();
        debug!("Sending custom command: {}", command);
        self.perform(Command::Custom(command)).await?;
        self.read_response_in(expected_code).await
    }

    /// Perform a custom command using the data connection.
    /// It returns both the [`Response`] and the [`DataStream`].
    ///
    /// The [`DataStream`] implements both [`Write`] and [`Read`] and so it can be written or read to interact with the
    /// data channel.
    ///
    /// If you want you can easily parse lines from the [`DataStream`] using [`Self::get_lines_from_stream`].
    ///
    /// The stream must eventually be closed using [`Self::close_data_connection`].
    pub async fn custom_data_command(
        &mut self,
        command: impl ToString,
        expected_code: &[Status],
    ) -> FtpResult<(Response, DataStream<T>)> {
        let command = command.to_string();
        debug!("Sending custom data command: {}", command);
        let data_stream = self.data_command(Command::Custom(command)).await?;
        let response = self.read_response_in(expected_code).await?;
        Ok((response, data_stream))
    }

    /// Close data connection.
    ///
    /// Call this function when you're done with the stream obtained with [`Self::custom_data_command`].
    ///
    /// # Warning
    ///
    /// Passing any other [`Read`] which is not the [`DataStream`]
    /// obtained with [`Self::custom_data_command`] may lead to undefined behavior.
    pub async fn close_data_connection(&mut self, stream: impl Read) -> FtpResult<()> {
        debug!("closing data connection");
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(stream);
        self.data_connection_open = false;
        trace!("dropped stream");
        // Then read response
        self.read_response_in(&[Status::ClosingDataConnection, Status::RequestedFileActionOk])
            .await
            .map(|_| ())
    }

    /// Read a [`DataStream`] line by line.
    pub async fn get_lines_from_stream(
        data_stream: &mut BufReader<DataStream<T>>,
    ) -> FtpResult<Vec<String>> {
        let mut lines: Vec<String> = Vec::new();

        loop {
            let mut line_buf = vec![];
            match data_stream.read_until(b'\n', &mut line_buf).await {
                Ok(0) => break,
                Ok(len) => {
                    let mut line = String::from_utf8_lossy(&line_buf[..len]).to_string();
                    trace!("STREAM IN: {:?}", line);
                    if line.ends_with('\n') {
                        line.pop();
                    }
                    if line.ends_with('\r') {
                        line.pop();
                    }
                    if line.is_empty() {
                        continue;
                    }
                    lines.push(line);
                }
                Err(err) => {
                    error!("failed to get lines from stream: {err}");
                    return Err(FtpError::BadResponse);
                }
            }
        }
        trace!("Lines from stream {:?}", lines);
        Ok(lines)
    }

    // -- private

    /// Execute command which send data back in a separate stream
    async fn data_command(&mut self, cmd: Command) -> FtpResult<DataStream<T>> {
        // guard data connection
        self.guard_multiple_data_connections()?;
        self.data_connection_open = true;

        let stream = match self.mode {
            Mode::Active => {
                let listener = self.active().await?;
                self.perform(cmd).await?;

                match async_std::future::timeout(self.active_timeout, listener.accept()).await {
                    Ok(Ok((stream, addr))) => {
                        debug!("Connection received from {}", addr);
                        stream
                    }
                    Ok(Err(e)) => return Err(FtpError::ConnectionError(e)), // Handle error
                    Err(e) => {
                        return Err(FtpError::ConnectionError(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            e,
                        )));
                    }
                }
            }
            Mode::ExtendedPassive => {
                let addr = self.epsv().await?;
                self.perform(cmd).await?;
                (self.passive_stream_builder)(addr).await?
            }
            Mode::Passive => {
                let addr = self.pasv().await?;
                self.perform(cmd).await?;
                (self.passive_stream_builder)(addr).await?
            }
        };

        #[cfg(not(feature = "async-secure"))]
        {
            Ok(DataStream::Tcp(stream))
        }

        #[cfg(feature = "async-secure")]
        match self.tls_ctx {
            Some(ref tls_ctx) => tls_ctx
                .connect(self.domain.as_ref().unwrap(), stream)
                .await
                .map(|x| DataStream::Ssl(Box::new(x)))
                .map_err(|e| FtpError::SecureError(format!("{e}"))),
            None => Ok(DataStream::Tcp(stream)),
        }
    }

    /// Runs the EPSV to enter Extended passive mode.
    async fn epsv(&mut self) -> FtpResult<SocketAddr> {
        debug!("EPSV command");
        self.perform(Command::Epsv).await?;
        // PASV response format : 229 Entering Extended Passive Mode (|||PORT|)
        let response: Response = self.read_response(Status::ExtendedPassiveMode).await?;
        let response_str = response.as_string().map_err(|_| FtpError::BadResponse)?;
        let caps = EPSV_PORT_RE
            .captures(&response_str)
            .ok_or_else(|| FtpError::UnexpectedResponse(response.clone()))?;
        let new_port = caps[1].parse::<u16>().unwrap();
        trace!("Got port number from EPSV: {}", new_port);
        let mut remote = self
            .reader
            .get_ref()
            .get_ref()
            .peer_addr()
            .map_err(FtpError::ConnectionError)?;
        remote.set_port(new_port);
        trace!("Remote address for extended passive mode is {}", remote);
        Ok(remote)
    }

    /// Runs the PASV command.
    async fn pasv(&mut self) -> FtpResult<SocketAddr> {
        debug!("PASV command");
        self.perform(Command::Pasv).await?;
        // PASV response format : 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2).
        let response: Response = self.read_response(Status::PassiveMode).await?;
        let addr = FtpStream::parse_passive_address_from_response(response)?;
        trace!("Passive address: {}", addr);
        if self.nat_workaround {
            let mut remote = self
                .reader
                .get_ref()
                .get_ref()
                .peer_addr()
                .map_err(FtpError::ConnectionError)?;
            remote.set_port(addr.port());
            trace!("Replacing site local address {} with {}", addr, remote);
            Ok(remote)
        } else {
            Ok(addr)
        }
    }

    /// Create a new tcp listener and send a PORT command for it
    async fn active(&mut self) -> FtpResult<TcpListener> {
        debug!("Starting local tcp listener...");
        let conn = TcpListener::bind("0.0.0.0:0")
            .await
            .map_err(FtpError::ConnectionError)?;

        let addr = conn.local_addr().map_err(FtpError::ConnectionError)?;
        trace!("Local address is {}", addr);

        let ip = match self.reader.get_mut() {
            DataStream::Tcp(stream) => stream.local_addr().unwrap().ip(),
            DataStream::Ssl(stream) => stream.get_ref().local_addr().unwrap().ip(),
        };

        let msb = addr.port() / 256;
        let lsb = addr.port() % 256;
        let ip_port = format!("{},{},{}", ip.to_string().replace('.', ","), msb, lsb);
        debug!("Active mode, listening on {}:{}", ip, addr.port());

        debug!("Running PORT command");
        self.perform(Command::Port(ip_port)).await?;
        self.read_response(Status::CommandOk).await?;

        Ok(conn)
    }

    /// Write data to stream
    async fn perform(&mut self, command: Command) -> FtpResult<()> {
        let command = command.to_string();
        trace!("CC OUT: {}", command.trim_end_matches("\r\n"));

        let stream = self.reader.get_mut();
        stream
            .write_all(command.as_bytes())
            .await
            .map_err(FtpError::ConnectionError)
    }

    /// Read response from stream
    pub async fn read_response(&mut self, expected_code: Status) -> FtpResult<Response> {
        self.read_response_in(&[expected_code]).await
    }

    /// Retrieve single line response
    pub async fn read_response_in(&mut self, expected_code: &[Status]) -> FtpResult<Response> {
        let mut line = Vec::new();
        let mut body: Vec<u8> = Vec::new();
        self.read_line(&mut line).await?;
        body.extend(line.iter());

        trace!("CC IN: {:?}", line);

        if line.len() < 5 {
            return Err(FtpError::BadResponse);
        }

        let code_word: u32 = self.code_from_buffer(&line, 3)?;
        let code = Status::from(code_word);

        trace!("Code parsed from response: {} ({})", code, code_word);

        // multiple line reply
        // loop while the line does not begin with the code and a space (or dash)
        let expected = [line[0], line[1], line[2], 0x20];
        let alt_expected = if expected_code.contains(&Status::System) {
            [line[0], line[1], line[2], b'-']
        } else {
            expected
        };
        trace!("CC IN: {:?}", line);
        while line.len() < 5 || (line[0..4] != expected && line[0..4] != alt_expected) {
            line.clear();
            self.read_line(&mut line).await?;
            body.extend(line.iter());
            trace!("CC IN: {:?}", line);
        }

        let response: Response = Response::new(code, body);
        // Return Ok or error with response
        if expected_code.contains(&code) {
            Ok(response)
        } else {
            Err(FtpError::UnexpectedResponse(response))
        }
    }

    async fn read_line(&mut self, line: &mut Vec<u8>) -> FtpResult<usize> {
        self.reader
            .read_until(0x0A, line.as_mut())
            .await
            .map_err(FtpError::ConnectionError)?;
        Ok(line.len())
    }

    /// Get code from buffer
    fn code_from_buffer(&self, buf: &[u8], len: usize) -> Result<u32, FtpError> {
        if buf.len() < len {
            return Err(FtpError::BadResponse);
        }
        let buffer = buf[0..len].to_vec();
        let as_string = String::from_utf8(buffer).map_err(|_| FtpError::BadResponse)?;
        as_string.parse::<u32>().map_err(|_| FtpError::BadResponse)
    }

    /// Execute a command which returns list of strings in a separate stream
    async fn stream_lines(&mut self, cmd: Command, open_code: Status) -> FtpResult<Vec<String>> {
        let mut data_stream = BufReader::new(self.data_command(cmd).await?);
        self.read_response_in(&[open_code, Status::AlreadyOpen])
            .await?;
        let lines = Self::get_lines_from_stream(&mut data_stream).await;
        self.finalize_retr_stream(data_stream).await?;
        lines
    }

    fn default_passive_stream_builder() -> Box<AsyncStdPassiveStreamBuilder> {
        Box::new(|address| {
            Box::pin(async move {
                TcpStream::connect(address)
                    .await
                    .map_err(FtpError::ConnectionError)
            })
        })
    }

    /// guard against multiple data connections
    ///
    /// If `data_connection_open` is true, returns an [`FtpError::DataConnectionAlreadyOpen`] indicating that a data connection is already open.
    /// Otherwise, returns Ok(()).
    fn guard_multiple_data_connections(&self) -> FtpResult<()> {
        if self.data_connection_open {
            Err(FtpError::DataConnectionAlreadyOpen)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod test {
    use std::io::BufReader;
    use std::str::FromStr as _;
    use std::sync::Arc;

    use async_std::io::ReadExt;
    #[cfg(feature = "async-secure")]
    use pretty_assertions::assert_eq;
    use rand::distr::Alphanumeric;
    use rand::{Rng, rng};

    use super::super::async_std::AsyncFtpStream;
    use super::*;
    use crate::test_container::SyncPureFtpRunner;
    use crate::types::FormatControl;
    use crate::{FtpError, FtpStream, Status};

    #[async_attributes::test]
    async fn connect() {
        crate::log_init();
        let (stream, _container) = setup_stream().await;
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn should_change_mode() {
        crate::log_init();
        let (mut stream, _container) = setup_stream().await;

        assert_eq!(stream.mode, Mode::Passive);
        stream.set_mode(Mode::Active);
        assert_eq!(stream.mode, Mode::Active);
    }

    #[async_attributes::test]
    async fn should_connect_with_timeout() {
        crate::log_init();
        let container = SyncPureFtpRunner::start();
        let port = container.get_ftp_port();
        let url = format!("127.0.0.1:{port}");
        let addr: SocketAddr = url.parse().expect("invalid hostname");

        let mut stream = AsyncFtpStream::connect_timeout(addr, Duration::from_secs(15))
            .await
            .unwrap();
        assert!(stream.login("test", "test").await.is_ok());
        assert!(
            stream
                .get_welcome_msg()
                .unwrap()
                .contains("220 You will be disconnected after 15 minutes of inactivity.")
        );
    }

    #[async_attributes::test]
    async fn welcome_message() {
        crate::log_init();
        let (stream, _container) = setup_stream().await;
        assert!(
            stream
                .get_welcome_msg()
                .unwrap()
                .contains("220 You will be disconnected after 15 minutes of inactivity.")
        );
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn should_set_passive_nat_workaround() {
        crate::log_init();
        let (mut stream, _container) = setup_stream().await;
        stream.set_passive_nat_workaround(true);
        assert!(stream.nat_workaround);
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn get_ref() {
        let (stream, _container) = setup_stream().await;
        assert!(stream.get_ref().set_ttl(255).is_ok());
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn change_wrkdir() {
        let (mut stream, _container) = setup_stream().await;
        let wrkdir: String = stream.pwd().await.unwrap();
        assert!(stream.cwd("/").await.is_ok());
        assert_eq!(stream.pwd().await.unwrap().as_str(), "/");
        assert!(stream.cwd(wrkdir.as_str()).await.is_ok());
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn cd_up() {
        let (mut stream, _container) = setup_stream().await;
        let wrkdir: String = stream.pwd().await.unwrap();
        assert!(stream.cdup().await.is_ok());
        assert_eq!(stream.pwd().await.unwrap().as_str(), "/");
        assert!(stream.cwd(wrkdir.as_str()).await.is_ok());
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn noop() {
        let (mut stream, _container) = setup_stream().await;
        assert!(stream.noop().await.is_ok());
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn make_and_remove_dir() {
        let (mut stream, _container) = setup_stream().await;
        // Make directory
        assert!(stream.mkdir("omar").await.is_ok());
        // It shouldn't allow me to re-create the directory; should return error code 550
        match stream.mkdir("omar").await.err().unwrap() {
            FtpError::UnexpectedResponse(Response { status, body: _ }) => {
                assert_eq!(status, Status::FileUnavailable)
            }
            err => panic!("Expected UnexpectedResponse, got {}", err),
        }
        // Remove directory
        assert!(stream.rmdir("omar").await.is_ok());
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn should_get_feat_and_set_opts() {
        let (mut stream, _container) = setup_stream().await;
        let features = stream.feat().await.expect("failed to get features");
        assert!(features.contains_key("UTF8"));
        assert!(stream.opts("UTF8", Some("ON")).await.is_ok());

        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn set_transfer_type() {
        let (mut stream, _container) = setup_stream().await;
        assert!(stream.transfer_type(FileType::Binary).await.is_ok());
        assert!(
            stream
                .transfer_type(FileType::Ascii(FormatControl::Default))
                .await
                .is_ok()
        );
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn test_should_use_retr() {
        use async_std::io::Cursor;

        let (mut stream, _container) = setup_stream().await;
        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).await.is_ok());
        // Write file
        let file_data = "test data\n";
        let mut reader = Cursor::new(file_data.as_bytes());
        assert!(stream.put_file("test.txt", &mut reader).await.is_ok());
        // Read file
        let reader = stream
            .retr("test.txt", |mut reader| {
                Box::pin(async move {
                    let mut buf = Vec::new();
                    reader.read_to_end(&mut buf).await.expect("failed to read");
                    Ok((buf, reader))
                })
            })
            .await
            .unwrap();
        assert_eq!(reader, "test data\n".as_bytes());
    }

    #[async_attributes::test]
    async fn transfer_file() {
        use async_std::io::Cursor;

        let (mut stream, _container) = setup_stream().await;
        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).await.is_ok());
        // Write file
        let file_data = "test data\n";
        let mut reader = Cursor::new(file_data.as_bytes());
        assert!(stream.put_file("test.txt", &mut reader).await.is_ok());
        // Append file
        let mut reader = Cursor::new(file_data.as_bytes());
        assert!(stream.append_file("test.txt", &mut reader).await.is_ok());
        // Read file
        let mut reader = stream.retr_as_stream("test.txt").await.unwrap();
        let mut buffer = Vec::new();
        assert!(
            async_std::io::ReadExt::read_to_end(&mut reader, &mut buffer)
                .await
                .is_ok()
        );
        // Verify file matches
        assert_eq!(buffer.as_slice(), "test data\ntest data\n".as_bytes());
        // Finalize
        assert!(stream.finalize_retr_stream(reader).await.is_ok());
        // Get size
        assert_eq!(stream.size("test.txt").await.unwrap(), 20);
        // Size of non-existing file
        assert!(stream.size("omarone.txt").await.is_err());
        // List directory
        assert_eq!(stream.list(None).await.unwrap().len(), 1);
        // list names
        assert_eq!(stream.nlst(None).await.unwrap().as_slice(), &["test.txt"]);
        // modification time
        assert!(stream.mdtm("test.txt").await.is_ok());
        // Remove file
        assert!(stream.rm("test.txt").await.is_ok());
        assert!(stream.mdtm("test.txt").await.is_err());
        // Write file, rename and get
        let file_data = "test data\n";
        let mut reader = Cursor::new(file_data.as_bytes());
        assert!(stream.put_file("test.txt", &mut reader).await.is_ok());
        assert!(stream.rename("test.txt", "toast.txt").await.is_ok());
        assert!(stream.rm("toast.txt").await.is_ok());
        // List directory again
        assert_eq!(stream.list(None).await.unwrap().len(), 0);
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn should_resume_transfer() {
        let (mut stream, container) = setup_stream().await;
        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).await.is_ok());
        // get dir
        let wrkdir = stream.pwd().await.unwrap();
        // put as stream
        let mut transfer_stream = stream.put_with_stream("test.bin").await.unwrap();
        assert_eq!(
            transfer_stream
                .write(&[0x00, 0x01, 0x02, 0x03, 0x04])
                .await
                .unwrap(),
            5
        );
        // Drop stream on purpose to simulate a failed connection
        drop(stream);
        drop(transfer_stream);
        // Re-connect to server
        let port = container.get_ftp_port();
        let url = format!("localhost:{port}");

        let mut stream = AsyncFtpStream::connect(url).await.unwrap();
        assert!(stream.login("test", "test").await.is_ok());
        // Create wrkdir
        let tempdir: String = generate_tempdir();
        assert!(stream.mkdir(tempdir.as_str()).await.is_ok());
        // Change directory
        assert!(stream.cwd(tempdir.as_str()).await.is_ok());

        let container_t = container.clone();

        let mut stream = stream.passive_stream_builder(move |addr| {
            let container_t = container_t.clone();
            Box::pin(async move {
                let mut addr = addr.clone();
                let port = addr.port();
                let mapped = container_t.get_mapped_port(port);

                addr.set_port(mapped);

                info!("mapped port {port} to {mapped} for PASV");

                // open stream to this address instead
                TcpStream::connect(addr)
                    .await
                    .map_err(FtpError::ConnectionError)
            })
        });
        // Go back to previous dir
        assert!(stream.cwd(wrkdir).await.is_ok());
        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).await.is_ok());
        // Resume transfer
        assert!(stream.resume_transfer(5).await.is_ok());
        // Reopen stream
        let mut transfer_stream = stream.put_with_stream("test.bin").await.unwrap();
        assert_eq!(
            transfer_stream
                .write(&[0x05, 0x06, 0x07, 0x08, 0x09, 0x0a])
                .await
                .unwrap(),
            6
        );
        // Finalize
        assert!(stream.finalize_put_stream(transfer_stream).await.is_ok());
        // Get size
        //assert_eq!(stream.size("test.bin").await.unwrap(), 11);
        // Remove file
        assert!(stream.rm("test.bin").await.is_ok());
        // Drop stream
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn test_should_transfer_file_with_extended_passive_mode() {
        crate::log_init();
        use async_std::io::Cursor;

        let (mut stream, _container) = setup_stream().await;
        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).await.is_ok());
        stream.set_mode(Mode::ExtendedPassive);
        // Write file
        let file_data = "test data\n";
        let mut reader = Cursor::new(file_data.as_bytes());
        assert!(stream.put_file("test.txt", &mut reader).await.is_ok());
        // Remove file
        assert!(stream.rm("test.txt").await.is_ok());
        finalize_stream(stream).await;
    }

    #[async_attributes::test]
    async fn test_should_list_files_with_non_utf8_names() {
        let (mut stream, container) = setup_stream().await;
        let files = stream
            .nlst(Some("/invalid-utf8/"))
            .await
            .expect("Failed to list files");
        assert_eq!(files.len(), 1);

        // list file and parse
        let files = stream
            .list(Some("/invalid-utf8/"))
            .await
            .expect("Failed to list files");
        assert_eq!(files.len(), 1);
        // parse
        crate::list::File::from_str(files[0].as_str()).expect("Failed to parse file");

        finalize_stream(stream).await;
        drop(container);
    }

    #[async_attributes::test]
    async fn test_should_perform_custom_command() {
        let (mut stream, _container) = setup_stream().await;

        let command = "PWD";
        assert!(
            stream
                .custom_command(command, &[Status::PathCreated])
                .await
                .is_ok()
        );
    }

    #[async_attributes::test]
    async fn test_should_perform_custom_data_command() {
        let (mut stream, _container) = setup_stream().await;
        let command = "LIST";
        let (response, data_stream) = stream
            .custom_data_command(command, &[Status::AboutToSend])
            .await
            .expect("Failed to perform custom data command");
        assert_eq!(response.status, Status::AboutToSend);
        let mut reader = async_std::io::BufReader::new(data_stream);
        AsyncFtpStream::get_lines_from_stream(&mut reader)
            .await
            .expect("Failed to get lines from stream");
        // finalize
        assert!(stream.close_data_connection(reader).await.is_ok());
    }

    #[async_attributes::test]
    async fn test_should_prevent_multiple_data_connections() {
        let (mut stream, _container) = setup_stream().await;
        let command = "LIST";

        let _data_stream = stream
            .custom_data_command(command, &[Status::AboutToSend])
            .await
            .expect("Failed to perform custom data command");
        // Try to open another data connection without closing the previous one
        match stream
            .custom_data_command(command, &[Status::AboutToSend])
            .await
        {
            Err(FtpError::DataConnectionAlreadyOpen) => {}
            _ => panic!("Expected DataConnectionAlreadyOpen error"),
        }

        // try with all other data commands
        match stream.retr_as_stream("somefile.txt").await {
            Err(FtpError::DataConnectionAlreadyOpen) => {}
            _ => panic!("Expected DataConnectionAlreadyOpen error"),
        }

        match stream.put_with_stream("somefile.txt").await {
            Err(FtpError::DataConnectionAlreadyOpen) => {}
            _ => panic!("Expected DataConnectionAlreadyOpen error"),
        }

        match stream.append_with_stream("somefile.txt").await {
            Err(FtpError::DataConnectionAlreadyOpen) => {}
            _ => panic!("Expected DataConnectionAlreadyOpen error"),
        }
    }

    #[async_attributes::test]
    async fn test_should_free_data_connection_after_close() {
        let (mut stream, _container) = setup_stream().await;
        let command = "LIST";

        let (response, data_stream) = stream
            .custom_data_command(command, &[Status::AboutToSend])
            .await
            .expect("Failed to perform custom data command");
        assert_eq!(response.status, Status::AboutToSend);
        let mut reader = async_std::io::BufReader::new(data_stream);
        AsyncFtpStream::get_lines_from_stream(&mut reader)
            .await
            .expect("Failed to get lines from stream");
        // finalize
        assert!(stream.close_data_connection(reader).await.is_ok());

        // Now it should be possible to open another data connection
        let (response, data_stream) = stream
            .custom_data_command(command, &[Status::AboutToSend])
            .await
            .expect("Failed to perform custom data command");
        assert_eq!(response.status, Status::AboutToSend);
        let mut reader = async_std::io::BufReader::new(data_stream);
        AsyncFtpStream::get_lines_from_stream(&mut reader)
            .await
            .expect("Failed to get lines from stream");
        // finalize
        assert!(stream.close_data_connection(reader).await.is_ok());
    }

    /// Test if the stream is Send
    fn is_send<T: Send>(_send: T) {}

    #[async_attributes::test]
    #[ignore = "just needs to compile"]
    async fn test_ftp_stream_should_be_send() {
        crate::log_init();
        let ftp_stream = AsyncFtpStream::connect("test.rebex.net:21")
            .await
            .unwrap()
            .passive_stream_builder(|addr| {
                Box::pin(async move {
                    println!("Connecting to {}", addr);
                    TcpStream::connect(addr)
                        .await
                        .map_err(FtpError::ConnectionError)
                })
            });

        is_send::<AsyncFtpStream>(ftp_stream);
    }

    /// Test if the stream is Sync
    fn is_sync<T: Sync>(_send: T) {}

    #[async_attributes::test]
    #[ignore = "just needs to compile"]
    async fn test_ftp_stream_should_be_sync() {
        crate::log_init();
        let ftp_stream = AsyncFtpStream::connect("test.rebex.net:21")
            .await
            .unwrap()
            .passive_stream_builder(|addr| {
                Box::pin(async move {
                    println!("Connecting to {}", addr);
                    TcpStream::connect(addr)
                        .await
                        .map_err(FtpError::ConnectionError)
                })
            });

        is_sync::<AsyncFtpStream>(ftp_stream);
    }

    // -- test utils

    async fn setup_stream() -> (AsyncFtpStream, Arc<SyncPureFtpRunner>) {
        crate::log_init();
        let container = Arc::new(SyncPureFtpRunner::start());

        let port = container.get_ftp_port();
        let url = format!("localhost:{port}");

        let mut ftp_stream = ImplAsyncFtpStream::connect(url).await.unwrap();
        assert!(ftp_stream.login("test", "test").await.is_ok());
        // Create wrkdir
        let tempdir: String = generate_tempdir();
        assert!(ftp_stream.mkdir(tempdir.as_str()).await.is_ok());
        // Change directory
        assert!(ftp_stream.cwd(tempdir.as_str()).await.is_ok());

        let container_t = container.clone();

        let ftp_stream = ftp_stream.passive_stream_builder(move |addr| {
            let container_t = container_t.clone();
            Box::pin(async move {
                let mut addr = addr.clone();
                let port = addr.port();
                let mapped = container_t.get_mapped_port(port);

                addr.set_port(mapped);

                info!("mapped port {port} to {mapped} for PASV");

                // open stream to this address instead
                TcpStream::connect(addr)
                    .await
                    .map_err(FtpError::ConnectionError)
            })
        });

        (ftp_stream, container)
    }

    async fn finalize_stream(mut stream: AsyncFtpStream) {
        assert!(stream.quit().await.is_ok());
    }

    fn generate_tempdir() -> String {
        let mut rng = rng();
        let name: String = std::iter::repeat(())
            .map(|()| rng.sample(Alphanumeric))
            .map(char::from)
            .take(5)
            .collect();
        format!("temp_{}", name)
    }
}
