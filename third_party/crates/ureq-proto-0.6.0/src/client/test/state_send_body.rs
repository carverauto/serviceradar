use crate::client::SendRequestResult;

use super::TestSliceExt;
use super::scenario::Scenario;

#[test]
fn write_with_content_length() {
    let input = b"hello".as_slice();

    let scenario = Scenario::builder()
        .post("https://q.test")
        .header("content-length", input.len())
        .build();

    let mut call = scenario.to_send_body();

    // deliberately short buffer to require multiple writes
    let mut output = vec![0; 3];

    let overhead = call.calculate_max_input(output.len());
    assert_eq!(overhead, 3); // not chunked. entire output can be used as input.

    assert!(!call.can_proceed());

    // 1st write
    let (input_used, output_used) = call.write(input, &mut output).unwrap();
    assert_eq!(input_used, 3);
    assert_eq!(output_used, 3);
    assert_eq!(output[..output_used].as_str(), "hel");

    let input = &input[input_used..];
    assert!(!call.can_proceed());

    // 2nd write
    let (input_used, output_used) = call.write(input, &mut output).unwrap();
    assert_eq!(input_used, 2);
    assert_eq!(output_used, 2);
    assert_eq!(output[..output_used].as_str(), "lo");

    assert!(call.can_proceed());
}

#[test]
fn write_with_content_length_empty_slices() {
    let input = b"hello".as_slice();

    let scenario = Scenario::builder()
        .post("https://q.test")
        .header("content-length", input.len())
        .build();

    let mut call = scenario.to_send_body();
    let mut output = vec![0; 1024];

    // Useless write
    let (input_used, output_used) = call.write(&[], &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 0);

    assert!(!call.can_proceed());

    // Proper write
    let (input_used, output_used) = call.write(input, &mut output).unwrap();
    assert_eq!(input_used, 5);
    assert_eq!(output_used, 5);

    assert!(call.can_proceed());

    // More useless writes
    let (input_used, output_used) = call.write(&[], &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 0);
    let (input_used, output_used) = call.write(&[], &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 0);
    let (input_used, output_used) = call.write(&[], &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 0);

    assert!(call.can_proceed());
}

#[test]
fn write_with_chunked() {
    let input = b"hello".as_slice();

    let scenario = Scenario::builder().post("https://q.test").build();

    let mut call = scenario.to_send_body();

    let mut output = vec![0; 21 * 1024 + 74];

    let overhead = call.calculate_max_input(output.len());
    assert_eq!(overhead, 21554);

    assert!(!call.can_proceed());

    // 1st write
    let (input_used, output_used) = call.write(&input[..3], &mut output).unwrap();
    assert_eq!(input_used, 3);
    assert_eq!(output_used, 8);
    assert_eq!(output[..output_used].as_str(), "3\r\nhel\r\n");

    assert!(!call.can_proceed());

    // 2nd write
    let (input_used, output_used) = call.write(&input[3..], &mut output).unwrap();
    assert_eq!(input_used, 2);
    assert_eq!(output_used, 7);
    assert_eq!(output[..output_used].as_str(), "2\r\nlo\r\n");

    assert!(!call.can_proceed());

    // write end
    let (input_used, output_used) = call.write(&[], &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 5);
    assert_eq!(output[..output_used].as_str(), "0\r\n\r\n");

    assert!(call.can_proceed());
}

#[test]
fn send_body_despite_method() {
    let scenario = Scenario::builder()
        .delete("https://q.test")
        .send_body("DELETE should not have a body", true)
        .build();

    let mut call = scenario.to_prepare();

    call.force_send_body();

    let mut call = call.proceed();

    // Write the prelude and discard
    call.write(&mut vec![0; 1024]).unwrap();

    let result = call.proceed().unwrap().unwrap();

    // We should be able to get to this state without errors.
    assert!(matches!(result, SendRequestResult::SendBody(_)));
}
