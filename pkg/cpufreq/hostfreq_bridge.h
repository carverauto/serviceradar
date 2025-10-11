#ifndef SERVICERADAR_CPUFREQ_HOSTFREQ_BRIDGE_H_
#define SERVICERADAR_CPUFREQ_HOSTFREQ_BRIDGE_H_

#ifdef __cplusplus
extern "C" {
#endif

enum {
    HOSTFREQ_STATUS_OK = 0,
    HOSTFREQ_STATUS_UNAVAILABLE = 1,
    HOSTFREQ_STATUS_PERMISSION = 2,
    HOSTFREQ_STATUS_INTERNAL = 3,
};

int hostfreq_collect_json(int interval_ms,
                          int sample_count,
                          char** out_json,
                          double* out_actual_interval_ms,
                          char** out_error);

void hostfreq_free(char* ptr);

const char* hostfreq_status_string(int status);

#ifdef __cplusplus
}
#endif

#endif  // SERVICERADAR_CPUFREQ_HOSTFREQ_BRIDGE_H_
