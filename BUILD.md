# Building the project

* Currently, only linux on x86_64 is supported.
* The recommended linux distro is Ubuntu 24_04.
* The build process uses Bazel via Bazelisk.
* The repository currently pins Bazel via `.bazelversion` to `9.0.0`.

When configuring a VM, have at least 12 GB of RAM and 8 CPU cores available.

### Install Bazelisk

wget https://github.com/bazelbuild/bazelisk/releases/download/v1.27.0/bazelisk-linux-amd64

chmod +x bazelisk-linux-amd64

sudo mv bazelisk-linux-amd64 /usr/local/bin/bazel

**check bazelisk is installed**

which bazel
bazel --version

### Install system dependencies

* git
* clang-18
* build-essential
* openjdk-25-jdk
* bubblewrap
* rsync
* libgmp-dev 
* liblz4-dev 
* libzstd-dev 
* pkg-config
* libev-dev 
* libssl-dev

`
sudo apt install -y git clang-18 build-essential openjdk-25-jdk bubblewrap rsync libgmp-dev liblz4-dev libzstd-dev pkg-config libev-dev libssl-dev
`

### Clone the project

git clone https://github.com/carverauto/serviceradar.git


### Build the project 

`
bazel build //... 
`
