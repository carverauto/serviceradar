#!/usr/bin/env bash

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

password="hunter2"
passout="pass:${password}"

openssl genrsa -out rsa_sk.pkcs1.pem 1024

openssl pkcs8 -topk8 -in rsa_sk.pkcs1.pem -outform DER -out rsa_sk.pkcs8.der -nocrypt

gen_pkcs8 () {
    local aes_mode="${1:?}"
    local prf="${2:?}"

    openssl pkcs8 \
        -topk8 \
        -in rsa_sk.pkcs1.pem \
        -v2 "$aes_mode" \
        -v2prf "$prf" \
        -iter 10 \
        -passout "$passout" \
        -outform DER -out "rsa_sk_${aes_mode}_${prf}.pkcs8.der"
}

for aes_mode in "aes-128-cbc" "aes-192-cbc" "aes-256-cbc"
do
    for prf in "hmacWithSHA1" "hmacWithSHA224" "hmacWithSHA256" "hmacWithSHA384" "hmacWithSHA512"
    do
        gen_pkcs8 "$aes_mode" "$prf"
    done
done

extract () {
    local aes_mode="${1:?}"
    local prf="${2:?}"
    local algid_len="${3:?}"

    dd bs=1 skip=4 count="$algid_len" if="rsa_sk_${aes_mode}_${prf}.pkcs8.der" of="pbes2_${aes_mode}_${prf}_algid.der"
    dd bs=1 skip="$(expr $algid_len + 8)" if="rsa_sk_${aes_mode}_${prf}.pkcs8.der" of="pbes2_${aes_mode}_${prf}_ciphertext.bin"
}

for aes_mode in "aes-128-cbc" "aes-192-cbc" "aes-256-cbc"
do
    extract "$aes_mode" "hmacWithSHA1" 74

    for prf in "hmacWithSHA224" "hmacWithSHA256" "hmacWithSHA384" "hmacWithSHA512"
    do
        extract "$aes_mode" "$prf" 88
    done
done
