use etherparse::*;

fn main() {
    //setup the packet headers
    let builder = PacketBuilder::ethernet2(
        [1, 2, 3, 4, 5, 6],    //source mac
        [7, 8, 9, 10, 11, 12], //destination mac
    )
    .ipv4(
        [192, 168, 1, 1], //source ip
        [192, 168, 1, 2], //destination ip
        20,               //time to life
    )
    .tcp(
        21,    //source port
        1234,  //desitnation port
        1,     //sequence number
        26180, //window size
    )
    //set additional tcp header fields
    //supported flags: ns(), fin(), syn(), rst(), psh(), ece(), cwr()
    .ns() //set the ns flag
    .ack(123) //ack flag + the ack number
    .urg(23) //urg flag + urgent pointer
    //tcp header options
    .options(&[
        TcpOptionElement::Noop,
        TcpOptionElement::MaximumSegmentSize(1234),
    ])
    .unwrap();

    //payload of the tcp packet
    let payload = [1, 2, 3, 4, 5, 6, 7, 8];

    //get some memory to store the result
    let mut result = Vec::<u8>::with_capacity(builder.size(payload.len()));

    //serialize
    //this will automatically set all length fields, checksums and identifiers (ethertype & protocol)
    builder.write(&mut result, &payload).unwrap();
    println!("{:?}", result);
}
