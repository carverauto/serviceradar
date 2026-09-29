package edgerecord

import (
	"bufio"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// M2.0b1: the SHARED STATIC-TARGET PLAN CORPUS, this runtime's half.
//
// Core builds the plan a source authorization binds from a sweep group's static targets
// (ServiceRadar.Edge.SweepPlan). This test rebuilds the same plan from the corpus literals with
// Go's own digest grammar and requires Go's validator to accept it, so two things are proven
// independently of the Elixir builder: the canonical CIDR spelling the builder emits is valid,
// and every digest it commits is the one Go computes.
//
// The check-set grammar is defined only for this corpus (the agent takes the value from its
// lease and never computes it), so the transcript below IS its Go peer.

type planCorpusTarget struct {
	raw, cidr string
	count     uint64
	rangeID   []byte
	rangeSHA  string
}

type planCorpus struct {
	planID, scope []byte
	checks        [][3]uint64
	targets       []planCorpusTarget
	expect        map[string]string
}

func loadPlanCorpus(t *testing.T) planCorpus {
	t.Helper()

	f, err := os.Open(filepath.Join("..", "..", "..", "..", "proto", "edge", "v1", "testdata", "sweep_static_plan_corpus.txt"))
	if err != nil {
		t.Fatalf("open sweep static plan corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	c := planCorpus{expect: map[string]string{}}
	mustHex := func(s string) []byte {
		b, err := hex.DecodeString(s)
		if err != nil {
			t.Fatalf("bad hex %q: %v", s, err)
		}
		return b
	}
	mustUint := func(s string) uint64 {
		n, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			t.Fatalf("bad number %q: %v", s, err)
		}
		return n
	}

	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		switch fields[0] {
		case "plan_id":
			c.planID = mustHex(fields[1])
		case "network_scope_id":
			c.scope = mustHex(fields[1])
		case "check":
			c.checks = append(c.checks, [3]uint64{mustUint(fields[1]), mustUint(fields[2]), mustUint(fields[3])})
		case "target":
			c.targets = append(c.targets, planCorpusTarget{
				raw: fields[1], cidr: fields[2], count: mustUint(fields[3]),
				rangeID: mustHex(fields[4]), rangeSHA: fields[5],
			})
		case "expect":
			key := fields[1]
			if len(fields) == 4 {
				key += " " + fields[2]
			}
			c.expect[key] = fields[len(fields)-1]
		default:
			t.Fatalf("unknown corpus row %q", line)
		}
	}
	if err := s.Err(); err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	return c
}

func TestSweepStaticPlanCorpus(t *testing.T) {
	c := loadPlanCorpus(t)
	got := map[string]string{}

	d := newDigest()
	d.str("serviceradar.edge.check_set.v1")
	d.u64(1)
	d.u64(uint64(len(c.checks)))
	for _, ck := range c.checks {
		d.u64(ck[0])
		d.u64(ck[1])
		d.u64(ck[2])
	}
	checkSet := d.finish()
	got["check_set_sha256"] = hex.EncodeToString(checkSet)

	policy := []byte("any-success-v1")
	var ranges []*edgev1.TargetRangeV1
	var total uint64
	for i, tg := range c.targets {
		r := &edgev1.TargetRangeV1{
			RangeId: tg.rangeID, Cidr: tg.cidr, TargetCount: tg.count,
			CheckSetSha256: checkSet, AvailabilityPolicyId: policy,
			MtrOrdinalCount: proto.Uint64(0),
		}
		r.RangeSha256 = RangeDigest(r)
		ranges = append(ranges, r)
		total += tg.count
		got["range "+strconv.Itoa(i)] = hex.EncodeToString(r.RangeSha256)
	}

	page := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: c.planID, PageIndex: 0, PageCount: 1, CheckSetSha256: checkSet,
		DigestVersion: PlanDigestVersion, Ranges: ranges,
	}
	page.PageSha256 = PlanPageDigest(page)
	pages := []*edgev1.ScheduledPlanPageV1{page}

	commitment, err := PlanMtrOrdinalRangeCommitment(pages)
	if err != nil {
		t.Fatalf("mtr commitment: %v", err)
	}
	h := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: c.planID, PageCount: 1, TotalTargetCount: total,
		PlanRootSha256: PlanRoot(pages), DigestVersion: PlanDigestVersion, CheckSetSha256: checkSet,
		AvailabilityPolicyId: policy, NetworkScopeId: c.scope, MtrOrdinalRangeCommitment: commitment,
	}
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)

	// Go's own validator must accept the plan: the canonical spelling, the span sizes and the
	// digest relations are checked by the reference implementation, not restated here.
	if err := ValidatePlanPages(h, pages); err != nil {
		t.Fatalf("Go refuses the corpus plan: %v", err)
	}

	got["total_target_count"] = strconv.FormatUint(total, 10)
	got["page_sha256 0"] = hex.EncodeToString(page.PageSha256)
	got["plan_root"] = hex.EncodeToString(h.PlanRootSha256)
	got["header_sha256"] = hex.EncodeToString(h.ExecutionPlanSha256)

	for i, tg := range c.targets {
		if want := tg.rangeSHA; want != got["range "+strconv.Itoa(i)] {
			t.Errorf("range %d (%s) digest = %s, corpus has %s", i, tg.cidr, got["range "+strconv.Itoa(i)], want)
		}
	}
	for key, want := range c.expect {
		if got[key] != want {
			t.Errorf("%s = %s, corpus has %s", key, got[key], want)
		}
	}
}
