use bgpkit_parser::models::*;
use bgpkit_parser::BgpkitParser;

/// an very simple example that reads a remote BGP data file and print out the message count.
fn main() {
    let url = "http://archive.routeviews.org/route-views.amsix/bgpdata/2023.02/UPDATES/updates.20230222.0430.bz2";
    let parser = BgpkitParser::new(url).unwrap();
    for record in parser.into_record_iter() {
        match record.message {
            MrtMessage::TableDumpMessage(_) => {}
            MrtMessage::TableDumpV2Message(_) => {}
            MrtMessage::Bgp4Mp(msg) => match msg {
                Bgp4MpEnum::StateChange(_) => {}
                Bgp4MpEnum::Message(m) => match m.bgp_message {
                    BgpMessage::Open(_) => {}
                    BgpMessage::Update(u) => {
                        for attr in &u.attributes {
                            if let AttributeValue::OnlyToCustomer(remote) = attr {
                                println!("OTC message found, remote ASN = {remote}");
                            }
                        }
                    }
                    BgpMessage::Notification(_) => {}
                    BgpMessage::KeepAlive => {}
                },
            },
        }
    }
}
