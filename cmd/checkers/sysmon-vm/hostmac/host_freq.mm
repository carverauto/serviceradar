#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach_time.h>

#include <algorithm>
#include <climits>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// The IOReport APIs live in a private library, so declare the pieces we need explicitly.
using IOReportSubscriptionRef = struct __IOReportSubscriptionRef*;

extern "C" CFMutableDictionaryRef IOReportCopyChannelsInGroup(NSString* group,
                                                              NSString* subgroup,
                                                              uint64_t channel_id,
                                                              uint64_t,
                                                              uint64_t);

extern "C" IOReportSubscriptionRef IOReportCreateSubscription(void*,
                                                              CFMutableDictionaryRef desiredChannels,
                                                              CFMutableDictionaryRef* subbedChannels,
                                                              uint64_t channel_id,
                                                              CFTypeRef);

extern "C" CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription,
                                                 CFMutableDictionaryRef subbedChannels,
                                                 CFTypeRef);

extern "C" CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef previousSample,
                                                      CFDictionaryRef currentSample,
                                                      CFTypeRef);

extern "C" void IOReportIterate(CFDictionaryRef sample,
                                int(^iterator)(CFDictionaryRef channel));

extern "C" NSString* IOReportChannelGetChannelName(CFDictionaryRef channel);
extern "C" NSString* IOReportChannelGetGroup(CFDictionaryRef channel);
extern "C" NSString* IOReportChannelGetSubGroup(CFDictionaryRef channel);

extern "C" int IOReportStateGetCount(CFDictionaryRef channel);
extern "C" uint64_t IOReportStateGetResidency(CFDictionaryRef channel, int index);

namespace {

struct FrequencySample {
    std::string name;
    double averageMHz{0.0};
};

struct CollectorConfig {
    int intervalMs{200};
    int sampleCount{1};
};

mach_timebase_info_data_t Timebase() {
    static mach_timebase_info_data_t info{};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&info);
    });
    return info;
}

double NanosecondsToMilliseconds(uint64_t nanos) {
    return static_cast<double>(nanos) / 1e6;
}

std::vector<double> LoadDvfsTable(CFStringRef propertyKey) {
    std::vector<double> table;
    table.reserve(16);
    table.push_back(0.0);  // index 0 is unused (idle state placeholder).

    constexpr size_t kDvfsEntryBytes = sizeof(uint32_t) * 2;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                    IOServiceMatching("AppleARMIODevice"),
                                                    &iterator);
    if (kr != KERN_SUCCESS) {
        return table;
    }

    io_registry_entry_t entry = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef property = IORegistryEntryCreateCFProperty(entry, propertyKey,
                                                             kCFAllocatorDefault, 0);
        if (property != nullptr) {
            NSData* data = (__bridge_transfer NSData*)property;
            const uint8_t* bytes = static_cast<const uint8_t*>([data bytes]);
            const NSUInteger length = [data length];

        for (NSUInteger offset = 0; offset + kDvfsEntryBytes <= length; offset += kDvfsEntryBytes) {
            uint32_t freqHz = 0;
            uint32_t voltageMillivolts = 0;
            memcpy(&freqHz, bytes + offset, sizeof(freqHz));
            memcpy(&voltageMillivolts, bytes + offset + sizeof(freqHz), sizeof(voltageMillivolts));

                if (freqHz == 0) {
                    continue;
                }
                // IOReport encodes frequency in Hz; convert to MHz for readability.
                double frequencyMHz = static_cast<double>(freqHz) / 1e6;
                table.push_back(frequencyMHz);
            }
            IOObjectRelease(entry);
            break;
        }
        IOObjectRelease(entry);
    }

    IOObjectRelease(iterator);
    return table;
}

double ComputeAverageMHz(CFDictionaryRef channel,
                         const std::vector<double>& dvfsTable) {
    const int stateCount = IOReportStateGetCount(channel);
    if (stateCount <= 1 || dvfsTable.size() <= 1) {
        return 0.0;
    }

    double activeResidencyTotal = 0.0;
    std::vector<uint64_t> residencies;
    residencies.reserve(static_cast<size_t>(stateCount > 1 ? stateCount - 1 : 0));

    for (int index = 1; index < stateCount; ++index) {
        uint64_t residency = IOReportStateGetResidency(channel, index);
        residencies.push_back(residency);
        activeResidencyTotal += static_cast<double>(residency);
    }

    if (activeResidencyTotal <= 0.0) {
        return 0.0;
    }

    double weightedSumMHz = 0.0;
    for (int index = 1; index < stateCount; ++index) {
        double residency = static_cast<double>(residencies[static_cast<size_t>(index - 1)]);
        if (residency <= 0.0) {
            continue;
        }
        double distribution = residency / activeResidencyTotal;
        double freqMHz = (static_cast<size_t>(index) < dvfsTable.size())
                             ? dvfsTable[static_cast<size_t>(index)]
                             : 0.0;
        weightedSumMHz += distribution * freqMHz;
    }

    return weightedSumMHz;
}

bool HasPrefix(const std::string& value, const char* prefix) {
    const size_t prefixLen = strlen(prefix);
    if (prefixLen == 0 || value.size() < prefixLen) {
        return false;
    }
    return std::char_traits<char>::compare(value.data(), prefix, prefixLen) == 0;
}

CollectorConfig ParseArgs(int argc, const char* argv[]) {
    CollectorConfig config;
    for (int index = 1; index < argc; ++index) {
        std::string arg(argv[index]);
        auto parseInt = [&](int& target, const char* next) {
            if (!next) {
                return;
            }
            const char* begin = next;
            const char* end = begin + strlen(next);
            int value = 0;
            auto result = std::from_chars(begin, end, value);
            if (result.ec == std::errc() && result.ptr != begin) {
                target = value;
            }
        };

        if (arg == "--interval-ms" && index + 1 < argc) {
            parseInt(config.intervalMs, argv[index + 1]);
            ++index;
        } else if (arg == "--samples" && index + 1 < argc) {
            parseInt(config.sampleCount, argv[index + 1]);
            ++index;
        } else if (arg == "--help" || arg == "-h") {
            printf("Usage: hostfreq [--interval-ms N] [--samples N]\n");
            exit(0);
        }
    }
    return config;
}

NSMutableArray* SerializeSamples(const std::vector<FrequencySample>& samples) {
    auto* output = [NSMutableArray arrayWithCapacity:samples.size()];
    for (const auto& sample : samples) {
        NSString* name = [NSString stringWithUTF8String:sample.name.c_str()];
        NSDictionary* entry = @{
            @"name": name ?: @"",
            @"avg_mhz": @(sample.averageMHz)
        };
        [output addObject:entry];
    }
    return output;
}

void EmitJson(const CollectorConfig& config,
              double durationMs,
              const std::vector<FrequencySample>& clusterSamples,
              const std::vector<FrequencySample>& coreSamples) {
    NSISO8601DateFormatter* formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions =
        NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;

    NSMutableDictionary* root = [@{
        @"timestamp": [formatter stringFromDate:[NSDate date]],
        @"interval_request_ms": @(config.intervalMs),
        @"interval_actual_ms": @(durationMs)
    } mutableCopy];

    if (!clusterSamples.empty()) {
        root[@"clusters"] = SerializeSamples(clusterSamples);
    }
    if (!coreSamples.empty()) {
        root[@"cores"] = SerializeSamples(coreSamples);
    }

    NSError* error = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:root
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (!jsonData) {
        fprintf(stderr, "failed to encode JSON: %s\n", error.localizedDescription.UTF8String);
        return;
    }

    fwrite(jsonData.bytes, jsonData.length, 1, stdout);
    fputc('\n', stdout);
}

std::optional<std::pair<std::vector<FrequencySample>, std::vector<FrequencySample>>>
CollectFrequencies(IOReportSubscriptionRef subscription,
                   CFMutableDictionaryRef subscribedChannels,
                   const std::vector<double>& ecpuTable,
                   const std::vector<double>& pcpuTable,
                   const CollectorConfig& config,
                   double* durationMs) {
    CFDictionaryRef firstSample = IOReportCreateSamples(subscription, subscribedChannels, nullptr);
    if (firstSample == nullptr) {
        fprintf(stderr, "IOReportCreateSamples returned null (do you need sudo?).\n");
        return std::nullopt;
    }

    const mach_timebase_info_data_t timebase = Timebase();
    // mach_absolute_time() is a monotonic counter suitable for measuring intervals.
    const uint64_t start = mach_absolute_time();

    usleep(static_cast<useconds_t>(config.intervalMs * 1000));

    CFDictionaryRef secondSample = IOReportCreateSamples(subscription, subscribedChannels, nullptr);
    const uint64_t end = mach_absolute_time();

    if (secondSample == nullptr) {
        CFRelease(firstSample);
        fprintf(stderr, "IOReportCreateSamples (second) returned null.\n");
        return std::nullopt;
    }

    const uint64_t diff = end - start;
    *durationMs = NanosecondsToMilliseconds(diff * timebase.numer / timebase.denom);

    CFDictionaryRef delta = IOReportCreateSamplesDelta(firstSample, secondSample, nullptr);

    CFRelease(firstSample);
    CFRelease(secondSample);

    if (delta == nullptr) {
        fprintf(stderr, "IOReportCreateSamplesDelta returned null.\n");
        return std::nullopt;
    }

    __block std::vector<FrequencySample> clusters;
    __block std::vector<FrequencySample> cores;
    clusters.reserve(4);
    cores.reserve(8);

    IOReportIterate(delta, ^int(CFDictionaryRef channel) {
        NSString* subgroup = IOReportChannelGetSubGroup(channel);
        if (!subgroup) {
            return 0;
        }

        NSString* name = IOReportChannelGetChannelName(channel);
        if (!name) {
            return 0;
        }

        std::string label(name.UTF8String);
        const std::vector<double>* table = nullptr;

        if (HasPrefix(label, "ECP")) {
            table = &ecpuTable;
        } else if (HasPrefix(label, "PCP") || HasPrefix(label, "P-Cluster") ||
                   HasPrefix(label, "PCluster") || HasPrefix(label, "PCPU")) {
            table = &pcpuTable;
        } else if (HasPrefix(label, "ECPU")) {
            table = &ecpuTable;
        } else {
            return 0;
        }

        if ([subgroup isEqualToString:@"CPU Complex Performance States"]) {
            if (label == "ECPU" || label == "PCPU") {
                double averageMHz = ComputeAverageMHz(channel, *table);
                clusters.push_back({label, averageMHz});
            }
        } else if ([subgroup isEqualToString:@"CPU Core Performance States"]) {
            double averageMHz = ComputeAverageMHz(channel, *table);
            cores.push_back({label, averageMHz});
        }

        return 0;
    });

    CFRelease(delta);
    return std::make_pair(std::move(clusters), std::move(cores));
}

}  // namespace

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        CollectorConfig config = ParseArgs(argc, argv);

        std::vector<double> ecpuTable = LoadDvfsTable(CFSTR("voltage-states1-sram"));
        std::vector<double> pcpuTable = LoadDvfsTable(CFSTR("voltage-states5-sram"));

        if (ecpuTable.size() <= 1 && pcpuTable.size() <= 1) {
            fprintf(stderr,
                    "Failed to read DVFS tables from IORegistry. Run on Apple Silicon macOS with sudo.\n");
            return 1;
        }

        CFMutableDictionaryRef subscribedChannels = nullptr;
        CFMutableDictionaryRef cpuChannels = IOReportCopyChannelsInGroup(@"CPU Stats", nil, 0, 0, 0);
        if (!cpuChannels) {
            fprintf(stderr, "IOReportCopyChannelsInGroup(\"CPU Stats\") returned null.\n");
            return 1;
        }

        IOReportSubscriptionRef subscription =
            IOReportCreateSubscription(nullptr, cpuChannels, &subscribedChannels, 0, nullptr);
        if (!subscription || !subscribedChannels) {
            if (cpuChannels) {
                CFRelease(cpuChannels);
            }
            fprintf(stderr,
                    "IOReportCreateSubscription failed. Try running as a privileged user.\n");
            return 1;
        }

        CFRelease(cpuChannels);

        auto emitSample = [&](void) -> bool {
            double actualDurationMs = 0.0;
            auto result = CollectFrequencies(subscription,
                                             subscribedChannels,
                                             ecpuTable,
                                             pcpuTable,
                                             config,
                                             &actualDurationMs);
            if (!result.has_value()) {
                return false;
            }

            EmitJson(config, actualDurationMs,
                     result->first /* clusters */,
                     result->second /* cores */);
            return true;
        };

        if (config.sampleCount == 0) {
            while (true) {
                if (!emitSample()) {
                    CFRelease(subscribedChannels);
                    return 1;
                }
            }
        } else {
            for (int sampleIndex = 0; sampleIndex < config.sampleCount; ++sampleIndex) {
                if (!emitSample()) {
                    CFRelease(subscribedChannels);
                    return 1;
                }
            }
        }

        CFRelease(subscribedChannels);
    }

    return 0;
}
