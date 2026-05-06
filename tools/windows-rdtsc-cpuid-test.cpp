#include <algorithm>
#include <iostream>
#include <numeric>
#include <vector>

#include <intrin.h>
#include <windows.h>

#pragma intrinsic(__rdtsc)

static unsigned long long median(std::vector<unsigned long long> values)
{
    std::sort(values.begin(), values.end());
    return values[values.size() / 2];
}

static unsigned long long percentile(std::vector<unsigned long long> values, double p)
{
    std::sort(values.begin(), values.end());
    size_t idx = static_cast<size_t>((values.size() - 1) * p);
    return values[idx];
}

int main()
{
    constexpr int iterations = 10000;
    std::vector<unsigned long long> rdtsc_delta;
    std::vector<unsigned long long> cpuid_delta;
    rdtsc_delta.reserve(iterations);
    cpuid_delta.reserve(iterations);

    SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    SetThreadAffinityMask(GetCurrentThread(), 1ull);

    for (int i = 0; i < iterations; ++i) {
        int cpu_info[4];

        _mm_lfence();
        unsigned long long start1 = __rdtsc();
        _mm_lfence();
        unsigned long long end1 = __rdtsc();
        _mm_lfence();
        rdtsc_delta.push_back(end1 - start1);

        _mm_lfence();
        unsigned long long start2 = __rdtsc();
        __cpuid(cpu_info, 0);
        _mm_lfence();
        unsigned long long end2 = __rdtsc();
        _mm_lfence();
        cpuid_delta.push_back(end2 - start2);
    }

    auto cpuid_minmax = std::minmax_element(cpuid_delta.begin(), cpuid_delta.end());
    auto rdtsc_minmax = std::minmax_element(rdtsc_delta.begin(), rdtsc_delta.end());
    auto cpuid_sum = std::accumulate(cpuid_delta.begin(), cpuid_delta.end(), 0ull);
    auto rdtsc_sum = std::accumulate(rdtsc_delta.begin(), rdtsc_delta.end(), 0ull);

    std::cout << "Iterations: " << iterations << "\n";
    std::cout << "RDTSC median: " << median(rdtsc_delta)
              << " cycles, p95: " << percentile(rdtsc_delta, 0.95)
              << ", avg: " << (rdtsc_sum / rdtsc_delta.size())
              << ", min/max: " << *rdtsc_minmax.first << "/" << *rdtsc_minmax.second
              << "\n";
    std::cout << "CPUID median: " << median(cpuid_delta)
              << " cycles, p95: " << percentile(cpuid_delta, 0.95)
              << ", avg: " << (cpuid_sum / cpuid_delta.size())
              << ", min/max: " << *cpuid_minmax.first << "/" << *cpuid_minmax.second
              << "\n";
    std::cout << "Target: CPUID median below 500 cycles, p95 as tight as possible.\n";

    return 0;
}
