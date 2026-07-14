fn main() -> attohttpc::Result {
    env_logger::init();

    let file = attohttpc::MultipartFile::new("file", b"Hello, world!")
        .with_type("text/plain")?
        .with_filename("hello.txt");
    let form = attohttpc::MultipartBuilder::new()
        .with_text("Hello", "world!")
        .with_file(file)
        .build()?;

    let resp = attohttpc::post("http://httpbin.org/post").body(form).send()?;

    println!("Status: {:?}", resp.status());
    println!("Headers:\n{:#?}", resp.headers());
    println!("Body:\n{}", resp.text()?);

    Ok(())
}
