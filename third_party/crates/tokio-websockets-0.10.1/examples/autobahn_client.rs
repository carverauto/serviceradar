use std::str::FromStr;

use futures_util::{SinkExt, StreamExt};
use http::Uri;
use tokio_websockets::{ClientBuilder, Connector, Error, Limits};

#[cfg(feature = "simd")]
macro_rules! agent {
    () => {
        "tokio-websockets-simd"
    };
}

#[cfg(not(feature = "simd"))]
macro_rules! agent {
    () => {
        "tokio-websockets"
    };
}

async fn get_case_count() -> Result<u32, Error> {
    let uri = Uri::from_static("ws://localhost:9001/getCaseCount");
    let (mut stream, _) = ClientBuilder::from_uri(uri)
        .connector(&Connector::Plain)
        .connect()
        .await?;
    let msg = stream.next().await.unwrap()?;

    stream.close().await.unwrap();

    Ok(msg.as_text().unwrap().parse::<u32>().unwrap())
}

async fn update_reports() -> Result<(), Error> {
    let uri_str = concat!("ws://localhost:9001/updateReports?agent=", agent!());
    let uri = Uri::from_static(uri_str);
    let (mut stream, _) = ClientBuilder::from_uri(uri)
        .connector(&Connector::Plain)
        .connect()
        .await?;

    stream.close().await?;

    Ok(())
}

async fn run_test(case: u32) -> Result<(), Error> {
    println!("Running test case {case}");

    let uri = Uri::from_str(&format!(
        "ws://localhost:9001/runCase?case={}&agent={}",
        case,
        agent!()
    ))
    .unwrap();

    let (mut stream, _) = ClientBuilder::from_uri(uri)
        .limits(Limits::unlimited())
        .connector(&Connector::Plain)
        .connect()
        .await?;

    while let Some(msg) = stream.next().await {
        let msg = msg?;

        if msg.is_text() || msg.is_binary() {
            stream.send(msg).await?;
        }
    }

    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    let total = get_case_count().await?;
    println!("Running {total} tests");

    for case in 1..=total {
        if let Err(e) = run_test(case).await {
            match e {
                Error::Protocol(_) => {}
                _ => eprintln!("Testcase failed: {e:?}"),
            }
        };
    }

    update_reports().await?;

    Ok(())
}
