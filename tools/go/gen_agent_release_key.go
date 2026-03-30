package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
)

func main() {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}

	fmt.Printf("SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY=%s\n", base64.StdEncoding.EncodeToString(privateKey.Seed()))
	fmt.Printf("SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY=%s\n", base64.StdEncoding.EncodeToString(publicKey))
}
