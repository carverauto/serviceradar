use attohttpc::{Result, Session};

fn main() -> Result {
    let mut sess = Session::new();
    sess.header("Authorization", "Bearer please let me in!");

    let resp = sess.get("https://httpbin.org/get").send()?;
    println!("{}", resp.text()?);

    Ok(())
}
