# Building the project

* Currently, only linux on x86_64 is supported.
* The recommended linux distro is Ubuntu 24_04.
* The build process uses Bazel via Bazelisk.

### Install Bazelisk

wget https://github.com/bazelbuild/bazelisk/releases/download/v1.27.0/bazelisk-linux-amd64

chmod +x bazelisk-linux-amd64

sudo mv bazelisk-linux-amd64 /usr/local/bin/bazel

**check bazelisk is installed**

which bazel

### Install system dependencies

* git
* clang-18
* build-essential
* bubblewrap
* rsync
* ocaml 
* libgmp-dev 
* liblz4-dev 
* libzstd-dev 
* pkg-config
* libev-dev 
* libssl-dev

`
sudo apt install -y git clang-18 build-essential bubblewrap rsync ocaml libgmp-dev liblz4-dev libzstd-dev pkg-config
`

### Clone the project

git clone https://github.com/carverauto/serviceradar.git


### Clone the monorepo 

`
bazel build /... 
`
