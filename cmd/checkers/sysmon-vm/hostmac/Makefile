CC      = clang++
CFLAGS  = -std=c++20 -fobjc-arc -O2
LDFLAGS = -framework Foundation -framework IOKit -lIOReport
SRCS    = hostfreq.mm
OUTDIR ?= .
TARGET  = $(OUTDIR)/hostfreq

.PHONY: all
all: $(TARGET)

$(TARGET): $(SRCS)
	@mkdir -p $(OUTDIR)
	$(CC) $(CFLAGS) $(SRCS) -o $@ $(LDFLAGS)

.PHONY: clean
clean:
	$(RM) $(TARGET)
