package trivysidecar

import "testing"

func TestSubjectForKind(t *testing.T) {
	t.Parallel()

	subject := SubjectForKind("trivy.report", ReportKind{SubjectSuffix: "cluster.vulnerability"})
	if subject != "trivy.report.cluster.vulnerability" {
		t.Fatalf("unexpected subject: %s", subject)
	}
}
