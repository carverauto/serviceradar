# Generating Test Certificates

```shell
openssl req -new -x509 -newkey rsa:2048 -keyout /dev/null -nodes -sigopt rsa_padding_mode:pss -sha256 -sigopt rsa_pss_saltlen:-1 -outform der -out self_signed_sha256.der -batch
openssl req -new -x509 -newkey rsa:2048 -keyout /dev/null -nodes -sigopt rsa_padding_mode:pss -sha384 -sigopt rsa_pss_saltlen:-1 -outform der -out self_signed_sha384.der -batch
openssl req -new -x509 -newkey rsa:2048 -keyout /dev/null -nodes -sigopt rsa_padding_mode:pss -sha512 -sigopt rsa_pss_saltlen:-1 -outform der -out self_signed_sha512.der -batch
```
