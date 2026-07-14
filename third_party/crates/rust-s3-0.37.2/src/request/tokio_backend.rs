extern crate base64;
extern crate md5;

use bytes::Bytes;
use futures_util::TryStreamExt;
use maybe_async::maybe_async;
use std::collections::HashMap;
use std::str::FromStr as _;
use time::OffsetDateTime;

use super::request_trait::{Request, ResponseData, ResponseDataStream};
use crate::bucket::Bucket;
use crate::command::Command;
use crate::command::HttpMethod;
use crate::error::S3Error;
use crate::retry;
use crate::utils::now_utc;

use tokio_stream::StreamExt;

#[derive(Clone, Debug, Default)]
pub(crate) struct ClientOptions {
    pub request_timeout: Option<std::time::Duration>,
    pub proxy: Option<reqwest::Proxy>,
    #[cfg(any(feature = "tokio-native-tls", feature = "tokio-rustls-tls"))]
    pub accept_invalid_certs: bool,
    #[cfg(any(feature = "tokio-native-tls", feature = "tokio-rustls-tls"))]
    pub accept_invalid_hostnames: bool,
}

#[cfg(feature = "with-tokio")]
pub(crate) fn client(options: &ClientOptions) -> Result<reqwest::Client, S3Error> {
    let client = reqwest::Client::builder();

    let client = if let Some(timeout) = options.request_timeout {
        client.timeout(timeout)
    } else {
        client
    };

    let client = if let Some(ref proxy) = options.proxy {
        client.proxy(proxy.clone())
    } else {
        client
    };

    cfg_if::cfg_if! {
        if #[cfg(any(feature = "tokio-native-tls", feature = "tokio-rustls-tls"))] {
            let client = client.danger_accept_invalid_certs(options.accept_invalid_certs);
        }
    }

    cfg_if::cfg_if! {
        if #[cfg(any(feature = "tokio-native-tls", feature = "tokio-rustls-tls"))] {
            let client = client.danger_accept_invalid_hostnames(options.accept_invalid_hostnames);
        }
    }

    Ok(client.build()?)
}
// Temporary structure for making a request
pub struct ReqwestRequest<'a> {
    pub bucket: &'a Bucket,
    pub path: &'a str,
    pub command: Command<'a>,
    pub datetime: OffsetDateTime,
    pub sync: bool,
}

#[maybe_async]
impl<'a> Request for ReqwestRequest<'a> {
    type Response = reqwest::Response;
    type HeaderMap = reqwest::header::HeaderMap;

    async fn response(&self) -> Result<Self::Response, S3Error> {
        let headers = self
            .headers()
            .await?
            .iter()
            .map(|(k, v)| {
                (
                    reqwest::header::HeaderName::from_str(k.as_str()),
                    reqwest::header::HeaderValue::from_str(v.to_str().unwrap_or_default()),
                )
            })
            .filter(|(k, v)| k.is_ok() && v.is_ok())
            .map(|(k, v)| (k.unwrap(), v.unwrap()))
            .collect();

        let client = self.bucket.http_client();

        let method = match self.command.http_verb() {
            HttpMethod::Delete => reqwest::Method::DELETE,
            HttpMethod::Get => reqwest::Method::GET,
            HttpMethod::Post => reqwest::Method::POST,
            HttpMethod::Put => reqwest::Method::PUT,
            HttpMethod::Head => reqwest::Method::HEAD,
        };

        let request = client
            .request(method, self.url()?.as_str())
            .headers(headers)
            .body(self.request_body()?);

        let request = request.build()?;

        // println!("Request: {:?}", request);

        let response = client.execute(request).await?;

        if cfg!(feature = "fail-on-err") && !response.status().is_success() {
            let status = response.status().as_u16();
            let text = response.text().await?;
            return Err(S3Error::HttpFailWithBody(status, text));
        }

        Ok(response)
    }

    async fn response_status(&self) -> Result<u16, S3Error> {
        retry! {
            async {
                let headers = self
                    .headers()
                    .await?
                    .iter()
                    .map(|(k, v)| {
                        (
                            reqwest::header::HeaderName::from_str(k.as_str()),
                            reqwest::header::HeaderValue::from_str(v.to_str().unwrap_or_default()),
                        )
                    })
                    .filter(|(k, v)| k.is_ok() && v.is_ok())
                    .map(|(k, v)| (k.unwrap(), v.unwrap()))
                    .collect();

                let client = self.bucket.http_client();

                let method = match self.command.http_verb() {
                    HttpMethod::Delete => reqwest::Method::DELETE,
                    HttpMethod::Get => reqwest::Method::GET,
                    HttpMethod::Post => reqwest::Method::POST,
                    HttpMethod::Put => reqwest::Method::PUT,
                    HttpMethod::Head => reqwest::Method::HEAD,
                };

                let request = client
                    .request(method, self.url()?.as_str())
                    .headers(headers)
                    .body(self.request_body()?);

                let request = request.build()?;
                let response = client.execute(request).await?;
                let status = response.status().as_u16();

                if status == 404 {
                    return Ok(status);
                }

                if cfg!(feature = "fail-on-err") && !response.status().is_success() {
                    let text = response.text().await?;
                    return Err(S3Error::HttpFailWithBody(status, text));
                }

                Ok(status)
            }.await
        }
    }

    async fn response_data(&self, etag: bool) -> Result<ResponseData, S3Error> {
        let response = retry! {self.response().await }?;
        let status_code = response.status().as_u16();
        let mut headers = response.headers().clone();
        let response_headers = headers
            .clone()
            .iter()
            .map(|(k, v)| {
                (
                    k.to_string(),
                    v.to_str()
                        .unwrap_or("could-not-decode-header-value")
                        .to_string(),
                )
            })
            .collect::<HashMap<String, String>>();
        // When etag=true, we extract the ETag header and return it as the body.
        // This is used for PUT operations (regular puts, multipart chunks) where:
        // 1. S3 returns an empty or non-useful response body
        // 2. The ETag header contains the essential information we need
        // 3. The calling code expects to get the ETag via response_data.as_str()
        //
        // Note: This approach means we discard any actual response body when etag=true,
        // but for the operations that use this (PUTs), the body is typically empty
        // or contains redundant information already available in headers.
        //
        // TODO: Refactor this to properly return the response body and access ETag
        // from headers instead of replacing the body. This would be a breaking change.
        let body_vec = if etag {
            if let Some(etag) = headers.remove("ETag") {
                Bytes::from(etag.to_str()?.to_string())
            } else {
                Bytes::from("")
            }
        } else {
            response.bytes().await?
        };
        Ok(ResponseData::new(body_vec, status_code, response_headers))
    }

    async fn response_data_to_writer<T: tokio::io::AsyncWrite + Send + Unpin + ?Sized>(
        &self,
        writer: &mut T,
    ) -> Result<u16, S3Error> {
        use tokio::io::AsyncWriteExt;
        let response = retry! {self.response().await}?;

        let status_code = response.status();
        let mut stream = response.bytes_stream();

        while let Some(item) = stream.next().await {
            writer.write_all(&item?).await?;
        }

        Ok(status_code.as_u16())
    }

    async fn response_data_to_stream(&self) -> Result<ResponseDataStream, S3Error> {
        let response = retry! {self.response().await}?;
        let status_code = response.status();
        let stream = response.bytes_stream().map_err(S3Error::Reqwest);

        Ok(ResponseDataStream {
            bytes: Box::pin(stream),
            status_code: status_code.as_u16(),
        })
    }

    async fn response_header(&self) -> Result<(Self::HeaderMap, u16), S3Error> {
        let response = retry! {self.response().await}?;
        let status_code = response.status().as_u16();
        let headers = response.headers().clone();
        Ok((headers, status_code))
    }

    fn datetime(&self) -> OffsetDateTime {
        self.datetime
    }

    fn bucket(&self) -> Bucket {
        self.bucket.clone()
    }

    fn command(&self) -> Command<'_> {
        self.command.clone()
    }

    fn path(&self) -> String {
        self.path.to_string()
    }
}

impl<'a> ReqwestRequest<'a> {
    pub async fn new(
        bucket: &'a Bucket,
        path: &'a str,
        command: Command<'a>,
    ) -> Result<ReqwestRequest<'a>, S3Error> {
        bucket.credentials_refresh().await?;
        Ok(Self {
            bucket,
            path,
            command,
            datetime: now_utc(),
            sync: false,
        })
    }
}

#[cfg(test)]
mod tests {
    use crate::bucket::Bucket;
    use crate::command::Command;
    use crate::request::Request;
    use crate::request::tokio_backend::ReqwestRequest;
    use awscreds::Credentials;
    use http::header::{HOST, RANGE};

    // Fake keys - otherwise using Credentials::default will use actual user
    // credentials if they exist.
    fn fake_credentials() -> Credentials {
        let access_key = "AKIAIOSFODNN7EXAMPLE";
        let secert_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
        Credentials::new(Some(access_key), Some(secert_key), None, None, None).unwrap()
    }

    #[tokio::test]
    async fn url_uses_https_by_default() {
        let region = "custom-region".parse().unwrap();
        let bucket = Bucket::new("my-first-bucket", region, fake_credentials()).unwrap();
        let path = "/my-first/path";
        let request = ReqwestRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "https");

        let headers = request.headers().await.unwrap();
        let host = headers.get(HOST).unwrap();

        assert_eq!(*host, "my-first-bucket.custom-region".to_string());
    }

    #[tokio::test]
    async fn url_uses_https_by_default_path_style() {
        let region = "custom-region".parse().unwrap();
        let bucket = Bucket::new("my-first-bucket", region, fake_credentials())
            .unwrap()
            .with_path_style();
        let path = "/my-first/path";
        let request = ReqwestRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "https");

        let headers = request.headers().await.unwrap();
        let host = headers.get(HOST).unwrap();

        assert_eq!(*host, "custom-region".to_string());
    }

    #[tokio::test]
    async fn url_uses_scheme_from_custom_region_if_defined() {
        let region = "http://custom-region".parse().unwrap();
        let bucket = Bucket::new("my-second-bucket", region, fake_credentials()).unwrap();
        let path = "/my-second/path";
        let request = ReqwestRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "http");

        let headers = request.headers().await.unwrap();
        let host = headers.get(HOST).unwrap();
        assert_eq!(*host, "my-second-bucket.custom-region".to_string());
    }

    #[tokio::test]
    async fn url_uses_scheme_from_custom_region_if_defined_with_path_style() {
        let region = "http://custom-region".parse().unwrap();
        let bucket = Bucket::new("my-second-bucket", region, fake_credentials())
            .unwrap()
            .with_path_style();
        let path = "/my-second/path";
        let request = ReqwestRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "http");

        let headers = request.headers().await.unwrap();
        let host = headers.get(HOST).unwrap();
        assert_eq!(*host, "custom-region".to_string());
    }

    #[tokio::test]
    async fn test_get_object_range_header() {
        let region = "http://custom-region".parse().unwrap();
        let bucket = Bucket::new("my-second-bucket", region, fake_credentials())
            .unwrap()
            .with_path_style();
        let path = "/my-second/path";

        let request = ReqwestRequest::new(
            &bucket,
            path,
            Command::GetObjectRange {
                start: 0,
                end: None,
            },
        )
        .await
        .unwrap();
        let headers = request.headers().await.unwrap();
        let range = headers.get(RANGE).unwrap();
        assert_eq!(range, "bytes=0-");

        let request = ReqwestRequest::new(
            &bucket,
            path,
            Command::GetObjectRange {
                start: 0,
                end: Some(1),
            },
        )
        .await
        .unwrap();
        let headers = request.headers().await.unwrap();
        let range = headers.get(RANGE).unwrap();
        assert_eq!(range, "bytes=0-1");
    }
}
