fn main() -> attohttpc::Result {
    env_logger::init();

    let resp = attohttpc::get("https://statsapi.web.nhl.com/api/v1/schedule").send()?;
    println!("Status: {:?}", resp.status());
    println!("Headers:\n{:#?}", resp.headers());
    println!("Body:\n{}", resp.text()?);

    Ok(())
}
