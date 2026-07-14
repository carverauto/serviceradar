#![cfg(not(feature = "single-threaded"))]

use std::io;
use std::net::TcpListener;
use std::thread;
use std::time::Duration;

#[test]
fn request_fails_due_to_read_timeout() {
    let listener = TcpListener::bind("localhost:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let thread = thread::spawn(move || {
        let _stream = listener.accept().unwrap();
        thread::sleep(Duration::from_millis(500));
    });

    let result = attohttpc::get(format!("http://localhost:{port}"))
        .read_timeout(Duration::from_millis(100))
        .send();

    match result {
        Err(err) => match err.kind() {
            attohttpc::ErrorKind::Io(err) => match err.kind() {
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => (),
                err => panic!("Unexpected I/O error: {:?}", err),
            },
            err => panic!("Unexpected error: {:?}", err),
        },
        Ok(resp) => panic!("Unexpected response: {:?}", resp),
    }

    thread.join().unwrap();
}

#[test]
fn request_fails_due_to_timeout() {
    let listener = TcpListener::bind("localhost:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let thread = thread::spawn(move || {
        let _stream = listener.accept().unwrap();
        thread::sleep(Duration::from_millis(500));
    });

    let result = attohttpc::get(format!("http://localhost:{port}"))
        .timeout(Duration::from_millis(100))
        .send();

    match result {
        Err(err) => match err.kind() {
            attohttpc::ErrorKind::Io(err) => match err.kind() {
                io::ErrorKind::TimedOut => (),
                err => panic!("Unexpected I/O error: {:?}", err),
            },
            err => panic!("Unexpected error: {:?}", err),
        },
        Ok(resp) => panic!("Unexpected response: {:?}", resp),
    }

    thread.join().unwrap();
}
