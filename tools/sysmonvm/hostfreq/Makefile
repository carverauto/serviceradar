CC      = clang++
CFLAGS  = -std=c++20 -fobjc-arc -O2
LDFLAGS = -framework Foundation -framework IOKit -lIOReport
TARGET  = hostfreq
SRCS    = hostfreq.mm

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(SRCS) -o $@ $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
