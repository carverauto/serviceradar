// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use std::sync::LazyLock;
use std::time::SystemTime;

use aws_sigv4::http_request::PayloadChecksumKind;
use aws_sigv4::http_request::PercentEncodingMode;
use aws_sigv4::http_request::SignableBody;
use aws_sigv4::http_request::SignableRequest;
use aws_sigv4::http_request::SigningSettings;
use aws_sigv4::sign::v4::SigningParams;
use criterion::Criterion;
use criterion::criterion_group;
use criterion::criterion_main;
use reqsign_aws_v4::Credential as AwsCredential;
use reqsign_aws_v4::RequestSigner as AwsV4RequestSigner;
use reqsign_core::{Context, SignRequest};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

criterion_group!(benches, bench);
criterion_main!(benches);

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .expect("must success")
});

pub fn bench(c: &mut Criterion) {
    let mut group = c.benchmark_group("aws_v4");

    group.bench_function("reqsign", |b| {
        let cred = AwsCredential {
            access_key_id: "access_key_id".to_string(),
            secret_access_key: "secret_access_key".to_string(),
            ..Default::default()
        };

        let s = AwsV4RequestSigner::new("s3", "test");
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());

        b.to_async(&*RUNTIME).iter(|| async {
            let mut req = http::Request::new("");
            *req.method_mut() = http::Method::GET;
            *req.uri_mut() = "http://127.0.0.1:9000/hello"
                .parse()
                .expect("url must be valid");

            let (mut parts, _) = req.into_parts();
            s.sign_request(&ctx, &mut parts, Some(&cred), None)
                .await
                .expect("must success")
        })
    });

    group.bench_function("aws_sigv4", |b| {
        let mut ss = SigningSettings::default();
        ss.percent_encoding_mode = PercentEncodingMode::Single;
        ss.payload_checksum_kind = PayloadChecksumKind::XAmzSha256;

        let credentials = aws_credential_types::Credentials::new(
            "access_key_id".to_string(),
            "secret_access_key".to_string(),
            None,
            None,
            "test",
        )
        .into();

        let sp = SigningParams::builder()
            .identity(&credentials)
            .region("test")
            .name("s3")
            .time(SystemTime::now())
            .settings(ss)
            .build()
            .expect("signing params must be valid")
            .into();

        let mut req = http::Request::new("");
        *req.method_mut() = http::Method::GET;
        *req.uri_mut() = "http://127.0.0.1:9000/hello"
            .parse()
            .expect("url must be valid");
        let method = req.method().as_str();
        let uri = req.uri().to_string();
        let headers = req
            .headers()
            .iter()
            .map(|(k, v)| (k.as_str(), std::str::from_utf8(v.as_bytes()).unwrap()))
            .collect::<Vec<_>>();

        b.iter(|| {
            let _ = aws_sigv4::http_request::sign(
                SignableRequest::new(
                    method,
                    uri.as_str(),
                    headers.clone().into_iter(),
                    SignableBody::UnsignedPayload,
                )
                .unwrap(),
                &sp,
            )
            .expect("signing must succeed");
        })
    });

    group.finish();
}
