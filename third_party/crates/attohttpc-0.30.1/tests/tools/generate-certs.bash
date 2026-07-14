#!/bin/bash

# https://stackoverflow.com/a/10176685
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 1000 -nodes -subj '/CN=localhost'
