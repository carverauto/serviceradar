use oneio::{s3_copy, s3_delete, s3_download, s3_exists, s3_list, s3_reader, s3_stats, s3_upload};
use std::io::Read;
use tracing::info;

/// This example shows how to upload a file to S3 and read it back.
///
/// You need to set the following environment variables (e.g., in .env):
/// - AWS_ACCESS_KEY_ID
/// - AWS_SECRET_ACCESS_KEY
/// - AWS_REGION (e.g. "us-east-1") (use "auto" for Cloudflare R2)
/// - AWS_ENDPOINT
fn main() {
    tracing_subscriber::fmt::init();

    info!("upload to S3");
    s3_upload("oneio-test", "test/README.md", "README.md").unwrap();

    info!("read directly from S3");
    let mut content = String::new();
    s3_reader("oneio-test", "test/README.md")
        .unwrap()
        .read_to_string(&mut content)
        .unwrap();

    info!("download from S3");
    s3_download("oneio-test", "test/README.md", "test/README-2.md").unwrap();

    info!("get S3 file stats");
    let res = s3_stats("oneio-test", "test/README.md").unwrap();
    dbg!(res);

    info!("error if file does not exist");
    let res = s3_stats("oneio-test", "test/README___NON_EXISTS.md");
    assert!(res.is_err());
    assert_eq!(
        false,
        s3_exists("oneio-test", "test/README___NON_EXISTS.md").unwrap()
    );
    assert_eq!(true, s3_exists("oneio-test", "test/README.md").unwrap());

    info!("copy S3 file to a different location");
    let res = s3_copy("oneio-test", "test/README.md", "test/README-temporary.md");
    assert!(res.is_ok());
    assert_eq!(
        true,
        s3_exists("oneio-test", "test/README-temporary.md").unwrap()
    );

    info!("delete temporary copied S3 file");
    let res = s3_delete("oneio-test", "test/README-temporary.md");
    assert!(res.is_ok());
    assert_eq!(
        false,
        s3_exists("oneio-test", "test/README-temporary.md").unwrap()
    );

    info!("list S3 files");
    let res = s3_list("oneio-test", "test/", Some("/".to_string()), false).unwrap();
    dbg!(res);

    info!("read compressed s3 file by url");
    let mut writer = oneio::get_writer("test/README.md.gz").unwrap();
    write!(writer, "{}", content).unwrap();
    drop(writer);
    s3_upload("oneio-test", "test/README.md.gz", "test/README.md.gz").unwrap();
    let mut new_content = String::new();
    oneio::get_reader("s3://oneio-test/test/README.md.gz")
        .unwrap()
        .read_to_string(&mut new_content)
        .unwrap();
    assert_eq!(content, new_content);
}
