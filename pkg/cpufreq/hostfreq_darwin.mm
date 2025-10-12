#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach_time.h>

#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "hostfreq_bridge.h"

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

enum class Status {
    kOk = HOSTFREQ_STATUS_OK,
    kUnavailable = HOSTFREQ_STATUS_UNAVAILABLE,
    kPermission = HOSTFREQ_STATUS_PERMISSION,
    kInternal = HOSTFREQ_STATUS_INTERNAL,
};

struct FrequencySample {
    std::string name;
    double averageMHz{0.0};
};

struct CollectorConfig {
    int intervalMs{200};
    int sampleCount{1};
};

void AppendError(std::string* error, const std::string& message) {
    if (!error) {
        return;
    }
    if (!error->empty()) {
        error->append("\n");
    }
    error->append(message);
}

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
    table.push_back(0.0);

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
                memcpy(&freqHz, bytes + offset, sizeof(freqHz));
                if (freqHz == 0) {
                    continue;
                }

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

CollectorConfig ParseConfig(int intervalMs, int sampleCount) {
    CollectorConfig config;
    if (intervalMs > 0) {
        config.intervalMs = intervalMs;
    }
    if (sampleCount > 0) {
        config.sampleCount = sampleCount;
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

std::optional<std::string> EncodeJson(const CollectorConfig& config,
                                      double durationMs,
                                      const std::vector<FrequencySample>& clusterSamples,
                                      const std::vector<FrequencySample>& coreSamples,
                                      std::string* error) {
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

    NSError* nsError = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:root
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&nsError];
    if (!jsonData) {
        std::string message = "failed to encode JSON";
        if (nsError && nsError.localizedDescription) {
            message.append(": ");
            message.append(nsError.localizedDescription.UTF8String);
        }
        AppendError(error, message);
        return std::nullopt;
    }

    return std::string(static_cast<const char*>(jsonData.bytes), jsonData.length);
}

std::optional<std::pair<std::vector<FrequencySample>, std::vector<FrequencySample>>>
CollectFrequencies(IOReportSubscriptionRef subscription,
                   CFMutableDictionaryRef subscribedChannels,
                   const std::vector<double>& ecpuTable,
                   const std::vector<double>& pcpuTable,
                   const CollectorConfig& config,
                   double* durationMs,
                   std::string* error) {
    CFDictionaryRef firstSample = IOReportCreateSamples(subscription, subscribedChannels, nullptr);
    if (firstSample == nullptr) {
        AppendError(error, "IOReportCreateSamples returned null (requires elevated privileges?)");
        return std::nullopt;
    }

    const mach_timebase_info_data_t timebase = Timebase();
    const uint64_t start = mach_absolute_time();

    usleep(static_cast<useconds_t>(config.intervalMs * 1000));

    CFDictionaryRef secondSample = IOReportCreateSamples(subscription, subscribedChannels, nullptr);
    const uint64_t end = mach_absolute_time();

    if (secondSample == nullptr) {
        CFRelease(firstSample);
        AppendError(error, "IOReportCreateSamples (second) returned null");
        return std::nullopt;
    }

    const uint64_t diff = end - start;
    *durationMs = NanosecondsToMilliseconds(diff * timebase.numer / timebase.denom);

    CFDictionaryRef delta = IOReportCreateSamplesDelta(firstSample, secondSample, nullptr);

    CFRelease(firstSample);
    CFRelease(secondSample);

    if (delta == nullptr) {
        AppendError(error, "IOReportCreateSamplesDelta returned null");
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

Status CollectJsonInternal(const CollectorConfig& config,
                           std::string* json,
                           double* actualDurationMs,
                           std::string* error) {
    std::vector<double> ecpuTable = LoadDvfsTable(CFSTR("voltage-states1-sram"));
    std::vector<double> pcpuTable = LoadDvfsTable(CFSTR("voltage-states5-sram"));

    if (ecpuTable.size() <= 1 && pcpuTable.size() <= 1) {
        AppendError(error,
                    "Failed to read DVFS tables from IORegistry. Run on Apple Silicon macOS with sudo.");
        return Status::kUnavailable;
    }

    CFMutableDictionaryRef subscribedChannels = nullptr;
    CFMutableDictionaryRef cpuChannels = IOReportCopyChannelsInGroup(@"CPU Stats", nil, 0, 0, 0);
    if (!cpuChannels) {
        AppendError(error, "IOReportCopyChannelsInGroup(\"CPU Stats\") returned null.");
        return Status::kPermission;
    }

    IOReportSubscriptionRef subscription =
        IOReportCreateSubscription(nullptr, cpuChannels, &subscribedChannels, 0, nullptr);
    CFRelease(cpuChannels);

    if (!subscription || !subscribedChannels) {
        AppendError(error,
                    "IOReportCreateSubscription failed. Try running as a privileged user.");
        if (subscribedChannels) {
            CFRelease(subscribedChannels);
        }
        return Status::kPermission;
    }

    auto cleanup = [&]() {
        if (subscribedChannels) {
            CFRelease(subscribedChannels);
        }
        if (subscription) {
            CFRelease(subscription);
        }
    };

    auto emitSample = [&]() -> Status {
        double actualDuration = 0.0;
        auto result = CollectFrequencies(subscription,
                                         subscribedChannels,
                                         ecpuTable,
                                         pcpuTable,
                                         config,
                                         &actualDuration,
                                         error);
        if (!result.has_value()) {
            return Status::kInternal;
        }

        auto jsonOutput = EncodeJson(config,
                                     actualDuration,
                                     result->first,
                                     result->second,
                                     error);
        if (!jsonOutput.has_value()) {
            return Status::kInternal;
        }

        if (actualDurationMs) {
            *actualDurationMs = actualDuration;
        }

        if (json) {
            *json = std::move(*jsonOutput);
        }
        return Status::kOk;
    };

    Status status = Status::kOk;
    for (int sampleIndex = 0; sampleIndex < config.sampleCount; ++sampleIndex) {
        status = emitSample();
        if (status != Status::kOk) {
            break;
        }
    }

    cleanup();
    return status;
}

}  // namespace

extern "C" int hostfreq_collect_json(int interval_ms,
                                     int sample_count,
                                     char** out_json,
                                     double* out_actual_interval_ms,
                                     char** out_error) {
    @autoreleasepool {
        CollectorConfig config = ParseConfig(interval_ms, sample_count);

        std::string json;
        std::string error;
        double actual = 0.0;

        Status status = CollectJsonInternal(config, &json, &actual, &error);

        if (status == Status::kOk) {
            if (out_json) {
                char* buffer = static_cast<char*>(malloc(json.size() + 1));
                if (!buffer) {
                    if (out_error) {
                        *out_error = nullptr;
                    }
                    return static_cast<int>(Status::kInternal);
                }
                memcpy(buffer, json.data(), json.size());
                buffer[json.size()] = '\0';
                *out_json = buffer;
            }
            if (out_actual_interval_ms) {
                *out_actual_interval_ms = actual;
            }
            if (out_error) {
                *out_error = nullptr;
            }
        } else {
            if (out_json) {
                *out_json = nullptr;
            }
            if (out_actual_interval_ms) {
                *out_actual_interval_ms = 0.0;
            }
            if (out_error) {
                if (!error.empty()) {
                    char* buffer = static_cast<char*>(malloc(error.size() + 1));
                    if (buffer) {
                        memcpy(buffer, error.data(), error.size());
                        buffer[error.size()] = '\0';
                        *out_error = buffer;
                    } else {
                        *out_error = nullptr;
                    }
                } else {
                    *out_error = nullptr;
                }
            }
        }

        return static_cast<int>(status);
    }
}

extern "C" void hostfreq_free(char* ptr) {
    if (ptr != nullptr) {
        free(ptr);
    }
}

extern "C" const char* hostfreq_status_string(int status) {
    switch (status) {
        case HOSTFREQ_STATUS_OK:
            return "ok";
        case HOSTFREQ_STATUS_UNAVAILABLE:
            return "unavailable";
        case HOSTFREQ_STATUS_PERMISSION:
            return "permission";
        case HOSTFREQ_STATUS_INTERNAL:
            return "internal";
        default:
            return "unknown";
    }
}
