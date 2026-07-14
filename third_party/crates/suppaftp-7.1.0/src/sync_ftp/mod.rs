//! # Sync
//!
//! This module contains the definition for all Sync implementation of suppaftp

mod data_stream;
mod tls;

use std::io::{BufRead, BufReader, Cursor, Read, Write, copy};
#[cfg(not(feature = "secure"))]
use std::marker::PhantomData;
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

use chrono::{NaiveDate, NaiveDateTime, NaiveTime};
// export
pub use data_stream::DataStream;
#[cfg(feature = "secure")]
pub use tls::TlsConnector;
#[cfg(feature = "native-tls")]
pub use tls::{NativeTlsConnector, NativeTlsStream};
pub use tls::{NoTlsStream, TlsStream};
#[cfg(feature = "rustls")]
pub use tls::{RustlsConnector, RustlsStream};

use super::Status;
use super::regex::{EPSV_PORT_RE, MDTM_RE, PASV_PORT_RE, SIZE_RE};
use super::types::{FileType, FtpError, FtpResult, Mode, Response};
use crate::command::Command;
#[cfg(feature = "secure")]
use crate::command::ProtectionLevel;
use crate::types::Features;

/// A function that creates a new stream for the data connection in passive mode.
///
/// It takes a [`SocketAddr`] and returns a [`TcpStream`].
pub type PassiveStreamBuilder = dyn Fn(SocketAddr) -> FtpResult<TcpStream> + Send + Sync;

/// Stream to interface with the FTP server. This interface is only for the command stream.
pub struct ImplFtpStream<T>
where
    T: TlsStream,
{
    reader: BufReader<DataStream<T>>,
    mode: Mode,
    nat_workaround: bool,
    welcome_msg: Option<String>,
    /// flags whether a data connection is currently open
    ///
    /// Since it isn't possible to have multiple data connections at the same time,
    /// this flag is used to track whether a data connection is currently open.
    data_connection_open: bool,
    active_timeout: Duration,
    passive_stream_builder: Box<PassiveStreamBuilder>,
    #[cfg(not(feature = "secure"))]
    marker: PhantomData<T>,
    #[cfg(feature = "secure")]
    tls_ctx: Option<Box<dyn TlsConnector<Stream = T> + Send + Sync + 'static>>,
    #[cfg(feature = "secure")]
    domain: Option<String>,
}

impl<T> ImplFtpStream<T>
where
    T: TlsStream,
{
    /// Try to connect to the remote server
    pub fn connect<A: ToSocketAddrs>(addr: A) -> FtpResult<Self> {
        debug!("Connecting to server");
        TcpStream::connect(addr)
            .map_err(FtpError::ConnectionError)
            .and_then(|stream| Self::connect_with_stream(stream))
    }

    /// Try to connect to the remote server but with the specified timeout
    pub fn connect_timeout(addr: std::net::SocketAddr, timeout: Duration) -> FtpResult<Self> {
        debug!("Connecting to server {addr}");
        TcpStream::connect_timeout(&addr, timeout)
            .map_err(FtpError::ConnectionError)
            .and_then(|stream| Self::connect_with_stream(stream))
    }

    /// Connect using provided configured tcp stream
    pub fn connect_with_stream(stream: TcpStream) -> FtpResult<Self> {
        debug!("Established connection with server");
        let mut ftp_stream = Self {
            reader: BufReader::new(DataStream::Tcp(stream)),
            mode: Mode::Passive,
            nat_workaround: false,
            welcome_msg: None,
            data_connection_open: false,
            active_timeout: Duration::from_secs(60),
            passive_stream_builder: Self::default_passive_stream_builder(),
            #[cfg(feature = "secure")]
            tls_ctx: None,
            #[cfg(feature = "secure")]
            domain: None,
            #[cfg(not(feature = "secure"))]
            marker: PhantomData {},
        };
        debug!("Reading server response...");
        match ftp_stream.read_response(Status::Ready) {
            Ok(response) => {
                let welcome_msg = response.as_string().ok();
                debug!("Server READY; response: {:?}", welcome_msg);
                ftp_stream.welcome_msg = welcome_msg;
                Ok(ftp_stream)
            }
            Err(err) => Err(err),
        }
    }

    /// Enable active mode for data channel
    pub fn active_mode(mut self, accept_timeout: Duration) -> Self {
        self.mode = Mode::Active;
        self.active_timeout = accept_timeout;
        self
    }

    /// Set a custom [`PassiveStreamBuilder`] for passive mode.
    ///
    /// The stream builder is a function that takes a `SocketAddr` and returns a `TcpStream` and it's used
    /// to create the [`TcpStream`] for the data connection in passive mode.
    pub fn passive_stream_builder<F>(mut self, stream_builder: F) -> Self
    where
        F: Fn(SocketAddr) -> FtpResult<TcpStream> + Send + Sync + 'static,
    {
        self.passive_stream_builder = Box::new(stream_builder);
        self
    }

    /// Set the data channel transfer mode
    pub fn set_mode(&mut self, mode: Mode) {
        debug!("Changed mode to {:?}", mode);
        self.mode = mode;
    }

    /// Set NAT workaround for passive mode
    pub fn set_passive_nat_workaround(&mut self, nat_workaround: bool) {
        self.nat_workaround = nat_workaround;
    }

    /// Switch to explicit secure mode if possible (FTPS), using a provided SSL configuration.
    /// This method does nothing if the connect is already secured.
    ///
    /// ## Example
    ///
    /// ```rust,ignore
    /// use suppaftp::{NativeTlsFtpStream, NativeTlsConnector};
    /// use suppaftp::native_tls::{TlsConnector, TlsStream};
    /// use std::path::Path;
    ///
    /// // Create a TlsConnector
    /// // NOTE: For custom options see <https://docs.rs/native-tls/0.2.6/native_tls/struct.TlsConnectorBuilder.html>
    /// let mut ctx = NativeTlsConnector::from(TlsConnector::new().unwrap());
    /// let mut ftp_stream = NativeTlsFtpStream::connect("127.0.0.1:21").unwrap();
    /// let mut ftp_stream = ftp_stream.into_secure(ctx, "localhost").unwrap();
    /// ```
    #[cfg(feature = "secure")]
    #[cfg_attr(docsrs, doc(cfg(feature = "secure")))]
    pub fn into_secure(
        mut self,
        tls_connector: impl TlsConnector<Stream = T> + Send + Sync + 'static,
        domain: &str,
    ) -> FtpResult<Self> {
        // Ask the server to start securing data.
        debug!("Initializing TLS auth");
        self.perform(Command::Auth)?;
        self.read_response(Status::AuthOk)?;
        debug!("TLS OK; initializing ssl stream");
        let stream = tls_connector
            .connect(domain, self.reader.into_inner().into_tcp_stream())
            .map_err(|e| FtpError::SecureError(format!("{e}")))?;
        debug!("TLS Steam OK");
        let mut secured_ftp_tream = Self {
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
        secured_ftp_tream.perform(Command::Pbsz(0))?;
        secured_ftp_tream.read_response(Status::CommandOk)?;
        // Change the level of data protectio to Private
        secured_ftp_tream.perform(Command::Prot(ProtectionLevel::Private))?;
        secured_ftp_tream.read_response(Status::CommandOk)?;
        Ok(secured_ftp_tream)
    }

    /// Connect to remote ftps server using IMPLICIT secure connection.
    ///
    /// > Warning: mind that implicit ftps should be considered deprecated, if you can use explicit mode with [`ImplFtpStream::into_secure`]
    ///
    ///
    /// ## Example
    ///
    /// ```rust,ignore
    /// use suppaftp::FtpStream;
    /// use suppaftp::native_tls::{TlsConnector, TlsStream};
    /// use std::path::Path;
    ///
    /// //Create a TlsConnector
    /// //NOTE: For custom options see <https://docs.rs/native-tls/0.2.6/native_tls/struct.TlsConnectorBuilder.html>
    /// let mut ctx = TlsConnector::new().unwrap();
    /// let mut ftp_stream = FtpStream::connect_secure_implicit("127.0.0.1:990", ctx, "localhost").unwrap();
    /// ```
    #[cfg(all(feature = "secure", feature = "deprecated"))]
    #[cfg_attr(docsrs, doc(cfg(all(feature = "secure", feature = "deprecated"))))]
    pub fn connect_secure_implicit<A: ToSocketAddrs>(
        addr: A,
        tls_connector: impl TlsConnector<Stream = T> + Send + Sync + 'static,
        domain: &str,
    ) -> FtpResult<Self> {
        debug!("Connecting to server (secure)");
        let stream = TcpStream::connect(addr)
            .map_err(FtpError::ConnectionError)
            .map(|stream| {
                debug!("Established connection with server");
                Self {
                    reader: BufReader::new(DataStream::Tcp(stream)),
                    mode: Mode::Passive,
                    nat_workaround: false,
                    data_connection_open: false,
                    passive_stream_builder: Self::default_passive_stream_builder(),
                    welcome_msg: None,
                    tls_ctx: None,
                    domain: None,
                    active_timeout: Duration::from_secs(60),
                }
            })?;
        debug!("Established connection with server");
        debug!("TLS OK; initializing ssl stream");
        let stream = tls_connector
            .connect(domain, stream.reader.into_inner().into_tcp_stream())
            .map_err(|e| FtpError::SecureError(format!("{e}")))?;
        debug!("TLS Steam OK");
        let mut stream = Self {
            reader: BufReader::new(DataStream::Ssl(Box::new(stream))),
            mode: Mode::Passive,
            nat_workaround: false,
            data_connection_open: false,
            tls_ctx: Some(Box::new(tls_connector)),
            passive_stream_builder: Self::default_passive_stream_builder(),
            domain: Some(String::from(domain)),
            welcome_msg: None,
            active_timeout: Duration::from_secs(60),
        };
        debug!("Reading server response...");
        match stream.read_response(Status::Ready) {
            Ok(response) => {
                let welcome_msg = response.as_string().ok();
                debug!("Server READY; response: {:?}", welcome_msg);
                stream.welcome_msg = welcome_msg;
            }
            Err(err) => return Err(err),
        }

        Ok(stream)
    }

    /// Returns welcome message retrieved from server (if available)
    pub fn get_welcome_msg(&self) -> Option<&str> {
        self.welcome_msg.as_deref()
    }

    /// Returns a reference to the underlying [`TcpStream`].
    ///
    /// Example:
    /// ```ignore
    /// use suppaftp::FtpStream;
    /// use std::net::TcpStream;
    /// use std::time::Duration;
    ///
    /// let stream = FtpStream::connect("127.0.0.1:21")
    ///                        .expect("Couldn't connect to the server...");
    /// stream.get_ref().set_read_timeout(Some(Duration::from_secs(10)))
    ///                 .expect("set_read_timeout call failed");
    /// ```
    pub fn get_ref(&self) -> &TcpStream {
        self.reader.get_ref().get_ref()
    }

    /// Log in to the FTP server.
    pub fn login<S: AsRef<str>>(&mut self, user: S, password: S) -> FtpResult<()> {
        debug!("Signin in with user '{}'", user.as_ref());
        self.perform(Command::User(user.as_ref().to_string()))?;
        self.read_response_in(&[Status::LoggedIn, Status::NeedPassword])
            .and_then(|Response { status, body: _ }| {
                if status == Status::NeedPassword {
                    debug!("Password is required");
                    self.perform(Command::Pass(password.as_ref().to_string()))?;
                    self.read_response(Status::LoggedIn)?;
                }
                debug!("Login OK");
                Ok(())
            })
    }

    /// Perform clear command channel (CCC).
    /// Once the command is performed, the command channel will be encrypted no more.
    /// The data stream will still be secure.
    #[cfg(feature = "secure")]
    #[cfg_attr(docsrs, doc(cfg(feature = "secure")))]
    pub fn clear_command_channel(mut self) -> FtpResult<Self> {
        // Ask the server to stop securing data
        debug!("performing clear command channel");
        self.perform(Command::ClearCommandChannel)?;
        self.read_response(Status::CommandOk)?;
        trace!("CCC OK");
        self.reader = BufReader::new(DataStream::Tcp(self.reader.into_inner().into_tcp_stream()));
        Ok(self)
    }

    /// Change the current directory to the path specified.
    pub fn cwd<S: AsRef<str>>(&mut self, path: S) -> FtpResult<()> {
        debug!("Changing working directory to {}", path.as_ref());
        self.perform(Command::Cwd(path.as_ref().to_string()))?;
        self.read_response(Status::RequestedFileActionOk)
            .map(|_| ())
    }

    /// Move the current directory to the parent directory.
    pub fn cdup(&mut self) -> FtpResult<()> {
        debug!("Going to parent directory");
        self.perform(Command::Cdup)?;
        self.read_response_in(&[Status::CommandOk, Status::RequestedFileActionOk])
            .map(|_| ())
    }

    /// Gets the current directory
    pub fn pwd(&mut self) -> FtpResult<String> {
        debug!("Getting working directory");
        self.perform(Command::Pwd)?;
        self.read_response(Status::PathCreated)
            .and_then(|response| {
                let body = response.as_string().map_err(|_| FtpError::BadResponse)?;
                let status = response.status;
                match (body.find('"'), body.rfind('"')) {
                    (Some(begin), Some(end)) if begin < end => Ok(body[begin + 1..end].to_string()),
                    _ => Err(FtpError::UnexpectedResponse(Response::new(
                        status,
                        response.body,
                    ))),
                }
            })
    }

    /// This does nothing. This is usually just used to keep the connection open.
    pub fn noop(&mut self) -> FtpResult<()> {
        debug!("Pinging server");
        self.perform(Command::Noop)?;
        self.read_response(Status::CommandOk).map(|_| ())
    }

    /// The EPRT command allows for the specification of an extended address
    /// for the data connection. The extended address MUST consist of the
    /// network protocol as well as the network and transport addresses
    pub fn eprt(&mut self, address: SocketAddr) -> FtpResult<()> {
        debug!("EPRT with address {address}");
        self.perform(Command::Eprt(address))?;
        self.read_response(Status::CommandOk).map(|_| ())
    }

    /// This creates a new directory on the server.
    pub fn mkdir<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<()> {
        debug!("Creating directory at {}", pathname.as_ref());
        self.perform(Command::Mkd(pathname.as_ref().to_string()))?;
        self.read_response(Status::PathCreated).map(|_| ())
    }

    /// Sets the type of file to be transferred. That is the implementation
    /// of `TYPE` command.
    pub fn transfer_type(&mut self, file_type: FileType) -> FtpResult<()> {
        debug!("Setting transfer type {}", file_type);
        self.perform(Command::Type(file_type))?;
        self.read_response(Status::CommandOk).map(|_| ())
    }

    /// Quits the current FTP session.
    pub fn quit(&mut self) -> FtpResult<()> {
        debug!("Quitting stream");
        self.perform(Command::Quit)?;
        self.read_response(Status::Closing).map(|_| ())
    }

    /// Renames the file from_name to to_name
    pub fn rename<S: AsRef<str>>(&mut self, from_name: S, to_name: S) -> FtpResult<()> {
        debug!(
            "Renaming '{}' to '{}'",
            from_name.as_ref(),
            to_name.as_ref()
        );
        self.perform(Command::RenameFrom(from_name.as_ref().to_string()))?;
        self.read_response(Status::RequestFilePending)
            .and_then(|_| {
                self.perform(Command::RenameTo(to_name.as_ref().to_string()))?;
                self.read_response(Status::RequestedFileActionOk)
                    .map(|_| ())
            })
    }

    /// The implementation of `RETR` command where `filename` is the name of the file
    /// to download from FTP and `reader` is the function which operates with the
    /// data stream opened.
    ///
    /// ```rust,ignore
    /// use suppaftp::{FtpStream, FtpError};
    /// use std::io::Cursor;
    /// let mut conn = FtpStream::connect("127.0.0.1:10021").unwrap();
    /// conn.login("test", "test").and_then(|_| {
    ///     let mut reader = Cursor::new("hello, world!".as_bytes());
    ///     conn.put_file("retr.txt", &mut reader)
    /// }).unwrap();
    /// assert!(conn.retr("retr.txt", |stream| {
    ///     let mut buf = Vec::new();
    ///     stream.read_to_end(&mut buf).map(|_|
    ///         assert_eq!(buf, "hello, world!".as_bytes())
    ///     ).map_err(|e| FtpError::ConnectionError(e))
    /// }).is_ok());
    /// assert!(conn.rm("retr.txt").is_ok());
    /// ```
    pub fn retr<F, D>(&mut self, file_name: &str, mut reader: F) -> FtpResult<D>
    where
        F: FnMut(&mut dyn Read) -> FtpResult<D>,
    {
        match self.retr_as_stream(file_name) {
            Ok(mut stream) => {
                let result = reader(&mut stream)?;
                self.finalize_retr_stream(stream)?;
                Ok(result)
            }
            Err(err) => Err(err),
        }
    }

    /// Simple way to retr a file from the server. This stores the file in a buffer in memory.
    ///
    /// ```rust,ignore
    /// # use suppaftp::{FtpStream, FtpError};
    /// # use std::io::Cursor;
    /// # let mut conn = FtpStream::connect("127.0.0.1:10021").unwrap();
    /// # conn.login("test", "test").and_then(|_| {
    /// #     let mut reader = Cursor::new("hello, world!".as_bytes());
    /// #     conn.put_file("simple_retr.txt", &mut reader)
    /// # }).unwrap();
    /// let cursor = conn.retr_as_buffer("simple_retr.txt").unwrap();
    /// // do something with bytes
    /// assert_eq!(cursor.into_inner(), "hello, world!".as_bytes());
    /// # assert!(conn.rm("simple_retr.txt").is_ok());
    /// ```
    pub fn retr_as_buffer(&mut self, file_name: &str) -> FtpResult<Cursor<Vec<u8>>> {
        self.retr(file_name, |reader| {
            let mut buffer = Vec::new();
            reader
                .read_to_end(&mut buffer)
                .map(|_| buffer)
                .map_err(FtpError::ConnectionError)
        })
        .map(Cursor::new)
    }

    /// Retrieves the file name specified from the server as a readable stream.
    /// This method is a more complicated way to retrieve a file.
    /// The reader returned should be dropped.
    /// Also you will have to read the response to make sure it has the correct value.
    /// Once file has been read, call [`ImplFtpStream::finalize_retr_stream`]
    pub fn retr_as_stream<S: AsRef<str>>(&mut self, file_name: S) -> FtpResult<DataStream<T>> {
        debug!("Retrieving '{}'", file_name.as_ref());
        let data_stream = self.data_command(Command::Retr(file_name.as_ref().to_string()))?;
        self.read_response_in(&[Status::AboutToSend, Status::AlreadyOpen])?;
        Ok(data_stream)
    }

    /// Finalize retr stream; must be called once the requested file, got previously with [`ImplFtpStream::retr_as_stream`] has been read
    pub fn finalize_retr_stream(&mut self, stream: impl Read) -> FtpResult<()> {
        debug!("Finalizing retr stream");
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(stream);
        // mark data channel as closed
        self.data_connection_open = false;
        trace!("dropped stream");
        // Then read response
        self.read_response_in(&[Status::ClosingDataConnection, Status::RequestedFileActionOk])
            .map(|_| ())
    }

    /// Removes the remote pathname from the server.
    pub fn rmdir<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<()> {
        debug!("Removing directory {}", pathname.as_ref());
        self.perform(Command::Rmd(pathname.as_ref().to_string()))?;
        self.read_response(Status::RequestedFileActionOk)
            .map(|_| ())
    }

    /// Remove the remote file from the server.
    pub fn rm<S: AsRef<str>>(&mut self, filename: S) -> FtpResult<()> {
        debug!("Removing file {}", filename.as_ref());
        self.perform(Command::Dele(filename.as_ref().to_string()))?;
        self.read_response(Status::RequestedFileActionOk)
            .map(|_| ())
    }

    /// This stores a file on the server.
    /// r argument must be any struct which implemenents the [`Read`] trait.
    /// Returns amount of written bytes
    pub fn put_file<S: AsRef<str>, R: Read>(&mut self, filename: S, r: &mut R) -> FtpResult<u64> {
        // Get stream
        let mut data_stream = self.put_with_stream(filename.as_ref())?;
        let bytes = copy(r, &mut data_stream).map_err(FtpError::ConnectionError)?;
        self.finalize_put_stream(data_stream)?;
        Ok(bytes)
    }

    /// Send PUT command and returns a BufWriter, which references the file created on the server
    /// The returned stream must be then correctly manipulated to write the content of the source file to the remote destination
    /// The stream must be then correctly dropped.
    /// Once you've finished the write, YOU MUST CALL THIS METHOD: [`ImplFtpStream::finalize_put_stream`]
    pub fn put_with_stream<S: AsRef<str>>(&mut self, filename: S) -> FtpResult<DataStream<T>> {
        debug!("Put file {}", filename.as_ref());
        let stream = self.data_command(Command::Store(filename.as_ref().to_string()))?;
        self.read_response_in(&[Status::AlreadyOpen, Status::AboutToSend])?;
        Ok(stream)
    }

    /// Finalize put when using stream
    /// This method must be called once the file has been written and
    /// [`ImplFtpStream::put_with_stream`] has been used to write the file
    pub fn finalize_put_stream(&mut self, stream: impl Write) -> FtpResult<()> {
        debug!("Finalizing put stream");
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(stream);
        // mark data channel as closed
        self.data_connection_open = false;
        trace!("Stream dropped");
        // Read response
        self.read_response_in(&[Status::ClosingDataConnection, Status::RequestedFileActionOk])
            .map(|_| ())
    }

    /// Open specified file for appending data. Returns the stream to append data to specified file.
    /// Once you've finished the write, YOU MUST CALL THIS METHOD: [`ImplFtpStream::finalize_put_stream`]
    pub fn append_with_stream<S: AsRef<str>>(&mut self, filename: S) -> FtpResult<DataStream<T>> {
        debug!("Appending to file {}", filename.as_ref());
        let stream = self.data_command(Command::Appe(filename.as_ref().to_string()))?;
        self.read_response_in(&[Status::AlreadyOpen, Status::AboutToSend])?;
        Ok(stream)
    }

    /// Append data from reader to file at `filename`
    pub fn append_file<R: Read>(&mut self, filename: &str, r: &mut R) -> FtpResult<u64> {
        // Get stream
        let mut data_stream = self.append_with_stream(filename)?;
        let bytes = copy(r, &mut data_stream).map_err(FtpError::ConnectionError)?;
        self.finalize_put_stream(Box::new(data_stream))?;
        Ok(bytes)
    }

    /// abort the previous FTP service command
    pub fn abort(&mut self, data_stream: impl Read + 'static) -> FtpResult<()> {
        debug!("Aborting active file transfer");
        self.perform(Command::Abor)?;
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(data_stream);
        // mark data channel as closed
        self.data_connection_open = false;
        trace!("dropped stream");
        self.read_response_in(&[Status::ClosingDataConnection, Status::TransferAborted])?;
        self.read_response(Status::ClosingDataConnection)?;
        debug!("Transfer aborted");
        Ok(())
    }

    /// Tell the server to resume the transfer from a certain offset. The offset indicates the amount of bytes to skip
    /// from the beginning of the file.
    /// the REST command does not actually initiate the transfer.
    /// After issuing a REST command, the client must send the appropriate FTP command to transfer the file
    ///
    /// It is possible to cancel the REST command, sending a REST command with offset 0
    pub fn resume_transfer(&mut self, offset: usize) -> FtpResult<()> {
        debug!("Requesting to resume transfer at offset {}", offset);
        self.perform(Command::Rest(offset))?;
        self.read_response(Status::RequestFilePending)?;
        debug!("Resume transfer accepted");
        Ok(())
    }

    /// Execute `LIST` command which returns the detailed file listing in human readable format.
    /// If `pathname` is omited then the list of files in the current directory will be
    /// returned otherwise it will the list of files on `pathname`.
    ///
    /// ### Parse result
    ///
    /// You can parse the output of this command with
    ///
    /// ```rust
    ///
    /// use std::str::FromStr;
    /// use suppaftp::list::File;
    ///
    /// let file: File = File::from_str("-rw-rw-r-- 1 0  1  8192 Nov 5 2018 omar.txt")
    ///
    ///     .unwrap();
    /// ```
    pub fn list(&mut self, pathname: Option<&str>) -> FtpResult<Vec<String>> {
        debug!(
            "Reading {} directory content",
            pathname.unwrap_or("working")
        );

        self.stream_lines(
            Command::List(pathname.map(|x| x.to_string())),
            Status::AboutToSend,
        )
    }

    /// Execute `NLST` command which returns the list of file names only.
    /// If `pathname` is omited then the list of files in the current directory will be
    /// returned otherwise it will the list of files on `pathname`.
    pub fn nlst(&mut self, pathname: Option<&str>) -> FtpResult<Vec<String>> {
        debug!(
            "Getting file names for {} directory",
            pathname.unwrap_or("working")
        );

        self.stream_lines(
            Command::Nlst(pathname.map(|x| x.to_string())),
            Status::AboutToSend,
        )
    }

    /// Execute `MLSD` command which returns the machine-processable listing of a directory.
    /// If `pathname` is omited then the list of files in the current directory will be
    pub fn mlsd(&mut self, pathname: Option<&str>) -> FtpResult<Vec<String>> {
        debug!(
            "Reading {} directory content",
            pathname.unwrap_or("working")
        );

        self.stream_lines(
            Command::Mlsd(pathname.map(|x| x.to_string())),
            Status::AboutToSend,
        )
    }

    /// Execute `MLST` command which returns the machine-processable listing of a file.
    /// If `pathname` is omited then the list of files in the current directory will be
    pub fn mlst(&mut self, pathname: Option<&str>) -> FtpResult<String> {
        debug!("Reading {} path information", pathname.unwrap_or("working"));

        self.perform(Command::Mlst(pathname.map(|x| x.to_string())))?;
        let response = self.read_response_in(&[Status::RequestedFileActionOk])?;
        // read body at line 1
        let response_str = String::from_utf8_lossy(&response.body).to_string();
        match response_str.lines().nth(1) {
            Some("") => Err(FtpError::BadResponse),
            Some(line) => Ok(line.trim().to_string()),
            None => Err(FtpError::BadResponse),
        }
    }

    /// Retrieves the modification time of the file at `pathname` if it exists.
    pub fn mdtm<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<NaiveDateTime> {
        debug!("Getting modification time for {}", pathname.as_ref());
        self.perform(Command::Mdtm(pathname.as_ref().to_string()))?;
        let response: Response = self.read_response(Status::File)?;
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
    pub fn size<S: AsRef<str>>(&mut self, pathname: S) -> FtpResult<usize> {
        debug!("Getting file size for {}", pathname.as_ref());
        self.perform(Command::Size(pathname.as_ref().to_string()))?;
        let response: Response = self.read_response(Status::File)?;
        let body = response.as_string().map_err(|_| FtpError::BadResponse)?;

        match SIZE_RE.captures(&body) {
            Some(caps) => Ok(caps[1].parse().unwrap()),
            None => Err(FtpError::BadResponse),
        }
    }

    /// Retrieves the features supported by the server, through the FEAT command.
    pub fn feat(&mut self) -> FtpResult<Features> {
        debug!("Getting server supported features");
        // Send FEAT command
        self.perform(Command::Feat)?;

        // Read the response
        let response = self.read_response(Status::System)?;

        let first_line = String::from_utf8_lossy(&response.body);
        let mut feat_lines = vec![first_line.to_string()];
        loop {
            let mut line = Vec::new();
            let line_sz = self.read_line(&mut line)?;
            if line_sz == 0 {
                // EOF reached
                break;
            }
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
    pub fn opts(&mut self, option: impl ToString, value: Option<impl ToString>) -> FtpResult<()> {
        debug!("Getting server supported features");
        self.perform(Command::Opts(
            option.to_string(),
            value.map(|x| x.to_string()),
        ))?;
        self.read_response(Status::CommandOk)?;

        Ok(())
    }

    /// Execute a command on the server and return the response
    pub fn site(&mut self, command: impl ToString) -> FtpResult<Response> {
        debug!("Sending SITE command: {}", command.to_string());
        self.perform(Command::Site(command.to_string()))?;
        self.read_response(Status::CommandOk)
    }

    /// Perform custom command
    pub fn custom_command(
        &mut self,
        command: impl ToString,
        expected_code: &[Status],
    ) -> FtpResult<Response> {
        let command = command.to_string();
        debug!("Sending custom command: {}", command);
        self.perform(Command::Custom(command))?;
        self.read_response_in(expected_code)
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
    pub fn custom_data_command(
        &mut self,
        command: impl ToString,
        expected_code: &[Status],
    ) -> FtpResult<(Response, DataStream<T>)> {
        let command = command.to_string();
        debug!("Sending custom data command: {}", command);
        let data_stream = self.data_command(Command::Custom(command))?;
        let response = self.read_response_in(expected_code)?;
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
    pub fn close_data_connection(&mut self, stream: impl Read) -> FtpResult<()> {
        debug!("closing data connection");
        // Drop stream NOTE: must be done first, otherwise server won't return any response
        drop(stream);
        // mark data channel as closed
        self.data_connection_open = false;
        trace!("dropped stream");
        // Then read response
        self.read_response_in(&[Status::ClosingDataConnection, Status::RequestedFileActionOk])
            .map(|_| ())
    }

    /// Read a [`DataStream`] line by line.
    pub fn get_lines_from_stream(
        data_stream: &mut BufReader<DataStream<T>>,
    ) -> FtpResult<Vec<String>> {
        let mut lines: Vec<String> = Vec::new();

        loop {
            let mut line_buf = vec![];
            match data_stream.read_until(b'\n', &mut line_buf) {
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

    /// Read response from stream
    fn read_response(&mut self, expected_code: Status) -> FtpResult<Response> {
        self.read_response_in(&[expected_code])
    }

    /// Retrieve single line response
    fn read_response_in(&mut self, expected_code: &[Status]) -> FtpResult<Response> {
        let mut line = Vec::new();
        let mut body: Vec<u8> = Vec::new();
        self.read_line(&mut line)?;
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
            self.read_line(&mut line)?;
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

    /// Read bytes from reader until 0x0A or EOF is found
    fn read_line(&mut self, line: &mut Vec<u8>) -> FtpResult<usize> {
        self.reader
            .read_until(0x0A, line.as_mut())
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

    /// Write data to stream with command to perform
    fn perform(&mut self, command: Command) -> FtpResult<()> {
        let command = command.to_string();
        trace!("CC OUT: {}", command.trim_end_matches("\r\n"));

        let stream = self.reader.get_mut();
        stream
            .write_all(command.as_bytes())
            .map_err(FtpError::ConnectionError)
    }

    /// Execute command which send data back in a separate stream
    fn data_command(&mut self, cmd: Command) -> FtpResult<DataStream<T>> {
        // guard data connection
        self.guard_multiple_data_connections()?;
        self.data_connection_open = true;

        let stream = match self.mode {
            Mode::Active => self
                .active()
                .and_then(|listener| self.perform(cmd).map(|_| listener))
                .and_then(|listener| {
                    let start = Instant::now();
                    loop {
                        match listener.accept() {
                            Ok((stream, _)) => break Ok(stream),
                            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                if start.elapsed() > self.active_timeout {
                                    break Err(FtpError::ConnectionError(
                                        std::io::ErrorKind::WouldBlock.into(),
                                    ));
                                }
                                std::thread::sleep(Duration::from_millis(100));
                            }
                            Err(e) => break Err(FtpError::ConnectionError(e)),
                        }
                    }
                })?,
            Mode::ExtendedPassive => self
                .epsv()
                .and_then(|addr| self.perform(cmd).map(|_| addr))
                .and_then(|addr| (self.passive_stream_builder)(addr))?,
            Mode::Passive => self
                .pasv()
                .and_then(|addr| self.perform(cmd).map(|_| addr))
                .and_then(|addr| (self.passive_stream_builder)(addr))?,
        };

        #[cfg(not(feature = "secure"))]
        {
            Ok(DataStream::Tcp(stream))
        }

        #[cfg(feature = "secure")]
        match self.tls_ctx {
            Some(ref tls_ctx) => tls_ctx
                .connect(self.domain.as_ref().unwrap(), stream)
                .map(|x| DataStream::Ssl(Box::new(x)))
                .map_err(|e| FtpError::SecureError(format!("{e}"))),
            None => Ok(DataStream::Tcp(stream)),
        }
    }

    /// Create a new tcp listener and send a PORT command for it
    fn active(&mut self) -> FtpResult<TcpListener> {
        debug!("Starting local tcp listener...");
        let conn = TcpListener::bind("0.0.0.0:0").map_err(FtpError::ConnectionError)?;
        conn.set_nonblocking(true)
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
        self.perform(Command::Port(ip_port))?;
        self.read_response(Status::CommandOk)?;

        Ok(conn)
    }

    /// Runs the EPSV to enter Extended passive mode.
    fn epsv(&mut self) -> FtpResult<SocketAddr> {
        debug!("EPSV command");
        self.perform(Command::Epsv)?;
        // PASV response format : 229 Entering Extended Passive Mode (|||PORT|)
        let response: Response = self.read_response(Status::ExtendedPassiveMode)?;
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

    /// Runs the PASV command  to enter passive mode.
    fn pasv(&mut self) -> FtpResult<SocketAddr> {
        debug!("PASV command");
        self.perform(Command::Pasv)?;
        // PASV response format : 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2).
        let response = self.read_response(Status::PassiveMode)?;
        let addr = Self::parse_passive_address_from_response(response)?;
        trace!("Passive address: {addr}",);
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

    /// Parse passive address from response
    pub(crate) fn parse_passive_address_from_response(response: Response) -> FtpResult<SocketAddr> {
        let response_str = response.as_string().map_err(|_| FtpError::BadResponse)?;
        trace!("PASV response: {response_str}",);
        let caps = PASV_PORT_RE
            .captures(&response_str)
            .ok_or_else(|| FtpError::UnexpectedResponse(response.clone()))?;
        // If the regex matches we can be sure groups contains numbers
        let (oct1, oct2, oct3, oct4) = (
            caps[1].parse::<u8>().unwrap(),
            caps[2].parse::<u8>().unwrap(),
            caps[3].parse::<u8>().unwrap(),
            caps[4].parse::<u8>().unwrap(),
        );
        let (msb, lsb) = (
            caps[5].parse::<u8>().unwrap(),
            caps[6].parse::<u8>().unwrap(),
        );
        let ip = Ipv4Addr::new(oct1, oct2, oct3, oct4);
        let port = (u16::from(msb) << 8) | u16::from(lsb);
        let addr = SocketAddr::new(ip.into(), port);

        Ok(addr)
    }

    /// Execute a command which returns list of strings in a separate stream
    fn stream_lines(&mut self, cmd: Command, open_code: Status) -> FtpResult<Vec<String>> {
        let mut data_stream = BufReader::new(self.data_command(cmd)?);
        self.read_response_in(&[open_code, Status::AlreadyOpen])?;
        let lines = Self::get_lines_from_stream(&mut data_stream);
        self.finalize_retr_stream(data_stream)?;
        lines
    }

    /// Default stream builder
    fn default_passive_stream_builder() -> Box<PassiveStreamBuilder> {
        Box::new(|addr| TcpStream::connect(addr).map_err(FtpError::ConnectionError))
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

    use std::net::IpAddr;
    use std::str::FromStr;
    use std::sync::Arc;

    #[cfg(feature = "secure")]
    use pretty_assertions::assert_eq;
    use rand::distr::Alphanumeric;
    use rand::{Rng, rng};

    use super::*;
    use crate::FtpStream;
    use crate::test_container::SyncPureFtpRunner;
    use crate::types::FormatControl;

    #[test]
    fn connect() {
        crate::log_init();
        with_test_ftp_stream(|_stream| {});
    }

    #[test]
    fn test_should_parse_passive_address_from_response() {
        let response = vec![
            50, 50, 55, 32, 69, 110, 116, 101, 114, 105, 110, 103, 32, 80, 97, 115, 115, 105, 118,
            101, 32, 77, 111, 100, 101, 32, 40, 49, 50, 55, 44, 48, 44, 48, 44, 49, 44, 49, 49, 55,
            44, 53, 54, 41, 13, 10,
        ];
        let response = Response::new(Status::PassiveMode, response);

        let address = FtpStream::parse_passive_address_from_response(response)
            .expect("Failed to parse passive address");
        assert_eq!(
            address.ip(),
            IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)),
            "IP address is not correct"
        );
        assert_eq!(address.port(), 30008, "Port is not correct");

        let response = vec![
            50, 50, 55, 32, 69, 110, 116, 101, 114, 105, 110, 103, 32, 80, 97, 115, 115, 105, 118,
            101, 32, 77, 111, 100, 101, 32, 40, 53, 56, 44, 50, 52, 55, 44, 57, 50, 44, 49, 50, 50,
            44, 49, 52, 54, 44, 50, 51, 57, 41, 46, 13, 10,
        ];
        let response = Response::new(Status::PassiveMode, response);

        let address = FtpStream::parse_passive_address_from_response(response)
            .expect("Failed to parse passive address");
        assert_eq!(
            address.ip(),
            IpAddr::V4(Ipv4Addr::new(58, 247, 92, 122)),
            "IP address is not correct"
        );
        assert_eq!(address.port(), 37615, "Port is not correct");
    }

    #[test]
    fn should_change_mode() {
        with_test_ftp_stream(|stream| {
            assert_eq!(stream.mode, Mode::Passive);
            stream.set_mode(Mode::Active);
            assert_eq!(stream.mode, Mode::Active);
        })
    }

    #[test]
    fn should_connect_with_timeout() {
        crate::log_init();
        let container = SyncPureFtpRunner::start();
        let port = container.get_ftp_port();
        let url = format!("127.0.0.1:{port}");
        let addr: SocketAddr = url.parse().expect("invalid hostname");

        let mut stream = FtpStream::connect_timeout(addr, Duration::from_secs(15)).unwrap();
        assert!(stream.login("test", "test").is_ok());
        assert!(
            stream
                .get_welcome_msg()
                .unwrap()
                .contains("220 You will be disconnected after 15 minutes of inactivity.")
        );
    }

    #[test]
    fn welcome_message() {
        crate::log_init();
        with_test_ftp_stream(|stream| {
            assert!(
                stream
                    .get_welcome_msg()
                    .unwrap()
                    .contains("220 You will be disconnected after 15 minutes of inactivity.")
            );
        });
    }

    #[test]
    fn should_set_passive_nat_workaround() {
        with_test_ftp_stream(|stream| {
            stream.set_passive_nat_workaround(true);
            assert!(stream.nat_workaround);
        });
    }

    #[test]
    fn get_ref() {
        use std::time::Duration;
        with_test_ftp_stream(|stream| {
            assert!(
                stream
                    .get_ref()
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .is_ok()
            );
        });
    }

    #[test]
    fn change_wrkdir() {
        with_test_ftp_stream(|stream| {
            let wrkdir: String = stream.pwd().unwrap();
            assert!(stream.cwd("/").is_ok());
            assert_eq!(stream.pwd().unwrap().as_str(), "/");
            assert!(stream.cwd(wrkdir.as_str()).is_ok());
        })
    }

    #[test]
    fn cd_up() {
        with_test_ftp_stream(|stream| {
            let wrkdir: String = stream.pwd().unwrap();
            assert!(stream.cdup().is_ok());
            assert_eq!(stream.pwd().unwrap().as_str(), "/");
            assert!(stream.cwd(wrkdir.as_str()).is_ok());
        })
    }

    #[test]
    fn noop() {
        with_test_ftp_stream(|stream| {
            assert!(stream.noop().is_ok());
        })
    }

    #[test]
    fn make_and_remove_dir() {
        with_test_ftp_stream(|stream| {
            // Make directory
            assert!(stream.mkdir("omar").is_ok());
            // It shouldn't allow me to re-create the directory; should return error code 550
            match stream.mkdir("omar").err().unwrap() {
                FtpError::UnexpectedResponse(Response { status, body: _ }) => {
                    assert_eq!(status, Status::FileUnavailable)
                }
                err => panic!("Expected UnexpectedResponse, got {}", err),
            }
            // Remove directory
            assert!(stream.rmdir("omar").is_ok());
        })
    }

    #[test]
    fn set_transfer_type() {
        with_test_ftp_stream(|stream| {
            assert!(stream.transfer_type(FileType::Binary).is_ok());
            assert!(
                stream
                    .transfer_type(FileType::Ascii(FormatControl::Default))
                    .is_ok()
            );
        })
    }

    #[test]
    fn test_should_list_files_with_non_utf8_names() {
        with_test_ftp_stream(|stream| {
            let files = stream
                .nlst(Some("/invalid-utf8/"))
                .expect("Failed to list files");
            assert_eq!(files.len(), 1);

            // list file and parse
            let files = stream
                .list(Some("/invalid-utf8/"))
                .expect("Failed to list files");
            assert_eq!(files.len(), 1);
            // parse
            crate::list::File::from_str(files[0].as_str()).expect("Failed to parse file");
        });
    }

    #[test]
    fn should_transfer_file() {
        with_test_ftp_stream(|stream| {
            // Set transfer type to Binary
            assert!(stream.transfer_type(FileType::Binary).is_ok());
            // Write file
            let file_data = "test data\n";
            let mut reader = Cursor::new(file_data.as_bytes());
            assert!(stream.put_file("test.txt", &mut reader).is_ok());
            // Read file
            assert_eq!(
                stream
                    .retr_as_buffer("test.txt")
                    .map(|bytes| bytes.into_inner())
                    .unwrap(),
                file_data.as_bytes()
            );
            // Get size
            assert_eq!(stream.size("test.txt").unwrap(), 10);
            // Size of non-existing file
            assert!(stream.size("omarone.txt").is_err());
            // List directory
            assert_eq!(stream.list(None).unwrap().len(), 1);
            // list names
            assert_eq!(stream.nlst(None).unwrap().as_slice(), &["test.txt"]);
            // modification time
            assert!(stream.mdtm("test.txt").is_ok());
            // Remove file
            assert!(stream.rm("test.txt").is_ok());
            assert!(stream.mdtm("test.txt").is_err());
            // Write file, rename and get
            let file_data = "test data\n";
            let mut reader = Cursor::new(file_data.as_bytes());
            assert!(stream.put_file("test.txt", &mut reader).is_ok());
            // Append file
            let mut reader = Cursor::new(file_data.as_bytes());
            assert!(stream.append_file("test.txt", &mut reader).is_ok());
            // Read file
            let mut reader = stream.retr_as_stream("test.txt").unwrap();
            let mut buffer = Vec::new();
            assert!(reader.read_to_end(&mut buffer).is_ok());
            // Finalize
            assert!(stream.finalize_retr_stream(Box::new(reader)).is_ok());
            // Verify file matches
            assert_eq!(buffer.as_slice(), "test data\ntest data\n".as_bytes());
            // Rename
            assert!(stream.rename("test.txt", "toast.txt").is_ok());
            assert!(stream.rm("toast.txt").is_ok());
            // List directory again
            assert_eq!(stream.list(None).unwrap().len(), 0);
        })
    }

    #[test]
    fn should_get_feat_and_set_opts() {
        with_test_ftp_stream(|stream| {
            let features = stream.feat().expect("Failed to get features");
            assert!(features.contains_key("UTF8"));
            assert!(stream.opts("UTF8", Some("ON")).is_ok());
        })
    }

    #[test]
    fn should_resume_transfer() {
        crate::log_init();
        let container = Arc::new(SyncPureFtpRunner::start());
        let port = container.get_ftp_port();

        let url = format!("localhost:{port}");

        // init stream with mapper
        let mut stream: FtpStream = setup_stream(&url, &container);

        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).is_ok());
        // get dir
        let wrkdir = stream.pwd().unwrap();
        // put as stream
        let mut transfer_stream = stream.put_with_stream("test.bin").unwrap();
        assert_eq!(
            transfer_stream
                .write(&[0x00, 0x01, 0x02, 0x03, 0x04])
                .unwrap(),
            5
        );
        // Drop stream on purpose to simulate a failed connection
        drop(stream);
        drop(transfer_stream);
        // Re-connect to server
        let mut stream = setup_stream(&url, &container);
        // Go back to previous dir
        assert!(stream.cwd(wrkdir).is_ok());
        // Set transfer type to Binary
        assert!(stream.transfer_type(FileType::Binary).is_ok());
        // Resume transfer
        assert!(stream.resume_transfer(5).is_ok());
        // Reopen stream
        let mut transfer_stream = stream.put_with_stream("test.bin").unwrap();
        assert_eq!(
            transfer_stream
                .write(&[0x05, 0x06, 0x07, 0x08, 0x09, 0x0a])
                .unwrap(),
            6
        );
        // Finalize
        assert!(stream.finalize_put_stream(transfer_stream).is_ok());
        // Get size
        //assert_eq!(stream.size("test.bin").unwrap(), 11);
        // Remove file
        assert!(stream.rm("test.bin").is_ok());

        finalize_stream(stream);
    }

    #[test]
    fn should_transfer_with_extended_passive_mode() {
        with_test_ftp_stream(|stream| {
            // Set transfer type to Binary
            assert!(stream.transfer_type(FileType::Binary).is_ok());
            stream.set_mode(Mode::ExtendedPassive);
            // Write file
            let file_data = "test data\n";
            let mut reader = Cursor::new(file_data.as_bytes());
            assert!(stream.put_file("test.txt", &mut reader).is_ok());
            // Remove file
            assert!(stream.rm("test.txt").is_ok());
        })
    }

    #[test]
    fn test_should_perform_custom_command() {
        with_test_ftp_stream(|stream| {
            let command = "PWD";
            assert!(
                stream
                    .custom_command(command, &[Status::PathCreated])
                    .is_ok()
            );
        });
    }

    #[test]
    fn test_should_perform_custom_data_command() {
        with_test_ftp_stream(|stream| {
            let command = "LIST";
            let (response, data_stream) = stream
                .custom_data_command(command, &[Status::AboutToSend])
                .expect("Failed to perform custom data command");
            assert_eq!(response.status, Status::AboutToSend);
            let mut reader = BufReader::new(data_stream);
            FtpStream::get_lines_from_stream(&mut reader).expect("Failed to get lines from stream");
            // finalize
            assert!(stream.close_data_connection(reader).is_ok());
        });
    }

    #[test]
    fn test_should_prevent_multiple_data_connections() {
        with_test_ftp_stream(|stream| {
            let command = "LIST";

            let (_, data_stream) = stream
                .custom_data_command(command, &[Status::AboutToSend])
                .expect("Failed to perform custom data command");
            let mut reader = BufReader::new(data_stream);
            // Try to open another data connection without closing the previous one
            match stream.custom_data_command(command, &[Status::AboutToSend]) {
                Err(FtpError::DataConnectionAlreadyOpen) => {}
                _ => panic!("Expected DataConnectionAlreadyOpen error"),
            }

            // try with all other data commands
            match stream.retr_as_stream("somefile.txt") {
                Err(FtpError::DataConnectionAlreadyOpen) => {}
                _ => panic!("Expected DataConnectionAlreadyOpen error"),
            }

            match stream.put_with_stream("somefile.txt") {
                Err(FtpError::DataConnectionAlreadyOpen) => {}
                _ => panic!("Expected DataConnectionAlreadyOpen error"),
            }

            match stream.append_with_stream("somefile.txt") {
                Err(FtpError::DataConnectionAlreadyOpen) => {}
                _ => panic!("Expected DataConnectionAlreadyOpen error"),
            }

            assert!(stream.close_data_connection(reader).is_ok());
        });
    }

    #[test]
    fn test_should_free_data_connection_after_close() {
        with_test_ftp_stream(|stream| {
            let command = "LIST";

            let (response, data_stream) = stream
                .custom_data_command(command, &[Status::AboutToSend])
                .expect("Failed to perform custom data command");
            assert_eq!(response.status, Status::AboutToSend);
            let mut reader = BufReader::new(data_stream);
            FtpStream::get_lines_from_stream(&mut reader).expect("Failed to get lines from stream");
            // finalize
            assert!(stream.close_data_connection(reader).is_ok());

            // Now it should be possible to open another data connection
            let (response, data_stream) = stream
                .custom_data_command(command, &[Status::AboutToSend])
                .expect("Failed to perform custom data command");
            assert_eq!(response.status, Status::AboutToSend);
            let mut reader = BufReader::new(data_stream);
            FtpStream::get_lines_from_stream(&mut reader).expect("Failed to get lines from stream");
            // finalize
            assert!(stream.close_data_connection(reader).is_ok());
        });
    }

    // -- test utils

    fn with_test_ftp_stream<F>(f: F)
    where
        F: FnOnce(&mut FtpStream),
    {
        crate::log_init();
        let container = Arc::new(SyncPureFtpRunner::start());
        let port = container.get_ftp_port();

        // init stream with mapper
        let mut stream: FtpStream = setup_stream(&format!("localhost:{port}"), &container);

        f(&mut stream);
        finalize_stream(stream);

        drop(container);
    }

    fn setup_stream(url: &str, container: &Arc<SyncPureFtpRunner>) -> FtpStream {
        let mut ftp_stream = FtpStream::connect(url).unwrap();
        assert!(ftp_stream.login("test", "test").is_ok());
        // Create wrkdir
        let tempdir: String = generate_tempdir();
        assert!(ftp_stream.mkdir(tempdir.as_str()).is_ok());
        // Change directory
        assert!(ftp_stream.cwd(tempdir.as_str()).is_ok());

        let container_t = container.clone();

        ftp_stream.passive_stream_builder(move |addr| {
            let mut addr = addr.clone();
            let port = addr.port();
            let mapped = container_t.get_mapped_port(port);

            addr.set_port(mapped);

            info!("mapped port {port} to {mapped} for PASV");

            // open stream to this address instead
            TcpStream::connect(addr).map_err(FtpError::ConnectionError)
        })
    }

    fn finalize_stream(mut stream: FtpStream) {
        assert!(stream.quit().is_ok());
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

    /// Test if the stream is Send
    fn is_send<T: Send>(_send: T) {}

    fn is_sync<T: Sync>(_sync: T) {}

    #[test]
    #[ignore = "just needs to compile"]
    fn test_ftp_stream_should_be_send() {
        crate::log_init();

        let ftp_stream = FtpStream::connect("test.rebex.net:21")
            .unwrap()
            .passive_stream_builder(|addr| {
                println!("Connecting to {}", addr);
                TcpStream::connect(addr).map_err(FtpError::ConnectionError)
            });

        is_send::<FtpStream>(ftp_stream);
    }

    #[test]
    #[ignore = "just needs to compile"]
    fn test_ftp_stream_should_be_sync() {
        crate::log_init();
        let ftp_stream = FtpStream::connect("test.rebex.net:21")
            .unwrap()
            .passive_stream_builder(|addr| {
                println!("Connecting to {}", addr);
                TcpStream::connect(addr).map_err(FtpError::ConnectionError)
            });

        is_sync::<FtpStream>(ftp_stream);
    }
}
