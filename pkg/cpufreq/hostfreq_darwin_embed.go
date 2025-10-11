//go:build darwin && cgo && hostfreq_embed

package cpufreq

/*
#cgo darwin CFLAGS: -fobjc-arc -I${SRCDIR}
#cgo darwin LDFLAGS: -lc++ ${SRCDIR}/hostfreq_darwin_embed.o
#include "hostfreq_bridge.h"
*/
import "C"

// This file is only built with the hostfreq_embed tag. The Makefile compiles
// hostfreq_darwin.mm into hostfreq_darwin_embed.o prior to invoking `go build`,
// and the linker picks it up via the extra LDFLAGS declared above.
