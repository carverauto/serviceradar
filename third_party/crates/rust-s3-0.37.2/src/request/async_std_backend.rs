use async_std::io::Write as AsyncWrite;
use async_std::io::{ReadExt, WriteExt};
use async_std::stream::StreamExt;
use bytes::Bytes;
use futures_util::FutureExt;
use std::collections::HashMap;

use crate::bucket::Bucket;
use crate::command::Command;
use crate::error::S3Error;
use crate::utils::now_utc;
use time::OffsetDateTime;

use crate::command::HttpMethod;
use crate::request::{Request, ResponseData, ResponseDataStream};

use http::HeaderMap;
use maybe_async::maybe_async;
use surf::http::Method;
use surf::http::headers::{HeaderName, HeaderValue};

// Temporary structure for making a request
pub struct SurfRequest<'a> {
    pub bucket: &'a Bucket,
    pub path: &'a str,
    pub command: Command<'a>,
    pub datetime: OffsetDateTime,
    pub sync: bool,
}

#[maybe_async]
impl<'a> Request for SurfRequest<'a> {
    type Response = surf::Response;
    type HeaderMap = HeaderMap;

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

    async fn response(&self) -> Result<surf::Response, S3Error> {
        // Build headers
        let headers = self.headers().await?;

        let request = match self.command.http_verb() {
            HttpMethod::Get => surf::Request::builder(Method::Get, self.url()?),
            HttpMethod::Delete => surf::Request::builder(Method::Delete, self.url()?),
            HttpMethod::Put => surf::Request::builder(Method::Put, self.url()?),
            HttpMethod::Post => surf::Request::builder(Method::Post, self.url()?),
            HttpMethod::Head => surf::Request::builder(Method::Head, self.url()?),
        };

        let mut request = request.body(self.request_body()?);

        for (name, value) in headers.iter() {
            request = request.header(
                HeaderName::from_bytes(AsRef::<[u8]>::as_ref(&name).to_vec())
                    .expect("Could not parse heaeder name"),
                HeaderValue::from_bytes(AsRef::<[u8]>::as_ref(&value).to_vec())
                    .expect("Could not parse header value"),
            );
        }

        let response = request
            .send()
            .await
            .map_err(|e| S3Error::Surf(e.to_string()))?;

        if cfg!(feature = "fail-on-err") && !response.status().is_success() {
            return Err(S3Error::HttpFail);
        }

        Ok(response)
    }

    async fn response_status(&self) -> Result<u16, S3Error> {
        crate::retry! {
            async {
                let headers = self.headers().await?;

                let request = match self.command.http_verb() {
                    HttpMethod::Get => surf::Request::builder(Method::Get, self.url()?),
                    HttpMethod::Delete => surf::Request::builder(Method::Delete, self.url()?),
                    HttpMethod::Put => surf::Request::builder(Method::Put, self.url()?),
                    HttpMethod::Post => surf::Request::builder(Method::Post, self.url()?),
                    HttpMethod::Head => surf::Request::builder(Method::Head, self.url()?),
                };

                let mut request = request.body(self.request_body()?);

                for (name, value) in headers.iter() {
                    request = request.header(
                        HeaderName::from_bytes(AsRef::<[u8]>::as_ref(&name).to_vec())
                            .expect("Could not parse heaeder name"),
                        HeaderValue::from_bytes(AsRef::<[u8]>::as_ref(&value).to_vec())
                            .expect("Could not parse header value"),
                    );
                }

                let response = request
                    .send()
                    .await
                    .map_err(|e| S3Error::Surf(e.to_string()))?;
                let status = u16::from(response.status());

                if status == 404 {
                    Ok(status)
                } else if cfg!(feature = "fail-on-err") && !response.status().is_success() {
                    Err(S3Error::HttpFail)
                } else {
                    Ok(status)
                }
            }.await
        }
    }

    async fn response_data(&self, etag: bool) -> Result<ResponseData, S3Error> {
        let mut response = crate::retry! {self.response().await}?;
        let status_code = response.status();

        let response_headers = response
            .header_names()
            .zip(response.header_values())
            .map(|(k, v)| (k.to_string(), v.to_string()))
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
            if let Some(etag) = response.header("ETag") {
                Bytes::from(etag.as_str().to_string())
            } else {
                Bytes::from("")
            }
        } else {
            let body = match response.body_bytes().await {
                Ok(bytes) => Ok(Bytes::from(bytes)),
                Err(e) => Err(S3Error::Surf(e.to_string())),
            };
            body?
        };
        Ok(ResponseData::new(
            body_vec,
            status_code.into(),
            response_headers,
        ))
    }

    async fn response_data_to_writer<T: AsyncWrite + Send + Unpin + ?Sized>(
        &self,
        writer: &mut T,
    ) -> Result<u16, S3Error> {
        let mut buffer = Vec::new();

        let response = crate::retry! {self.response().await}?;

        let status_code = response.status();

        let mut stream = surf::http::Body::from_reader(response, None);

        stream.read_to_end(&mut buffer).await?;

        writer.write_all(&buffer).await?;

        Ok(status_code.into())
    }

    async fn response_header(&self) -> Result<(HeaderMap, u16), S3Error> {
        let mut header_map = HeaderMap::new();
        let response = crate::retry! {self.response().await}?;
        let status_code = response.status();

        for (name, value) in response.iter() {
            header_map.insert(
                http::header::HeaderName::from_lowercase(
                    name.to_string().to_ascii_lowercase().as_ref(),
                )?,
                value.as_str().parse()?,
            );
        }
        Ok((header_map, status_code.into()))
    }

    async fn response_data_to_stream(&self) -> Result<ResponseDataStream, S3Error> {
        let mut response = crate::retry! {self.response().await}?;
        let status_code = response.status();

        let body = response
            .take_body()
            .bytes()
            .filter_map(|n| n.ok())
            .fold(vec![], |mut b, n| {
                b.push(n);
                b
            })
            .then(|b| async move { Ok(Bytes::from(b)) })
            .into_stream();

        Ok(ResponseDataStream {
            bytes: Box::pin(body),
            status_code: status_code.into(),
        })
    }
}

impl<'a> SurfRequest<'a> {
    pub async fn new<'b>(
        bucket: &'b Bucket,
        path: &'b str,
        command: Command<'b>,
    ) -> Result<SurfRequest<'b>, S3Error> {
        bucket.credentials_refresh().await?;
        Ok(SurfRequest {
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
    use crate::request::async_std_backend::SurfRequest;
    use anyhow::Result;
    use awscreds::Credentials;

    // Fake keys - otherwise using Credentials::default will use actual user
    // credentials if they exist.
    fn fake_credentials() -> Credentials {
        let access_key = "AKIAIOSFODNN7EXAMPLE";
        let secert_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
        Credentials::new(Some(access_key), Some(secert_key), None, None, None).unwrap()
    }

    #[async_std::test]
    async fn url_uses_https_by_default() -> Result<()> {
        let region = "custom-region".parse()?;
        let bucket = Bucket::new("my-first-bucket", region, fake_credentials())?;
        let path = "/my-first/path";
        let request = SurfRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url()?.scheme(), "https");

        let headers = request.headers().await.unwrap();
        let host = headers.get("Host").unwrap();

        assert_eq!(*host, "my-first-bucket.custom-region".to_string());
        Ok(())
    }

    #[async_std::test]
    async fn url_uses_https_by_default_path_style() -> Result<()> {
        let region = "custom-region".parse()?;
        let bucket = Bucket::new("my-first-bucket", region, fake_credentials())?.with_path_style();
        let path = "/my-first/path";
        let request = SurfRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "https");

        let headers = request.headers().await.unwrap();
        let host = headers.get("Host").unwrap();

        assert_eq!(*host, "custom-region".to_string());
        Ok(())
    }

    #[async_std::test]
    async fn url_uses_scheme_from_custom_region_if_defined() -> Result<()> {
        let region = "http://custom-region".parse()?;
        let bucket = Bucket::new("my-second-bucket", region, fake_credentials())?;
        let path = "/my-second/path";
        let request = SurfRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "http");

        let headers = request.headers().await.unwrap();
        let host = headers.get("Host").unwrap();
        assert_eq!(*host, "my-second-bucket.custom-region".to_string());
        Ok(())
    }

    #[async_std::test]
    async fn url_uses_scheme_from_custom_region_if_defined_with_path_style() -> Result<()> {
        let region = "http://custom-region".parse()?;
        let bucket = Bucket::new("my-second-bucket", region, fake_credentials())?.with_path_style();
        let path = "/my-second/path";
        let request = SurfRequest::new(&bucket, path, Command::GetObject)
            .await
            .unwrap();

        assert_eq!(request.url().unwrap().scheme(), "http");

        let headers = request.headers().await.unwrap();
        let host = headers.get("Host").unwrap();
        assert_eq!(*host, "custom-region".to_string());

        Ok(())
    }
}
