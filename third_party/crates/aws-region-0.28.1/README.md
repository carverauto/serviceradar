AWS S3 [region identifier](https://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region),
passing in custom values is also possible, in that case it is up to you to pass a valid endpoint,
otherwise boom will happen :)

# Example
```rust
use std::str::FromStr;
use awsregion::Region;

// Parse from a string
let region: Region = "us-east-1".parse().unwrap();
// Choose region directly
let region = Region::EuWest2;

// Custom region requires valid region name and endpoint
let region_name = "nl-ams".to_string();
let endpoint = "https://s3.nl-ams.scw.cloud".to_string();
let region = Region::Custom { region: region_name, endpoint };
```