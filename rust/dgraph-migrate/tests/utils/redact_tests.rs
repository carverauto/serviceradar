/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use dgraph_migrate::MigrateError;

/// Both Jobs print this error to stderr on every connect retry, so the
/// guarantee has to hold for the variant itself, not for one call site.
#[test]
fn a_connect_error_never_renders_the_acl_password() {
    let err = MigrateError::Connect(
        "dgraph://groot:s3cr3t@alpha.example.com:9080?sslmode=verify-ca".to_string(),
        "transport error".to_string(),
    );
    let rendered = err.to_string();

    assert!(
        !rendered.contains("s3cr3t"),
        "connect error leaked the ACL password: {rendered}"
    );
    assert!(
        rendered.contains("alpha.example.com:9080"),
        "connect error must still name the endpoint: {rendered}"
    );
    assert!(
        rendered.contains("transport error"),
        "connect error must still name the cause: {rendered}"
    );
}

#[test]
fn a_connect_error_without_userinfo_is_unchanged() {
    let err = MigrateError::Connect(
        "dgraph://alpha.example.com:9080?sslmode=require".to_string(),
        "transport error".to_string(),
    );
    assert_eq!(
        err.to_string(),
        "connect to dgraph://alpha.example.com:9080?sslmode=require: transport error"
    );
}
