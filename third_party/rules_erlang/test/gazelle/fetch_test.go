package fetch_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/rabbitmq/rules_erlang/gazelle/fetch"
	"testing"
)

func TestUpdate(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Fetch Suite")
}

var _ = Describe("Fetch Suite", func() {
	Describe("ParseHexImportArg", func() {
		It("should parse the full specification", func() {
			imp := "lz4=hex.pm/lz4-erlang@1.0.0"
			name, pkg, version, err := fetch.ParseHexImportArg(imp)

			Expect(name).To(Equal("lz4"))
			Expect(pkg).To(Equal("lz4-erlang"))
			Expect(version).To(Equal("1.0.0"))
			Expect(err).NotTo(HaveOccurred())
		})

		It("leaves the name empty if not explicit", func() {
			imp := "hex.pm/lz4-erlang@1.0.0"
			name, pkg, version, err := fetch.ParseHexImportArg(imp)

			Expect(name).To(Equal(""))
			Expect(pkg).To(Equal("lz4-erlang"))
			Expect(version).To(Equal("1.0.0"))
			Expect(err).NotTo(HaveOccurred())
		})
	})

	Describe("ParseGithubImportArg", func() {
		It("should parse the full specification", func() {
			imp := "inet_tcp_proxy_dist@1.2.0=github.com/rabbitmq/inet_tcp_proxy@master"
			name, version, owner, repo, ref, err := fetch.ParseGithubImportArg(imp)

			Expect(name).To(Equal("inet_tcp_proxy_dist"))
			Expect(version).To(Equal("1.2.0"))
			Expect(owner).To(Equal("rabbitmq"))
			Expect(repo).To(Equal("inet_tcp_proxy"))
			Expect(ref).To(Equal("master"))
			Expect(err).NotTo(HaveOccurred())
		})

		It("should parse a partial specification", func() {
			imp := "inet_tcp_proxy_dist=github.com/rabbitmq/inet_tcp_proxy@master"
			name, version, owner, repo, ref, err := fetch.ParseGithubImportArg(imp)

			Expect(name).To(Equal("inet_tcp_proxy_dist"))
			Expect(version).To(Equal(""))
			Expect(owner).To(Equal("rabbitmq"))
			Expect(repo).To(Equal("inet_tcp_proxy"))
			Expect(ref).To(Equal("master"))
			Expect(err).NotTo(HaveOccurred())
		})

		It("leaves the name empty if not explicit", func() {
			imp := "github.com/rabbitmq/inet_tcp_proxy@master"
			name, version, owner, repo, ref, err := fetch.ParseGithubImportArg(imp)

			Expect(name).To(Equal(""))
			Expect(version).To(Equal(""))
			Expect(owner).To(Equal("rabbitmq"))
			Expect(repo).To(Equal("inet_tcp_proxy"))
			Expect(ref).To(Equal("master"))
			Expect(err).NotTo(HaveOccurred())
		})
	})
})
