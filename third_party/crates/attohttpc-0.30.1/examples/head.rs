fn main() -> attohttpc::Result {
    env_logger::init();

    let resp = attohttpc::head("http://httpbin.org").send()?;
    println!("Status: {:?}", resp.status());
    println!("Headers:\n{:#?}", resp.headers());

    Ok(())
}
