fn main() -> attohttpc::Result {
    env_logger::init();

    let resp = attohttpc::post("https://httpbin.org/post")
        .text("hello, world!")
        .send()?;

    println!("Status: {:?}", resp.status());
    println!("Headers:\n{:#?}", resp.headers());
    println!("Body:\n{}", resp.text()?);

    Ok(())
}
