package mapper

import "testing"

func TestLLDPManagementIPv4FromOID(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		oid  string
		want string
	}{
		{
			name: "lldpd length-prefixed ipv4",
			oid:  ".1.0.8802.1.1.2.1.4.2.1.3.100.78.2.1.4.10.99.0.12",
			want: "10.99.0.12",
		},
		{
			name: "unprefixed ipv4",
			oid:  ".1.0.8802.1.1.2.1.4.2.1.3.100.25.7.1.192.168.1.87",
			want: "192.168.1.87",
		},
		{
			name: "ipv6 subtype ignored",
			oid:  ".1.0.8802.1.1.2.1.4.2.1.3.100.78.2.2.16.32.1.0.0.0.0.0.0.0.0.0.0.0.0.0.1",
			want: "",
		},
		{
			name: "too short",
			oid:  ".1.0.8802.1.1.2.1.4.2.1.3.100.78.2",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := lldpManagementIPv4FromOID(tt.oid); got != tt.want {
				t.Fatalf("lldpManagementIPv4FromOID(%q) = %q, want %q", tt.oid, got, tt.want)
			}
		})
	}
}
