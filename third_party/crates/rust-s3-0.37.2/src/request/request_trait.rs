use base64::Engine;
use base64::engine::general_purpose;
use hmac::Mac;
use quick_xml::se::to_string;
use std::collections::HashMap;
#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
use std::pin::Pin;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc2822;
use url::Url;

use crate::LONG_DATETIME;
use crate::bucket::Bucket;
use crate::command::Command;
use crate::error::S3Error;
use crate::signing;
use bytes::Bytes;
use http::HeaderMap;
use http::header::{
    ACCEPT, AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE, DATE, HOST, HeaderName, RANGE,
};
use std::fmt::Write as _;

#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
use futures_util::Stream;
#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
use futures_util::stream::{self, StreamExt};

#[derive(Debug)]

pub struct ResponseData {
    bytes: Bytes,
    status_code: u16,
    headers: HashMap<String, String>,
}

#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
pub type DataStream = Pin<Box<dyn Stream<Item = StreamItem> + Send>>;
#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
pub type StreamItem = Result<Bytes, S3Error>;

#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
pub struct ResponseDataStream {
    pub bytes: DataStream,
    pub status_code: u16,
}

#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
impl ResponseDataStream {
    pub fn bytes(&mut self) -> &mut DataStream {
        &mut self.bytes
    }
}

impl From<ResponseData> for Vec<u8> {
    fn from(data: ResponseData) -> Vec<u8> {
        data.to_vec()
    }
}

impl ResponseData {
    pub fn new(bytes: Bytes, status_code: u16, headers: HashMap<String, String>) -> ResponseData {
        ResponseData {
            bytes,
            status_code,
            headers,
        }
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.bytes
    }

    pub fn to_vec(self) -> Vec<u8> {
        self.bytes.to_vec()
    }

    pub fn bytes(&self) -> &Bytes {
        &self.bytes
    }

    pub fn bytes_mut(&mut self) -> &mut Bytes {
        &mut self.bytes
    }

    pub fn into_bytes(self) -> Bytes {
        self.bytes
    }

    pub fn status_code(&self) -> u16 {
        self.status_code
    }

    pub fn as_str(&self) -> Result<&str, std::str::Utf8Error> {
        std::str::from_utf8(self.as_slice())
    }

    pub fn to_string(&self) -> Result<String, std::str::Utf8Error> {
        std::str::from_utf8(self.as_slice()).map(|s| s.to_string())
    }

    pub fn headers(&self) -> HashMap<String, String> {
        self.headers.clone()
    }
}

use std::fmt;

impl fmt::Display for ResponseData {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "Status code: {}\n Data: {}",
            self.status_code(),
            self.to_string()
                .unwrap_or_else(|_| "Data could not be cast to UTF string".to_string())
        )
    }
}

#[cfg(feature = "with-tokio")]
impl tokio::io::AsyncRead for ResponseDataStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if buf.remaining() == 0 {
            return std::task::Poll::Ready(Ok(()));
        }

        loop {
            match Stream::poll_next(self.bytes.as_mut(), cx) {
                std::task::Poll::Ready(Some(Ok(chunk))) => {
                    if chunk.is_empty() {
                        continue;
                    }

                    let amt = std::cmp::min(chunk.len(), buf.remaining());
                    buf.put_slice(&chunk[..amt]);

                    if amt < chunk.len() {
                        let remainder = chunk.slice(amt..);
                        let previous_stream =
                            std::mem::replace(&mut self.bytes, Box::pin(stream::empty()));
                        self.bytes = Box::pin(
                            stream::once(async move { Ok(remainder) }).chain(previous_stream),
                        );
                    }

                    return std::task::Poll::Ready(Ok(()));
                }
                std::task::Poll::Ready(Some(Err(error))) => {
                    return std::task::Poll::Ready(Err(std::io::Error::other(error)));
                }
                std::task::Poll::Ready(None) => {
                    return std::task::Poll::Ready(Ok(()));
                }
                std::task::Poll::Pending => return std::task::Poll::Pending,
            }
        }
    }
}

#[cfg(feature = "with-async-std")]
impl async_std::io::Read for ResponseDataStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut [u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        if buf.is_empty() {
            return std::task::Poll::Ready(Ok(0));
        }

        loop {
            match Stream::poll_next(self.bytes.as_mut(), cx) {
                std::task::Poll::Ready(Some(Ok(chunk))) => {
                    if chunk.is_empty() {
                        continue;
                    }

                    let amt = std::cmp::min(chunk.len(), buf.len());
                    buf[..amt].copy_from_slice(&chunk[..amt]);

                    if amt < chunk.len() {
                        let remainder = chunk.slice(amt..);
                        let previous_stream =
                            std::mem::replace(&mut self.bytes, Box::pin(stream::empty()));
                        self.bytes = Box::pin(
                            stream::once(async move { Ok(remainder) }).chain(previous_stream),
                        );
                    }

                    return std::task::Poll::Ready(Ok(amt));
                }
                std::task::Poll::Ready(Some(Err(error))) => {
                    return std::task::Poll::Ready(Err(std::io::Error::other(error)));
                }
                std::task::Poll::Ready(None) => {
                    return std::task::Poll::Ready(Ok(0));
                }
                std::task::Poll::Pending => return std::task::Poll::Pending,
            }
        }
    }
}

#[maybe_async::maybe_async]
pub trait Request {
    type Response;
    type HeaderMap;

    async fn response(&self) -> Result<Self::Response, S3Error>;
    async fn response_data(&self, etag: bool) -> Result<ResponseData, S3Error>;
    #[cfg(feature = "with-tokio")]
    async fn response_data_to_writer<T: tokio::io::AsyncWrite + Send + Unpin + ?Sized>(
        &self,
        writer: &mut T,
    ) -> Result<u16, S3Error>;
    #[cfg(feature = "with-async-std")]
    async fn response_data_to_writer<T: async_std::io::Write + Send + Unpin + ?Sized>(
        &self,
        writer: &mut T,
    ) -> Result<u16, S3Error>;
    #[cfg(feature = "sync")]
    fn response_data_to_writer<T: std::io::Write + Send + ?Sized>(
        &self,
        writer: &mut T,
    ) -> Result<u16, S3Error>;
    #[cfg(any(feature = "with-async-std", feature = "with-tokio"))]
    async fn response_data_to_stream(&self) -> Result<ResponseDataStream, S3Error>;
    async fn response_header(&self) -> Result<(Self::HeaderMap, u16), S3Error>;
    async fn response_status(&self) -> Result<u16, S3Error> {
        let (_, status_code) = self.response_header().await?;
        Ok(status_code)
    }
    fn datetime(&self) -> OffsetDateTime;
    fn bucket(&self) -> Bucket;
    fn command(&self) -> Command<'_>;
    fn path(&self) -> String;

    async fn signing_key(&self) -> Result<Vec<u8>, S3Error> {
        signing::signing_key(
            &self.datetime(),
            &self
                .bucket()
                .secret_key()
                .await?
                .expect("Secret key must be provided to sign headers, found None"),
            &self.bucket().region(),
            "s3",
        )
    }

    fn request_body(&self) -> Result<Vec<u8>, S3Error> {
        let result = if let Command::PutObject { content, .. } = self.command() {
            Vec::from(content)
        } else if let Command::PutObjectTagging { tags } = self.command() {
            Vec::from(tags)
        } else if let Command::UploadPart { content, .. } = self.command() {
            Vec::from(content)
        } else if let Command::CompleteMultipartUpload { data, .. } = &self.command() {
            let body = data.to_string();
            body.as_bytes().to_vec()
        } else if let Command::CreateBucket { config } = &self.command() {
            if let Some(payload) = config.location_constraint_payload() {
                Vec::from(payload)
            } else {
                Vec::new()
            }
        } else if let Command::PutBucketLifecycle { configuration, .. } = &self.command() {
            quick_xml::se::to_string(configuration)?.as_bytes().to_vec()
        } else if let Command::PutBucketCors { configuration, .. } = &self.command() {
            let cors = configuration.to_string();
            cors.as_bytes().to_vec()
        } else if let Command::DeleteObjects { data } = &self.command() {
            data.to_string().as_bytes().to_vec()
        } else {
            Vec::new()
        };
        Ok(result)
    }

    fn long_date(&self) -> Result<String, S3Error> {
        Ok(self.datetime().format(LONG_DATETIME)?)
    }

    fn string_to_sign(&self, request: &str) -> Result<String, S3Error> {
        signing::string_to_sign(&self.datetime(), &self.bucket().region(), request)
    }

    fn host_header(&self) -> String {
        self.bucket().host()
    }

    #[maybe_async::async_impl]
    async fn presigned(&self) -> Result<String, S3Error> {
        let (expiry, custom_headers, custom_queries) = match self.command() {
            Command::PresignGet {
                expiry_secs,
                custom_queries,
            } => (expiry_secs, None, custom_queries),
            Command::PresignPut {
                expiry_secs,
                custom_headers,
                custom_queries,
            } => (expiry_secs, custom_headers, custom_queries),
            Command::PresignDelete { expiry_secs } => (expiry_secs, None, None),
            _ => unreachable!(),
        };

        let url = self
            .presigned_url_no_sig(expiry, custom_headers.as_ref(), custom_queries.as_ref())
            .await?;

        // Build the URL string preserving the original host (including standard ports)
        // The Url type drops standard ports when converting to string, but we need them
        // for signature validation
        let url_str = if let awsregion::Region::Custom { ref endpoint, .. } = self.bucket().region()
        {
            // Check if we need to preserve a standard port
            if (endpoint.contains(":80") && url.scheme() == "http" && url.port().is_none())
                || (endpoint.contains(":443") && url.scheme() == "https" && url.port().is_none())
            {
                // Rebuild the URL with the original host from the endpoint
                let host = self.bucket().host();
                format!(
                    "{}://{}{}{}",
                    url.scheme(),
                    host,
                    url.path(),
                    url.query().map(|q| format!("?{}", q)).unwrap_or_default()
                )
            } else {
                url.to_string()
            }
        } else {
            url.to_string()
        };

        Ok(format!(
            "{}&X-Amz-Signature={}",
            url_str,
            self.presigned_authorization(custom_headers.as_ref())
                .await?
        ))
    }

    #[maybe_async::sync_impl]
    async fn presigned(&self) -> Result<String, S3Error> {
        let (expiry, custom_headers, custom_queries) = match self.command() {
            Command::PresignGet {
                expiry_secs,
                custom_queries,
            } => (expiry_secs, None, custom_queries),
            Command::PresignPut {
                expiry_secs,
                custom_headers,
                ..
            } => (expiry_secs, custom_headers, None),
            Command::PresignDelete { expiry_secs } => (expiry_secs, None, None),
            _ => unreachable!(),
        };

        let url =
            self.presigned_url_no_sig(expiry, custom_headers.as_ref(), custom_queries.as_ref())?;

        // Build the URL string preserving the original host (including standard ports)
        // The Url type drops standard ports when converting to string, but we need them
        // for signature validation
        let url_str = if let awsregion::Region::Custom { ref endpoint, .. } = self.bucket().region()
        {
            // Check if we need to preserve a standard port
            if (endpoint.contains(":80") && url.scheme() == "http" && url.port().is_none())
                || (endpoint.contains(":443") && url.scheme() == "https" && url.port().is_none())
            {
                // Rebuild the URL with the original host from the endpoint
                let host = self.bucket().host();
                format!(
                    "{}://{}{}{}",
                    url.scheme(),
                    host,
                    url.path(),
                    url.query().map(|q| format!("?{}", q)).unwrap_or_default()
                )
            } else {
                url.to_string()
            }
        } else {
            url.to_string()
        };

        Ok(format!(
            "{}&X-Amz-Signature={}",
            url_str,
            self.presigned_authorization(custom_headers.as_ref())?
        ))
    }

    async fn presigned_authorization(
        &self,
        custom_headers: Option<&HeaderMap>,
    ) -> Result<String, S3Error> {
        let mut headers = HeaderMap::new();
        let host_header = self.host_header();
        headers.insert(HOST, host_header.parse()?);
        if let Some(custom_headers) = custom_headers {
            for (k, v) in custom_headers.iter() {
                headers.insert(k.clone(), v.clone());
            }
        }
        let canonical_request = self.presigned_canonical_request(&headers).await?;
        let string_to_sign = self.string_to_sign(&canonical_request)?;
        let mut hmac = signing::HmacSha256::new_from_slice(&self.signing_key().await?)?;
        hmac.update(string_to_sign.as_bytes());
        let signature = hex::encode(hmac.finalize().into_bytes());
        // let signed_header = signing::signed_header_string(&headers);
        Ok(signature)
    }

    async fn presigned_canonical_request(&self, headers: &HeaderMap) -> Result<String, S3Error> {
        let (expiry, custom_headers, custom_queries) = match self.command() {
            Command::PresignGet {
                expiry_secs,
                custom_queries,
            } => (expiry_secs, None, custom_queries),
            Command::PresignPut {
                expiry_secs,
                custom_headers,
                custom_queries,
            } => (expiry_secs, custom_headers, custom_queries),
            Command::PresignDelete { expiry_secs } => (expiry_secs, None, None),
            _ => unreachable!(),
        };

        signing::canonical_request(
            &self.command().http_verb().to_string(),
            &self
                .presigned_url_no_sig(expiry, custom_headers.as_ref(), custom_queries.as_ref())
                .await?,
            headers,
            "UNSIGNED-PAYLOAD",
        )
    }

    #[maybe_async::async_impl]
    async fn presigned_url_no_sig(
        &self,
        expiry: u32,
        custom_headers: Option<&HeaderMap>,
        custom_queries: Option<&HashMap<String, String>>,
    ) -> Result<Url, S3Error> {
        let bucket = self.bucket();
        let token = if let Some(security_token) = bucket.security_token().await? {
            Some(security_token)
        } else {
            bucket.session_token().await?
        };
        let url = Url::parse(&format!(
            "{}{}{}",
            self.url()?,
            &signing::authorization_query_params_no_sig(
                &self.bucket().access_key().await?.unwrap_or_default(),
                &self.datetime(),
                &self.bucket().region(),
                expiry,
                custom_headers,
                token.as_ref()
            )?,
            &signing::flatten_queries(custom_queries)?,
        ))?;

        Ok(url)
    }

    #[maybe_async::sync_impl]
    fn presigned_url_no_sig(
        &self,
        expiry: u32,
        custom_headers: Option<&HeaderMap>,
        custom_queries: Option<&HashMap<String, String>>,
    ) -> Result<Url, S3Error> {
        let bucket = self.bucket();
        let token = if let Some(security_token) = bucket.security_token()? {
            Some(security_token)
        } else {
            bucket.session_token()?
        };
        let url = Url::parse(&format!(
            "{}{}{}",
            self.url()?,
            &signing::authorization_query_params_no_sig(
                &self.bucket().access_key()?.unwrap_or_default(),
                &self.datetime(),
                &self.bucket().region(),
                expiry,
                custom_headers,
                token.as_ref()
            )?,
            &signing::flatten_queries(custom_queries)?,
        ))?;

        Ok(url)
    }

    fn url(&self) -> Result<Url, S3Error> {
        let mut url_str = self.bucket().url();

        if let Command::ListBuckets { .. } = self.command() {
            return Ok(Url::parse(&url_str)?);
        }

        if let Command::CreateBucket { .. } = self.command() {
            return Ok(Url::parse(&url_str)?);
        }

        let path = if self.path().starts_with('/') {
            self.path()[1..].to_string()
        } else {
            self.path()[..].to_string()
        };

        url_str.push('/');
        url_str.push_str(&signing::uri_encode(&path, false));

        // Append to url_path
        #[allow(clippy::collapsible_match)]
        match self.command() {
            Command::InitiateMultipartUpload { .. } | Command::ListMultipartUploads { .. } => {
                url_str.push_str("?uploads")
            }
            Command::AbortMultipartUpload { upload_id } => {
                write!(url_str, "?uploadId={}", upload_id).expect("Could not write to url_str");
            }
            Command::CompleteMultipartUpload { upload_id, .. } => {
                write!(url_str, "?uploadId={}", upload_id).expect("Could not write to url_str");
            }
            Command::GetObjectTorrent => url_str.push_str("?torrent"),
            Command::PutObject { multipart, .. } => {
                if let Some(multipart) = multipart {
                    url_str.push_str(&multipart.query_string())
                }
            }
            Command::GetBucketLifecycle
            | Command::PutBucketLifecycle { .. }
            | Command::DeleteBucketLifecycle => {
                url_str.push_str("?lifecycle");
            }
            Command::GetBucketCors { .. }
            | Command::PutBucketCors { .. }
            | Command::DeleteBucketCors { .. } => {
                url_str.push_str("?cors");
            }
            Command::GetObjectAttributes { version_id, .. } => {
                if let Some(version_id) = version_id {
                    url_str.push_str(&format!("?attributes&versionId={}", version_id));
                } else {
                    url_str.push_str("?attributes&versionId=null");
                }
            }
            Command::HeadObject => {}
            Command::DeleteObject => {}
            Command::DeleteObjectTagging => {}
            Command::GetObject => {}
            Command::GetObjectRange { .. } => {}
            Command::GetObjectTagging => {}
            Command::ListObjects { .. } => {}
            Command::ListObjectsV2 { .. } => {}
            Command::GetBucketLocation => {}
            Command::PresignGet { .. } => {}
            Command::PresignPut { .. } => {}
            Command::PresignDelete { .. } => {}
            Command::DeleteBucket => {}
            Command::ListBuckets => {}
            Command::CopyObject { .. } => {}
            Command::PutObjectTagging { .. } => {}
            Command::UploadPart { .. } => {}
            Command::CreateBucket { .. } => {}
            Command::DeleteObjects { .. } => {
                url_str.push_str("?delete");
            }
        }

        let mut url = Url::parse(&url_str)?;

        for (key, value) in &self.bucket().extra_query {
            url.query_pairs_mut().append_pair(key, value);
        }

        if let Command::ListObjectsV2 {
            prefix,
            delimiter,
            continuation_token,
            start_after,
            max_keys,
        } = self.command().clone()
        {
            let mut query_pairs = url.query_pairs_mut();
            delimiter.map(|d| query_pairs.append_pair("delimiter", &d));

            query_pairs.append_pair("prefix", &prefix);
            query_pairs.append_pair("list-type", "2");
            if let Some(token) = continuation_token {
                query_pairs.append_pair("continuation-token", &token);
            }
            if let Some(start_after) = start_after {
                query_pairs.append_pair("start-after", &start_after);
            }
            if let Some(max_keys) = max_keys {
                query_pairs.append_pair("max-keys", &max_keys.to_string());
            }
        }

        if let Command::ListObjects {
            prefix,
            delimiter,
            marker,
            max_keys,
        } = self.command().clone()
        {
            let mut query_pairs = url.query_pairs_mut();
            delimiter.map(|d| query_pairs.append_pair("delimiter", &d));

            query_pairs.append_pair("prefix", &prefix);
            if let Some(marker) = marker {
                query_pairs.append_pair("marker", &marker);
            }
            if let Some(max_keys) = max_keys {
                query_pairs.append_pair("max-keys", &max_keys.to_string());
            }
        }

        match self.command() {
            Command::ListMultipartUploads {
                prefix,
                delimiter,
                key_marker,
                max_uploads,
            } => {
                let mut query_pairs = url.query_pairs_mut();
                delimiter.map(|d| query_pairs.append_pair("delimiter", d));
                if let Some(prefix) = prefix {
                    query_pairs.append_pair("prefix", prefix);
                }
                if let Some(key_marker) = key_marker {
                    query_pairs.append_pair("key-marker", &key_marker);
                }
                if let Some(max_uploads) = max_uploads {
                    query_pairs.append_pair("max-uploads", max_uploads.to_string().as_str());
                }
            }
            Command::PutObjectTagging { .. }
            | Command::GetObjectTagging
            | Command::DeleteObjectTagging => {
                url.query_pairs_mut().append_pair("tagging", "");
            }
            _ => {}
        }

        Ok(url)
    }

    fn canonical_request(&self, headers: &HeaderMap) -> Result<String, S3Error> {
        signing::canonical_request(
            &self.command().http_verb().to_string(),
            &self.url()?,
            headers,
            &self.command().sha256()?,
        )
    }

    #[maybe_async::maybe_async]
    async fn authorization(&self, headers: &HeaderMap) -> Result<String, S3Error> {
        let canonical_request = self.canonical_request(headers)?;
        let string_to_sign = self.string_to_sign(&canonical_request)?;
        let mut hmac = signing::HmacSha256::new_from_slice(&self.signing_key().await?)?;
        hmac.update(string_to_sign.as_bytes());
        let signature = hex::encode(hmac.finalize().into_bytes());
        let signed_header = signing::signed_header_string(headers);
        signing::authorization_header(
            &self
                .bucket()
                .access_key()
                .await?
                .expect("No access_key provided"),
            &self.datetime(),
            &self.bucket().region(),
            &signed_header,
            &signature,
        )
    }

    #[maybe_async::maybe_async]
    async fn headers(&self) -> Result<HeaderMap, S3Error> {
        // Generate this once, but it's used in more than one place.
        let sha256 = self.command().sha256()?;

        // Start with extra_headers, that way our headers replace anything with
        // the same name.

        let mut headers = HeaderMap::new();

        for (k, v) in self.bucket().extra_headers.iter() {
            if k.as_str().starts_with("x-amz-meta-") {
                // metadata is invalid on any multipart command other than initiate
                match self.command() {
                    Command::UploadPart { .. }
                    | Command::AbortMultipartUpload { .. }
                    | Command::CompleteMultipartUpload { .. }
                    | Command::PutObject {
                        multipart: Some(_), ..
                    } => continue,
                    _ => (),
                }
            }
            headers.insert(k.clone(), v.clone());
        }

        // Append custom headers for PUT request if any
        if let Command::PutObject { custom_headers, .. } = self.command()
            && let Some(custom_headers) = custom_headers
        {
            for (k, v) in custom_headers.iter() {
                headers.insert(k.clone(), v.clone());
            }
        }

        let host_header = self.host_header();

        headers.insert(HOST, host_header.parse()?);

        match self.command() {
            Command::CopyObject { from } => {
                headers.insert(HeaderName::from_static("x-amz-copy-source"), from.parse()?);
            }
            Command::ListObjects { .. } => {}
            Command::ListObjectsV2 { .. } => {}
            Command::HeadObject => {}
            Command::GetObject => {}
            Command::GetObjectTagging => {}
            Command::GetBucketLocation => {}
            Command::ListBuckets => {}
            _ => {
                headers.insert(
                    CONTENT_LENGTH,
                    self.command().content_length()?.to_string().parse()?,
                );
                headers.insert(CONTENT_TYPE, self.command().content_type().parse()?);
            }
        }
        headers.insert(
            HeaderName::from_static("x-amz-content-sha256"),
            sha256.parse()?,
        );
        headers.insert(
            HeaderName::from_static("x-amz-date"),
            self.long_date()?.parse()?,
        );

        if let Some(session_token) = self.bucket().session_token().await? {
            headers.insert(
                HeaderName::from_static("x-amz-security-token"),
                session_token.parse()?,
            );
        } else if let Some(security_token) = self.bucket().security_token().await? {
            headers.insert(
                HeaderName::from_static("x-amz-security-token"),
                security_token.parse()?,
            );
        }

        if let Command::PutObjectTagging { tags } = self.command() {
            let digest = md5::compute(tags);
            let hash = general_purpose::STANDARD.encode(digest.as_ref());
            headers.insert(HeaderName::from_static("content-md5"), hash.parse()?);
        } else if let Command::PutObject { content, .. } = self.command() {
            let digest = md5::compute(content);
            let hash = general_purpose::STANDARD.encode(digest.as_ref());
            headers.insert(HeaderName::from_static("content-md5"), hash.parse()?);
        } else if let Command::UploadPart { content, .. } = self.command() {
            let digest = md5::compute(content);
            let hash = general_purpose::STANDARD.encode(digest.as_ref());
            headers.insert(HeaderName::from_static("content-md5"), hash.parse()?);
        } else if let Command::GetObject {} = self.command() {
            headers.insert(ACCEPT, "application/octet-stream".to_string().parse()?);
        // headers.insert(header::ACCEPT_CHARSET, HeaderValue::from_str("UTF-8")?);
        } else if let Command::GetObjectRange { start, end } = self.command() {
            headers.insert(ACCEPT, "application/octet-stream".to_string().parse()?);

            let mut range = format!("bytes={}-", start);

            if let Some(end) = end {
                range.push_str(&end.to_string());
            }

            headers.insert(RANGE, range.parse()?);
        } else if let Command::CreateBucket { ref config } = self.command() {
            config.add_headers(&mut headers)?;
        } else if let Command::PutBucketLifecycle { ref configuration } = self.command() {
            let digest = md5::compute(to_string(configuration)?.as_bytes());
            let hash = general_purpose::STANDARD.encode(digest.as_ref());
            headers.insert(HeaderName::from_static("content-md5"), hash.parse()?);
        } else if let Command::PutBucketCors {
            expected_bucket_owner,
            configuration,
            ..
        } = self.command()
        {
            let digest = md5::compute(configuration.to_string().as_bytes());
            let hash = general_purpose::STANDARD.encode(digest.as_ref());
            headers.insert(HeaderName::from_static("content-md5"), hash.parse()?);

            headers.insert(
                HeaderName::from_static("x-amz-expected-bucket-owner"),
                expected_bucket_owner.parse()?,
            );
        } else if let Command::GetBucketCors {
            expected_bucket_owner,
        } = self.command()
        {
            headers.insert(
                HeaderName::from_static("x-amz-expected-bucket-owner"),
                expected_bucket_owner.parse()?,
            );
        } else if let Command::DeleteBucketCors {
            expected_bucket_owner,
        } = self.command()
        {
            headers.insert(
                HeaderName::from_static("x-amz-expected-bucket-owner"),
                expected_bucket_owner.parse()?,
            );
        } else if let Command::GetObjectAttributes {
            expected_bucket_owner,
            ..
        } = self.command()
        {
            headers.insert(
                HeaderName::from_static("x-amz-expected-bucket-owner"),
                expected_bucket_owner.parse()?,
            );
            headers.insert(
                HeaderName::from_static("x-amz-object-attributes"),
                "ETag".parse()?,
            );
        } else if let Command::DeleteObjects { ref data } = self.command() {
            let body = data.to_string();
            let digest = md5::compute(body.as_bytes());
            let hash = general_purpose::STANDARD.encode(digest.as_ref());
            headers.insert(HeaderName::from_static("content-md5"), hash.parse()?);
        }

        // This must be last, as it signs the other headers, omitted if no secret key is provided
        if self.bucket().secret_key().await?.is_some() {
            let authorization = self.authorization(&headers).await?;
            headers.insert(AUTHORIZATION, authorization.parse()?);
        }

        // The format of RFC2822 is somewhat malleable, so including it in
        // signed headers can cause signature mismatches. We do include the
        // X-Amz-Date header, so requests are still properly limited to a date
        // range and can't be used again e.g. reply attacks. Adding this header
        // after the generation of the Authorization header leaves it out of
        // the signed headers.
        headers.insert(DATE, self.datetime().format(&Rfc2822)?.parse()?);

        Ok(headers)
    }
}

#[cfg(all(test, feature = "with-tokio"))]
mod tests {
    use super::*;
    use bytes::Bytes;
    use futures_util::stream;
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn test_async_read_implementation() {
        // Create a mock stream with test data
        let chunks = vec![
            Ok(Bytes::from("Hello, ")),
            Ok(Bytes::from("World!")),
            Ok(Bytes::from(" This is a test.")),
        ];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        // Read all data using AsyncRead
        let mut buffer = Vec::new();
        response_stream.read_to_end(&mut buffer).await.unwrap();

        assert_eq!(buffer, b"Hello, World! This is a test.");
    }

    #[tokio::test]
    async fn test_async_read_with_small_buffer_preserves_large_chunk() {
        let expected = b"This is a much longer string that won't fit in a small buffer";
        let chunks = vec![Ok(Bytes::copy_from_slice(expected))];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        let mut output = Vec::new();
        let mut buffer = [0u8; 10];

        loop {
            let n = response_stream.read(&mut buffer).await.unwrap();
            if n == 0 {
                break;
            }
            output.extend_from_slice(&buffer[..n]);
        }

        assert_eq!(output, expected);
    }

    #[tokio::test]
    async fn test_async_read_with_error() {
        use crate::error::S3Error;

        // Create a stream that returns an error
        let chunks: Vec<Result<Bytes, S3Error>> = vec![
            Ok(Bytes::from("Some data")),
            Err(S3Error::Io(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Test error",
            ))),
        ];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        // First read should succeed
        let mut buffer = [0u8; 20];
        let n = response_stream.read(&mut buffer).await.unwrap();
        assert_eq!(n, 9);
        assert_eq!(&buffer[..n], b"Some data");

        // Second read should fail with an error
        let result = response_stream.read(&mut buffer).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_async_read_copy() {
        // Test using tokio::io::copy which is a common use case
        let chunks = vec![
            Ok(Bytes::from("First chunk\n")),
            Ok(Bytes::from("Second chunk\n")),
            Ok(Bytes::from("Third chunk\n")),
        ];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        let mut output = Vec::new();
        tokio::io::copy(&mut response_stream, &mut output)
            .await
            .unwrap();

        assert_eq!(output, b"First chunk\nSecond chunk\nThird chunk\n");
    }
}

#[cfg(all(test, feature = "with-async-std"))]
mod async_std_tests {
    use super::*;
    use async_std::io::ReadExt;
    use bytes::Bytes;
    use futures_util::stream;

    #[async_std::test]
    async fn test_async_read_implementation() {
        // Create a mock stream with test data
        let chunks = vec![
            Ok(Bytes::from("Hello, ")),
            Ok(Bytes::from("World!")),
            Ok(Bytes::from(" This is a test.")),
        ];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        // Read all data using AsyncRead
        let mut buffer = Vec::new();
        response_stream.read_to_end(&mut buffer).await.unwrap();

        assert_eq!(buffer, b"Hello, World! This is a test.");
    }

    #[async_std::test]
    async fn test_async_read_with_small_buffer_preserves_large_chunk() {
        let expected = b"This is a much longer string that won't fit in a small buffer";
        let chunks = vec![Ok(Bytes::copy_from_slice(expected))];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        let mut output = Vec::new();
        let mut buffer = [0u8; 10];

        loop {
            let n = response_stream.read(&mut buffer).await.unwrap();
            if n == 0 {
                break;
            }
            output.extend_from_slice(&buffer[..n]);
        }

        assert_eq!(output, expected);
    }

    #[async_std::test]
    async fn test_async_read_with_error() {
        use crate::error::S3Error;

        // Create a stream that returns an error
        let chunks: Vec<Result<Bytes, S3Error>> = vec![
            Ok(Bytes::from("Some data")),
            Err(S3Error::Io(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Test error",
            ))),
        ];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        // First read should succeed
        let mut buffer = [0u8; 20];
        let n = response_stream.read(&mut buffer).await.unwrap();
        assert_eq!(n, 9);
        assert_eq!(&buffer[..n], b"Some data");

        // Second read should fail with an error
        let result = response_stream.read(&mut buffer).await;
        assert!(result.is_err());
    }

    #[async_std::test]
    async fn test_async_read_copy() {
        // Test using async_std::io::copy which is a common use case
        let chunks = vec![
            Ok(Bytes::from("First chunk\n")),
            Ok(Bytes::from("Second chunk\n")),
            Ok(Bytes::from("Third chunk\n")),
        ];

        let stream = stream::iter(chunks);
        let data_stream: DataStream = Box::pin(stream);

        let mut response_stream = ResponseDataStream {
            bytes: data_stream,
            status_code: 200,
        };

        let mut output = Vec::new();
        async_std::io::copy(&mut response_stream, &mut output)
            .await
            .unwrap();

        assert_eq!(output, b"First chunk\nSecond chunk\nThird chunk\n");
    }
}
