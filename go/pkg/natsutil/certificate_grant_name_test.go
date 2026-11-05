package natsutil

import "testing"

// The Elixir hub callout (ServiceRadar.NATS.CertificateAuthorizationToken.grant_name/2)
// asserts the same vectors, so both callouts name a grant identically.
func TestCertificateGrantNameGoldenVectors(t *testing.T) {
	t.Parallel()

	const fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

	tests := []struct {
		name        string
		permissions CertificatePermissions
		want        string
	}{
		{
			name: "allow lists with one deny",
			permissions: CertificatePermissions{
				Publish:     []string{"metrics.example.>", "telemetry.edge-record.v1.bulk.>"},
				Subscribe:   []string{"_INBOX.>"},
				PublishDeny: []string{"metrics.example.private.>"},
			},
			want: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.0a927de9431ea74d4030390481597ca690d23f9779e0c35944cb79d78eca8033",
		},
		{
			name: "allow lists without deny",
			permissions: CertificatePermissions{
				Publish:   []string{"metrics.example.>"},
				Subscribe: []string{"events.example.>"},
			},
			want: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.bbcf9abc89cd17e12ace4aeb6ca3714f8f89d3360d56b540fc49225582c64703",
		},
		{
			name: "empty subscribe denies everything",
			permissions: CertificatePermissions{
				Publish:       []string{"events.example.*"},
				SubscribeDeny: []string{"events.example.private"},
			},
			want: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.88a5e2cd34fdb8076c88999d2853429aab8889d249b3cbc0c63c207d3df8873c",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := certificateGrantName(fingerprint, tt.permissions)
			if err != nil {
				t.Fatalf("certificateGrantName: %v", err)
			}
			if got != tt.want {
				t.Fatalf("certificateGrantName = %q, want %q", got, tt.want)
			}
		})
	}
}
