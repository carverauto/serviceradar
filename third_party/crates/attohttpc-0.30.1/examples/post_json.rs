use serde_json::json;

fn main() -> attohttpc::Result {
    env_logger::init();

    let body = json!({
        "hello": "world",
    });

    let resp = attohttpc::post("http://httpbin.org/post").json(&body)?.send()?;
    println!("Status: {:?}", resp.status());
    println!("Headers:\n{:#?}", resp.headers());
    println!("Body:\n{}", resp.text_utf8()?);

    Ok(())
}
