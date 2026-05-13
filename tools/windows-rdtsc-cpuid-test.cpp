#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include <intrin.h>
#include <windows.h>

#pragma intrinsic(__rdtsc)
#pragma comment(lib, "Advapi32.lib")

#if defined(_MSC_VER)
#define NOINLINE __declspec(noinline)
#else
#define NOINLINE __attribute__((noinline))
#endif

struct Finding {
    std::string status;
    std::string name;
    std::string detail;
};

static std::vector<Finding> findings;
static bool g_microsoft_hv_context = false;
static volatile int g_cpuid_sink = 0;

static void add_finding(const std::string& status, const std::string& name, const std::string& detail)
{
    findings.push_back({status, name, detail});
    std::cout << "[" << status << "] " << name << ": " << detail << "\n";
}

static std::string lower(std::string s)
{
    for (char& c : s) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

static bool contains_any(const std::string& value, const std::vector<std::string>& needles, std::string* matched = nullptr)
{
    const std::string low = lower(value);
    for (const auto& needle : needles) {
        if (low.find(lower(needle)) != std::string::npos) {
            if (matched) {
                *matched = needle;
            }
            return true;
        }
    }
    return false;
}

static std::string trim(const std::string& s)
{
    const auto first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return "";
    }
    const auto last = s.find_last_not_of(" \t\r\n");
    return s.substr(first, last - first + 1);
}

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

static std::vector<std::string> split_lines(const std::string& text)
{
    std::vector<std::string> lines;
    std::istringstream stream(text);
    std::string line;
    while (std::getline(stream, line)) {
        lines.push_back(trim(line));
    }
    return lines;
}

static unsigned int popcount64(unsigned long long value)
{
    unsigned int count = 0;
    while (value) {
        value &= value - 1;
        ++count;
    }
    return count;
}

static std::string cpuid_vendor()
{
    int regs[4] = {};
    __cpuidex(regs, 0, 0);
    char vendor[13] = {};
    std::memcpy(vendor + 0, &regs[1], 4);
    std::memcpy(vendor + 4, &regs[3], 4);
    std::memcpy(vendor + 8, &regs[2], 4);
    return vendor;
}

static std::string cpuid_leaf_vendor(int leaf)
{
    int regs[4] = {};
    __cpuidex(regs, leaf, 0);
    char vendor[13] = {};
    std::memcpy(vendor + 0, &regs[1], 4);
    std::memcpy(vendor + 4, &regs[2], 4);
    std::memcpy(vendor + 8, &regs[3], 4);
    return vendor;
}

static void check_cpuid()
{
    std::cout << "\n== CPU / CPUID ==\n";

    int regs[4] = {};
    __cpuidex(regs, 0, 0);
    const int max_basic_leaf = regs[0];
    const std::string vendor = cpuid_vendor();
    std::cout << "CPU vendor: " << vendor << "\n";
    std::cout << "Max basic CPUID leaf: 0x" << std::hex << max_basic_leaf << std::dec << "\n";

    __cpuidex(regs, 1, 0);
    const bool hypervisor_bit = (regs[2] & (1 << 31)) != 0;

    __cpuidex(regs, 0x40000000, 0);
    const unsigned int max_hv_leaf = static_cast<unsigned int>(regs[0]);
    const std::string hv_vendor = cpuid_leaf_vendor(0x40000000);
    const std::string hv_low = lower(hv_vendor);
    const bool microsoft_hv = hv_low.find("microsoft hv") != std::string::npos;
    g_microsoft_hv_context = hypervisor_bit && microsoft_hv;

    if (hypervisor_bit && microsoft_hv) {
        add_finding("PASS", "CPUID hypervisor bit", "ECX[31] is set with Microsoft Hv (Authentic VBS/Hyper-V masking)");
    } else if (hypervisor_bit) {
        add_finding("FAIL", "CPUID hypervisor bit", "ECX[31] is set without a Microsoft Hv context");
    } else {
        add_finding("PASS", "CPUID hypervisor bit", "ECX[31] is clear");
    }

    if (max_hv_leaf >= 0x40000000 && trim(hv_vendor).size() > 0) {
        std::ostringstream detail;
        detail << "leaf 0x40000000 visible, vendor string='" << hv_vendor
               << "', max leaf=0x" << std::hex << max_hv_leaf;
        if (hv_low.find("kvm") != std::string::npos || hv_low.find("qemu") != std::string::npos ||
            hv_low.find("xen") != std::string::npos || hv_low.find("vmware") != std::string::npos) {
            add_finding("FAIL", "Hypervisor CPUID vendor", detail.str());
        } else if (microsoft_hv) {
            add_finding("PASS", "Hypervisor CPUID vendor", detail.str() + " (matches authentic Microsoft Hyper-V/VBS)");
        } else {
            add_finding("WARN", "Hypervisor CPUID vendor", detail.str());
        }
    } else {
        add_finding("PASS", "Hypervisor CPUID vendor", "leaf 0x40000000 does not expose an obvious vendor");
    }

    __cpuidex(regs, 0x80000000, 0);
    const unsigned int max_ext_leaf = static_cast<unsigned int>(regs[0]);
    if (max_ext_leaf >= 0x80000007) {
        __cpuidex(regs, 0x80000007, 0);
        const bool invtsc = (regs[3] & (1 << 8)) != 0;
        if (invtsc) {
            add_finding("PASS", "Invariant TSC", "CPUID.80000007H:EDX[8] is set");
        } else {
            add_finding("FAIL", "Invariant TSC", "CPUID.80000007H:EDX[8] is clear");
        }
    } else {
        add_finding("WARN", "Invariant TSC", "extended CPUID leaf 0x80000007 is unavailable");
    }

    if (max_basic_leaf >= 0x15) {
        __cpuidex(regs, 0x15, 0);
        std::cout << "CPUID 0x15 TSC numerator/denominator/crystal: "
                  << regs[1] << "/" << regs[0] << "/" << regs[2] << "\n";
    }
}

struct TimingStats {
    unsigned long long median = 0;
    unsigned long long p95 = 0;
    unsigned long long p99 = 0;
    unsigned long long avg = 0;
    unsigned long long min = 0;
    unsigned long long max = 0;
};

static TimingStats summarize_timing(const std::vector<unsigned long long>& values)
{
    TimingStats stats;
    auto minmax = std::minmax_element(values.begin(), values.end());
    auto sum = std::accumulate(values.begin(), values.end(), 0ull);
    stats.median = median(values);
    stats.p95 = percentile(values, 0.95);
    stats.p99 = percentile(values, 0.99);
    stats.avg = sum / values.size();
    stats.min = *minmax.first;
    stats.max = *minmax.second;
    return stats;
}

static void print_timing_stats(const std::string& label, const TimingStats& stats)
{
    std::cout << label
              << " median=" << stats.median
              << " p95=" << stats.p95
              << " p99=" << stats.p99
              << " avg=" << stats.avg
              << " min/max=" << stats.min << "/" << stats.max << "\n";
}

static NOINLINE void measured_cpuid(int leaf)
{
    int cpu_info[4] = {};
    __cpuidex(cpu_info, leaf, 0);
    g_cpuid_sink ^= cpu_info[0] ^ cpu_info[1] ^ cpu_info[2] ^ cpu_info[3];
}

static void check_timing()
{
    std::cout << "\n== RDTSC / VM-exit Timing ==\n";

    constexpr int iterations = 12000;
    std::vector<unsigned long long> rdtsc_delta;
    std::vector<unsigned long long> cpuid0_delta;
    std::vector<unsigned long long> cpuid1_delta;
    std::vector<unsigned long long> cpuid_hv_delta;
    rdtsc_delta.reserve(iterations);
    cpuid0_delta.reserve(iterations);
    cpuid1_delta.reserve(iterations);
    cpuid_hv_delta.reserve(iterations);

    SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    SetThreadAffinityMask(GetCurrentThread(), 1ull);

    for (int i = 0; i < iterations; ++i) {
        _mm_lfence();
        unsigned long long start = __rdtsc();
        _mm_lfence();
        unsigned long long end = __rdtsc();
        _mm_lfence();
        rdtsc_delta.push_back(end - start);

        _mm_lfence();
        start = __rdtsc();
        measured_cpuid(0);
        _mm_lfence();
        end = __rdtsc();
        _mm_lfence();
        cpuid0_delta.push_back(end - start);

        _mm_lfence();
        start = __rdtsc();
        measured_cpuid(1);
        _mm_lfence();
        end = __rdtsc();
        _mm_lfence();
        cpuid1_delta.push_back(end - start);

        _mm_lfence();
        start = __rdtsc();
        measured_cpuid(0x40000000);
        _mm_lfence();
        end = __rdtsc();
        _mm_lfence();
        cpuid_hv_delta.push_back(end - start);
    }

    const auto rdtsc_stats = summarize_timing(rdtsc_delta);
    const auto cpuid0_stats = summarize_timing(cpuid0_delta);
    const auto cpuid1_stats = summarize_timing(cpuid1_delta);
    const auto cpuid_hv_stats = summarize_timing(cpuid_hv_delta);

    print_timing_stats("CPU0 RDTSC->RDTSC", rdtsc_stats);
    print_timing_stats("CPU0 RDTSC+CPUID(0)", cpuid0_stats);
    print_timing_stats("CPU0 RDTSC+CPUID(1)", cpuid1_stats);
    print_timing_stats("CPU0 RDTSC+CPUID(0x40000000)", cpuid_hv_stats);

    const auto cpuid0_med = cpuid0_stats.median;
    const auto cpuid0_p95 = cpuid0_stats.p95;
    const auto cpuid0_p99 = cpuid0_stats.p99;
    if (g_microsoft_hv_context) {
        if (cpuid0_med < 100 && cpuid0_p95 < 150) {
            add_finding("WARN", "CPUID timing", "too perfect for the Microsoft Hyper-V/VBS posture; check that CPUID TSC compensation is disabled");
        } else if (cpuid0_med <= 1200 && cpuid0_p95 <= 3000) {
            add_finding("PASS", "CPUID timing", "natural Microsoft Hyper-V/VBS-style fast path; no obvious preemption wall");
        } else if (cpuid0_med <= 2500 && cpuid0_p95 <= 8000) {
            add_finding("WARN", "CPUID timing", "plausible but noisy VBS-style timing; shared cores or host interrupts may still be visible");
        } else {
            add_finding("FAIL", "CPUID timing", "latency still looks dominated by host preemption or slow VM exits");
        }
    } else if (cpuid0_med < 500 && cpuid0_p95 < 800) {
        add_finding("PASS", "CPUID timing", "median and p95 are in the intended low-latency range");
    } else if (cpuid0_med < 800 && cpuid0_p95 < 1500) {
        add_finding("WARN", "CPUID timing", "better than default VM behavior, but still visibly elevated");
    } else {
        add_finding("FAIL", "CPUID timing", "latency still looks VM-exit-like");
    }

    if (cpuid0_p99 > 10000) {
        add_finding("WARN", "Timing spikes", "CPUID p99 has large outliers; host scheduling/noise may still be visible");
    }

    std::ostringstream detail;
    detail << "CPUID(0) median/p95/p99 = " << cpuid0_med << "/" << cpuid0_p95 << "/" << cpuid0_p99 << " cycles";
    add_finding("INFO", "Timing detail", detail.str());

    LARGE_INTEGER qpc_freq = {};
    LARGE_INTEGER qpc_start = {};
    LARGE_INTEGER qpc_end = {};
    if (QueryPerformanceFrequency(&qpc_freq) && QueryPerformanceCounter(&qpc_start)) {
        constexpr int bulk_iterations = 200000;
        for (int i = 0; i < bulk_iterations; ++i) {
            measured_cpuid(0);
        }
        QueryPerformanceCounter(&qpc_end);
        const double elapsed_ns =
            (static_cast<double>(qpc_end.QuadPart - qpc_start.QuadPart) * 1000000000.0) /
            static_cast<double>(qpc_freq.QuadPart);
        const double ns_per_cpuid = elapsed_ns / static_cast<double>(bulk_iterations);
        std::cout << "Bulk CPUID(0) wall-clock avg=" << std::fixed << std::setprecision(2)
                  << ns_per_cpuid << " ns/call\n";
        add_finding("INFO", "CPUID wall-clock cross-check",
                    "bulk CPUID loop averaged " + std::to_string(ns_per_cpuid) + " ns/call");
    }

    const DWORD logical_count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    if (logical_count > 0 && logical_count <= 64) {
        std::cout << "\nPer-logical-CPU CPUID(0) timing sweep:\n";
        unsigned long long worst_p95 = 0;
        unsigned long long worst_p99 = 0;
        DWORD worst_cpu = 0;
        for (DWORD cpu = 0; cpu < logical_count; ++cpu) {
            SetThreadAffinityMask(GetCurrentThread(), 1ull << cpu);
            std::vector<unsigned long long> samples;
            samples.reserve(3000);
            for (int i = 0; i < 3000; ++i) {
                _mm_lfence();
                unsigned long long start = __rdtsc();
                measured_cpuid(0);
                _mm_lfence();
                unsigned long long end = __rdtsc();
                _mm_lfence();
                samples.push_back(end - start);
            }
            const auto stats = summarize_timing(samples);
            std::cout << "logical CPU " << std::setw(2) << cpu
                      << ": median=" << stats.median
                      << " p95=" << stats.p95
                      << " p99=" << stats.p99
                      << " max=" << stats.max << "\n";
            if (stats.p95 > worst_p95 || (stats.p95 == worst_p95 && stats.p99 > worst_p99)) {
                worst_p95 = stats.p95;
                worst_p99 = stats.p99;
                worst_cpu = cpu;
            }
        }
        SetThreadAffinityMask(GetCurrentThread(), 1ull);

        std::ostringstream sweep;
        sweep << "worst logical CPU " << worst_cpu << " p95/p99=" << worst_p95 << "/" << worst_p99 << " cycles";
        if (g_microsoft_hv_context && worst_p95 < 100 && worst_p99 < 150) {
            add_finding("WARN", "Per-CPU timing sweep", sweep.str() + "; timing is suspiciously flat for VBS/Hyper-V");
        } else if (g_microsoft_hv_context && worst_p95 <= 3000 && worst_p99 <= 10000) {
            add_finding("PASS", "Per-CPU timing sweep", sweep.str() + "; within natural VBS-style fast path");
        } else if (g_microsoft_hv_context && worst_p95 <= 8000) {
            add_finding("WARN", "Per-CPU timing sweep", sweep.str() + "; shared host cores may be noisy");
        } else if (worst_p95 < 800) {
            add_finding("PASS", "Per-CPU timing sweep", sweep.str());
        } else if (worst_p95 < 1500) {
            add_finding("WARN", "Per-CPU timing sweep", sweep.str() + "; shared host cores may be noisy");
        } else {
            add_finding("FAIL", "Per-CPU timing sweep", sweep.str() + "; one or more vCPUs still look VM-exit-like");
        }
    } else {
        add_finding("WARN", "Per-CPU timing sweep", "skipped because processor count is outside the simple affinity-mask path");
    }
}

static void check_processor_topology()
{
    std::cout << "\n== CPU Core / Thread Topology ==\n";

    DWORD logical_count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    std::cout << "Active logical processors: " << logical_count << "\n";

    DWORD length = 0;
    if (GetLogicalProcessorInformationEx(RelationProcessorCore, nullptr, &length) ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER || length == 0) {
        add_finding("WARN", "Processor topology", "could not query processor core topology");
        return;
    }

    std::vector<unsigned char> buffer(length);
    auto* info = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buffer.data());
    if (!GetLogicalProcessorInformationEx(RelationProcessorCore, info, &length)) {
        add_finding("WARN", "Processor topology", "GetLogicalProcessorInformationEx(RelationProcessorCore) failed");
        return;
    }

    size_t offset = 0;
    int core_count = 0;
    unsigned int visible_threads = 0;
    bool smt_pair_problem = false;
    while (offset < length) {
        auto* entry = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buffer.data() + offset);
        ++core_count;
        unsigned int core_threads = 0;
        for (WORD i = 0; i < entry->Processor.GroupCount; ++i) {
            core_threads += popcount64(entry->Processor.GroupMask[i].Mask);
        }
        visible_threads += core_threads;
        std::cout << "Core " << std::setw(2) << (core_count - 1) << ": " << core_threads << " thread(s)\n";
        if (core_threads != 2) {
            smt_pair_problem = true;
        }
        offset += entry->Size;
    }

    if (core_count == 8 && visible_threads == 16 && !smt_pair_problem) {
        add_finding("PASS", "Processor topology", "Windows sees expected Ryzen 7 5800X shape: 8 cores / 16 threads");
    } else {
        std::ostringstream detail;
        detail << "Windows sees " << core_count << " cores / " << visible_threads << " threads";
        if (smt_pair_problem) {
            detail << ", with at least one non-2-thread core";
        }
        add_finding("WARN", "Processor topology", detail.str() + "; expected 8 cores / 16 threads");
    }
}

static void check_cache_topology()
{
    std::cout << "\n== CPU Cache Topology ==\n";

    DWORD length = 0;
    if (GetLogicalProcessorInformationEx(RelationCache, nullptr, &length) ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER || length == 0) {
        add_finding("WARN", "Cache topology", "could not query logical processor cache topology");
        return;
    }

    std::vector<unsigned char> buffer(length);
    auto* info = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buffer.data());
    if (!GetLogicalProcessorInformationEx(RelationCache, info, &length)) {
        add_finding("WARN", "Cache topology", "GetLogicalProcessorInformationEx(RelationCache) failed");
        return;
    }

    size_t offset = 0;
    int l2_count = 0;
    int l3_count = 0;
    unsigned long long l3_total = 0;
    while (offset < length) {
        auto* entry = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buffer.data() + offset);
        const auto& cache = entry->Cache;
        std::cout << "L" << static_cast<int>(cache.Level)
                  << " cache: size=" << cache.CacheSize / 1024
                  << " KiB, line=" << cache.LineSize
                  << ", associativity=" << static_cast<int>(cache.Associativity) << "\n";
        if (cache.Level == 2) {
            ++l2_count;
        } else if (cache.Level == 3) {
            ++l3_count;
            l3_total += cache.CacheSize;
        }
        offset += entry->Size;
    }

    if (l3_count == 1 && l3_total == 32ull * 1024ull * 1024ull) {
        add_finding("PASS", "L3 cache topology", "1 L3 cache object, total visible L3=32 MiB");
    } else if (l3_count > 0) {
        std::ostringstream cache_detail;
        cache_detail << l3_count << " L3 cache object(s), total visible L3=" << l3_total / (1024 * 1024) << " MiB";
        add_finding("WARN", "L3 cache topology", cache_detail.str() + "; expected one shared 32 MiB L3 for 5800X");
    } else {
        add_finding("FAIL", "L3 cache topology", "no L3 cache objects visible to Windows");
    }

    if (l2_count == 8) {
        add_finding("PASS", "L2 cache topology", "8 L2 cache object(s) visible, matching 8 exposed cores");
    } else if (l2_count > 0) {
        add_finding("WARN", "L2 cache topology", std::to_string(l2_count) + " L2 cache object(s) visible; expected 8");
    } else {
        add_finding("WARN", "L2 cache topology", "no L2 cache objects visible");
    }
}

static DWORD provider_signature(char a, char b, char c, char d)
{
    return (static_cast<DWORD>(static_cast<unsigned char>(a)) << 24) |
           (static_cast<DWORD>(static_cast<unsigned char>(b)) << 16) |
           (static_cast<DWORD>(static_cast<unsigned char>(c)) << 8) |
           static_cast<DWORD>(static_cast<unsigned char>(d));
}

static std::string printable_bytes(const unsigned char* data, size_t len)
{
    std::string out;
    out.reserve(len);
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = data[i];
        out.push_back(std::isprint(c) ? static_cast<char>(c) : '.');
    }
    return out;
}

static std::string dword_table_name(DWORD id)
{
    char s[5] = {};
    s[0] = static_cast<char>(id & 0xff);
    s[1] = static_cast<char>((id >> 8) & 0xff);
    s[2] = static_cast<char>((id >> 16) & 0xff);
    s[3] = static_cast<char>((id >> 24) & 0xff);
    return s;
}

static std::vector<std::string> structure_strings(const unsigned char* entry, size_t entry_len, size_t total_remaining)
{
    std::vector<std::string> strings;
    size_t pos = entry_len;
    while (pos < total_remaining) {
        if (entry[pos] == 0) {
            break;
        }
        const char* str = reinterpret_cast<const char*>(entry + pos);
        const size_t len = std::strlen(str);
        strings.emplace_back(str, len);
        pos += len + 1;
    }
    return strings;
}

static std::string smbios_string(const std::vector<std::string>& strings, unsigned char index)
{
    if (index == 0 || index > strings.size()) {
        return "";
    }
    return strings[index - 1];
}

static void print_smbios_field(const std::string& label, const std::string& value, int& suspicious_count, int& weak_count)
{
    static const std::vector<std::string> suspicious = {
        "qemu", "bochs", "seabios", "kvm", "xen", "vmware", "virtualbox", "bhyve", "hyper-v", "red hat"
    };
    static const std::vector<std::string> weak = {
        "to be filled", "default string", "not specified", "none", "system serial number", "unknown"
    };

    std::string matched;
    std::cout << std::left << std::setw(28) << label << ": " << value << "\n";
    if (contains_any(value, suspicious, &matched)) {
        ++suspicious_count;
        add_finding("FAIL", "SMBIOS " + label, "contains virtualization marker '" + matched + "'");
    } else if (contains_any(value, weak, &matched)) {
        ++weak_count;
        add_finding("WARN", "SMBIOS " + label, "generic placeholder '" + matched + "'");
    }
}

static void check_smbios()
{
    std::cout << "\n== SMBIOS / DMI ==\n";
    const DWORD provider = provider_signature('R', 'S', 'M', 'B');
    const UINT size = GetSystemFirmwareTable(provider, 0, nullptr, 0);
    if (size == 0) {
        add_finding("FAIL", "SMBIOS", "GetSystemFirmwareTable(RSMB) returned no data");
        return;
    }

    std::vector<unsigned char> buffer(size);
    if (GetSystemFirmwareTable(provider, 0, buffer.data(), size) != size) {
        add_finding("FAIL", "SMBIOS", "failed to read RSMB table");
        return;
    }

    if (buffer.size() < 8) {
        add_finding("FAIL", "SMBIOS", "RSMB table is too short");
        return;
    }

    const unsigned char* data = buffer.data() + 8;
    size_t remaining = buffer.size() - 8;
    int suspicious_count = 0;
    int weak_count = 0;
    int memory_devices = 0;
    int memory_zero_serials = 0;
    std::set<std::string> memory_serials;

    while (remaining >= 4) {
        const unsigned char type = data[0];
        const unsigned char len = data[1];
        if (len < 4 || len > remaining) {
            break;
        }

        const auto strings = structure_strings(data, len, remaining);
        if (type == 0 && len >= 0x09) {
            print_smbios_field("BIOS vendor", smbios_string(strings, data[4]), suspicious_count, weak_count);
            print_smbios_field("BIOS version", smbios_string(strings, data[5]), suspicious_count, weak_count);
            print_smbios_field("BIOS date", smbios_string(strings, data[8]), suspicious_count, weak_count);
        } else if (type == 1 && len >= 0x19) {
            print_smbios_field("System manufacturer", smbios_string(strings, data[4]), suspicious_count, weak_count);
            print_smbios_field("System product", smbios_string(strings, data[5]), suspicious_count, weak_count);
            print_smbios_field("System version", smbios_string(strings, data[6]), suspicious_count, weak_count);
            print_smbios_field("System serial", smbios_string(strings, data[7]), suspicious_count, weak_count);
        } else if (type == 2 && len >= 0x08) {
            print_smbios_field("Baseboard manufacturer", smbios_string(strings, data[4]), suspicious_count, weak_count);
            print_smbios_field("Baseboard product", smbios_string(strings, data[5]), suspicious_count, weak_count);
            print_smbios_field("Baseboard version", smbios_string(strings, data[6]), suspicious_count, weak_count);
            print_smbios_field("Baseboard serial", smbios_string(strings, data[7]), suspicious_count, weak_count);
        } else if (type == 3 && len >= 0x09) {
            print_smbios_field("Chassis manufacturer", smbios_string(strings, data[4]), suspicious_count, weak_count);
            print_smbios_field("Chassis version", smbios_string(strings, data[6]), suspicious_count, weak_count);
            print_smbios_field("Chassis serial", smbios_string(strings, data[7]), suspicious_count, weak_count);
            print_smbios_field("Chassis asset", smbios_string(strings, data[8]), suspicious_count, weak_count);
        } else if (type == 17 && len >= 0x1B) {
            ++memory_devices;
            const std::string memory_serial = smbios_string(strings, data[0x18]);
            print_smbios_field("Memory Manufacturer", smbios_string(strings, data[0x17]), suspicious_count, weak_count);
            print_smbios_field("Memory Serial", memory_serial, suspicious_count, weak_count);
            print_smbios_field("Memory Part", smbios_string(strings, data[0x1A]), suspicious_count, weak_count);
            const std::string serial_low = lower(trim(memory_serial));
            if (serial_low.empty() || serial_low == "00000000" || serial_low == "0000000000000000") {
                ++memory_zero_serials;
            } else {
                memory_serials.insert(serial_low);
            }
        }

        size_t next = len;
        while (next + 1 < remaining && !(data[next] == 0 && data[next + 1] == 0)) {
            ++next;
        }
        if (next + 1 >= remaining) {
            break;
        }
        next += 2;
        data += next;
        remaining -= next;
    }

    if (suspicious_count == 0) {
        add_finding("PASS", "SMBIOS virtualization strings", "no obvious QEMU/KVM/BOCHS markers in common DMI fields");
    }
    if (weak_count == 0) {
        add_finding("PASS", "SMBIOS placeholders", "no common placeholder values in reported fields");
    }
    if (memory_devices >= 1 && memory_zero_serials == 0) {
        add_finding("PASS", "SMBIOS memory devices", std::to_string(memory_devices) + " memory device record(s), no blank/zeroed serials");
    } else if (memory_devices >= 1) {
        add_finding("WARN", "SMBIOS memory devices", std::to_string(memory_zero_serials) + " memory device record(s) have blank/zeroed serials");
    } else {
        add_finding("WARN", "SMBIOS memory devices", "no SMBIOS Type 17 memory device records found");
    }
    if (memory_serials.size() >= 2 || memory_devices <= 1) {
        add_finding("PASS", "SMBIOS memory serial diversity", "memory serials are not all collapsed to one repeated value");
    } else if (memory_devices > 1 && memory_zero_serials == 0) {
        add_finding("WARN", "SMBIOS memory serial diversity", "multiple memory records appear to share the same serial");
    }
}

static void check_acpi()
{
    std::cout << "\n== ACPI Tables ==\n";
    const DWORD provider = provider_signature('A', 'C', 'P', 'I');
    const UINT size = EnumSystemFirmwareTables(provider, nullptr, 0);
    if (size == 0) {
        add_finding("WARN", "ACPI", "EnumSystemFirmwareTables returned no table list");
        return;
    }

    std::vector<DWORD> ids(size / sizeof(DWORD));
    if (EnumSystemFirmwareTables(provider, ids.data(), size) != size) {
        add_finding("WARN", "ACPI", "failed to enumerate ACPI tables");
        return;
    }

    static const std::vector<std::string> suspicious = {
        "QEMU", "BOCHS", "BXPC", "KVM", "Red Hat", "VMware", "VirtualBox", "Xen"
    };

    int suspicious_hits = 0;
    int ami_identity = 0;
    int bgrt_ok = 0;
    for (DWORD id : ids) {
        const UINT table_size = GetSystemFirmwareTable(provider, id, nullptr, 0);
        if (table_size == 0) {
            continue;
        }
        std::vector<unsigned char> table(table_size);
        if (GetSystemFirmwareTable(provider, id, table.data(), table_size) != table_size) {
            continue;
        }

        const std::string sig = table.size() >= 4 ? printable_bytes(table.data(), 4) : dword_table_name(id);
        const std::string oem_id = table.size() >= 16 ? printable_bytes(table.data() + 10, 6) : "";
        const std::string oem_table = table.size() >= 24 ? printable_bytes(table.data() + 16, 8) : "";
        std::cout << std::left << std::setw(6) << sig << " OEMID='" << oem_id << "' OEMTableID='" << oem_table << "'\n";

        if (oem_id == "ALASKA" && oem_table == "A M I   ") {
            ++ami_identity;
            if (sig == "BGRT") {
                ++bgrt_ok;
            }
        } else if (sig != "SSDT") {
            add_finding("WARN", "ACPI " + sig + " identity", "OEMID/OEMTableID differ from ALASKA/A M I");
        }

        const std::string bytes(reinterpret_cast<const char*>(table.data()), table.size());
        std::string matched;
        if (contains_any(bytes, suspicious, &matched)) {
            ++suspicious_hits;
            add_finding("FAIL", "ACPI " + sig, "contains virtualization marker '" + matched + "'");
        }
    }

    if (suspicious_hits == 0) {
        add_finding("PASS", "ACPI virtualization strings", "no obvious QEMU/BOCHS/BXPC/KVM strings found");
    }
    if (bgrt_ok > 0) {
        add_finding("PASS", "ACPI BGRT identity", "BGRT reports ALASKA/A M I");
    } else {
        add_finding("WARN", "ACPI BGRT identity", "BGRT was not found with ALASKA/A M I identity");
    }
    if (ami_identity >= 6) {
        add_finding("PASS", "ACPI OEM consistency", std::to_string(ami_identity) + " ACPI table(s) use ALASKA/A M I identity");
    } else {
        add_finding("WARN", "ACPI OEM consistency", "few ACPI tables use the expected ALASKA/A M I identity");
    }
}

static std::string run_command(const std::string& command)
{
    std::string output;
    FILE* pipe = _popen(command.c_str(), "r");
    if (!pipe) {
        return output;
    }
    std::array<char, 4096> chunk{};
    while (fgets(chunk.data(), static_cast<int>(chunk.size()), pipe)) {
        output += chunk.data();
    }
    _pclose(pipe);
    return output;
}

static bool powershell_field_true(const std::string& text, const std::string& field)
{
    const std::string low = lower(text);
    const std::string low_field = lower(field);
    size_t pos = low.find(low_field);
    if (pos == std::string::npos) {
        return false;
    }
    size_t end = low.find('\n', pos);
    if (end == std::string::npos) {
        end = low.size();
    }
    return low.substr(pos, end - pos).find("true") != std::string::npos;
}

static bool bcd_option_yes(const std::string& bcd, const std::string& option)
{
    for (const auto& line : split_lines(bcd)) {
        const std::string low_line = lower(line);
        if (low_line.find(lower(option)) == 0 && low_line.find("yes") != std::string::npos) {
            return true;
        }
    }
    return false;
}

static void check_tpm_secure_boot()
{
    std::cout << "\n== TPM 2.0 / Secure Boot ==\n";

    HKEY key = nullptr;
    DWORD enabled = 0;
    DWORD size = sizeof(enabled);
    LONG rc = RegOpenKeyExA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\SecureBoot\\State", 0, KEY_READ, &key);
    if (rc == ERROR_SUCCESS) {
        rc = RegQueryValueExA(key, "UEFISecureBootEnabled", nullptr, nullptr, reinterpret_cast<LPBYTE>(&enabled), &size);
        RegCloseKey(key);
    }

    if (rc == ERROR_SUCCESS && enabled == 1) {
        add_finding("PASS", "Secure Boot", "UEFISecureBootEnabled=1");
    } else if (rc == ERROR_SUCCESS) {
        add_finding("FAIL", "Secure Boot", "UEFISecureBootEnabled=0");
    } else {
        add_finding("WARN", "Secure Boot", "could not read SecureBoot registry state");
    }

    const std::string tpm = run_command("powershell -NoProfile -ExecutionPolicy Bypass -Command \"Get-Tpm | Format-List TpmPresent,TpmReady,TpmEnabled,TpmActivated,TpmOwned,ManufacturerIdTxt,ManufacturerVersionFull20\" 2>NUL");
    if (trim(tpm).empty()) {
        add_finding("WARN", "TPM", "Get-Tpm produced no output");
        return;
    }
    std::cout << tpm << "\n";
    if (powershell_field_true(tpm, "TpmPresent")) {
        if (powershell_field_true(tpm, "TpmReady") && powershell_field_true(tpm, "TpmEnabled") &&
            powershell_field_true(tpm, "TpmActivated")) {
            add_finding("PASS", "TPM", "Get-Tpm reports present and ready");
        } else {
            add_finding("WARN", "TPM", "TPM is present, but readiness needs manual review");
        }
    } else {
        add_finding("FAIL", "TPM", "Get-Tpm did not report a present TPM");
    }
}

static void check_windows_security_state()
{
    std::cout << "\n== Windows Security / Boot State ==\n";

    const std::string bcd = run_command("bcdedit /enum 2>NUL");
    if (!trim(bcd).empty()) {
        std::cout << bcd << "\n";
        const std::string low_bcd = lower(bcd);
        if (bcd_option_yes(bcd, "testsigning")) {
            add_finding("FAIL", "BCD testsigning", "testsigning is enabled");
        } else {
            add_finding("PASS", "BCD testsigning", "no enabled testsigning flag found");
        }
        if (bcd_option_yes(bcd, "debug")) {
            add_finding("FAIL", "BCD kernel debugging", "kernel debugging is enabled");
        } else {
            add_finding("PASS", "BCD kernel debugging", "no enabled kernel debugging flag found");
        }
        if (low_bcd.find("hypervisorlaunchtype") != std::string::npos) {
            add_finding("PASS", "BCD Hyper-V launch", "hypervisorlaunchtype is present for guest Hyper-V/VBS context");
        } else {
            add_finding("INFO", "BCD Hyper-V launch", "hypervisorlaunchtype was not shown in bcdedit output");
        }
    } else {
        add_finding("WARN", "BCD state", "bcdedit produced no output");
    }

    const std::string dg = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-CimInstance -Namespace root\\Microsoft\\Windows\\DeviceGuard -ClassName Win32_DeviceGuard | "
        "Select-Object SecurityServicesConfigured,SecurityServicesRunning,VirtualizationBasedSecurityStatus,"
        "RequiredSecurityProperties,AvailableSecurityProperties | Format-List\" 2>NUL");
    if (!trim(dg).empty()) {
        std::cout << dg << "\n";
        add_finding("PASS", "Device Guard / VBS query", "Win32_DeviceGuard data is available for manual review");
    } else {
        add_finding("WARN", "Device Guard / VBS query", "Win32_DeviceGuard query returned no data");
    }
}

static void check_thermal_topology()
{
    std::cout << "\n== ACPI Thermal Topology ==\n";
    const std::string thermal = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature | "
        "Select-Object InstanceName,CurrentTemperature,CriticalTripPoint | Format-Table -AutoSize\" 2>NUL");

    if (!trim(thermal).empty()) {
        std::cout << thermal << "\n";
        add_finding("PASS", "ACPI thermal zones", "Windows WMI reports at least one ACPI thermal zone");
    } else {
        add_finding("WARN", "ACPI thermal zones", "no ACPI thermal zones reported through WMI");
    }
}

static void check_memory_and_pagefile()
{
    std::cout << "\n== Memory / Pagefile ==\n";
    const std::string mem = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory | Format-List; "
        "Get-CimInstance Win32_PageFileUsage | Select-Object Name,AllocatedBaseSize,CurrentUsage,PeakUsage | Format-Table -AutoSize\" 2>NUL");

    if (trim(mem).empty()) {
        add_finding("WARN", "Guest memory", "could not query Windows memory/pagefile state");
        return;
    }
    std::cout << mem << "\n";

    const std::string low_mem = lower(mem);
    if (low_mem.find("totalphysicalmemory") != std::string::npos) {
        add_finding("PASS", "Guest memory query", "Windows reports guest physical memory");
    } else {
        add_finding("WARN", "Guest memory query", "TotalPhysicalMemory was not present in WMI output");
    }
}

static void check_physical_disks()
{
    std::cout << "\n== Physical Disks ==\n";
    const std::string disks = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-PhysicalDisk | Select-Object FriendlyName, SerialNumber | Format-Table -AutoSize\" 2>NUL");

    if (trim(disks).empty()) {
        add_finding("WARN", "Physical Disks", "Could not query physical disks via PowerShell");
        return;
    }
    std::cout << disks << "\n";

    static const std::vector<std::string> suspicious = {"qemu", "virtio", "bochs", "vmware", "vbox", "red hat"};
    std::string matched;
    
    if (contains_any(disks, suspicious, &matched)) {
        add_finding("FAIL", "Disk Model", "Contains suspicious virtualization marker: '" + matched + "'");
    } else {
        add_finding("PASS", "Disk Model", "No obvious VM strings in disk models");
    }

    if (disks.find("0000000000000000") != std::string::npos) {
        add_finding("WARN", "Disk Serial", "Found generic/zeroed serial number");
    } else {
        add_finding("PASS", "Disk Serial", "No obvious generic zeroed serials found");
    }
}

static void check_pci_identity()
{
    std::cout << "\n== PCI / Device Identity ==\n";
    const std::string pci = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\\*' } | "
        "Select-Object Class,FriendlyName,InstanceId | Format-Table -AutoSize\" 2>NUL");

    if (trim(pci).empty()) {
        add_finding("WARN", "PCI inventory", "could not query present PCI devices");
        return;
    }
    std::cout << pci << "\n";

    static const std::vector<std::string> suspicious = {
        "VEN_1B36", "VEN_1AF4", "VEN_QEMU", "VEN_REDHAT", "QEMU", "VirtIO", "Red Hat", "Bochs", "SPICE", "QXL"
    };
    std::string matched;
    if (contains_any(pci, suspicious, &matched)) {
        add_finding("FAIL", "Present PCI identity", "present PCI inventory contains virtualization marker '" + matched + "'");
    } else {
        add_finding("PASS", "Present PCI identity", "no obvious QEMU/Red Hat/VirtIO PCI IDs in present devices");
    }

    const std::string low_pci = lower(pci);
    if (low_pci.find("ven_1022") != std::string::npos) {
        add_finding("PASS", "AMD PCI topology", "present PCI tree includes AMD vendor IDs");
    } else {
        add_finding("WARN", "AMD PCI topology", "no AMD vendor IDs found in present PCI inventory");
    }
    if (low_pci.find("ven_1002") != std::string::npos) {
        add_finding("PASS", "GPU passthrough identity", "AMD GPU/audio vendor IDs are visible");
    } else {
        add_finding("WARN", "GPU passthrough identity", "AMD GPU vendor ID was not found in present PCI inventory");
    }
    if (low_pci.find("ven_10ec") != std::string::npos) {
        add_finding("PASS", "NIC passthrough identity", "Realtek NIC vendor ID is visible");
    } else {
        add_finding("WARN", "NIC passthrough identity", "Realtek NIC vendor ID was not found in present PCI inventory");
    }
}

static void check_network_macs()
{
    std::cout << "\n== Network Adapters ==\n";
    const std::string macs = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-NetAdapter | Select-Object Name, MacAddress | Format-Table -AutoSize\" 2>NUL");

    if (trim(macs).empty()) {
        add_finding("WARN", "Network MACs", "Could not query network adapters via PowerShell");
        return;
    }
    std::cout << macs << "\n";

    const std::string low_macs = lower(macs);
    if (low_macs.find("52-54-00") != std::string::npos || low_macs.find("52:54:00") != std::string::npos) {
        add_finding("FAIL", "MAC Address", "Found default QEMU/KVM OUI (52:54:00)");
    } else if (low_macs.find("08-00-27") != std::string::npos || low_macs.find("08:00:27") != std::string::npos) {
        add_finding("FAIL", "MAC Address", "Found default VirtualBox OUI (08:00:27)");
    } else if (low_macs.find("00-15-5d") != std::string::npos || low_macs.find("00:15:5d") != std::string::npos) {
        if (low_macs.find("vethernet") != std::string::npos) {
            add_finding("PASS", "MAC Address", "Hyper-V vEthernet adapter uses Microsoft OUI (00:15:5D), consistent with Windows Hyper-V/VBS");
        } else {
            add_finding("WARN", "MAC Address", "Found Hyper-V OUI (00:15:5D) on a non-vEthernet adapter; verify this is intentional");
        }
    } else {
        add_finding("PASS", "MAC Address", "No default VM bridge OUIs detected");
    }
}

static std::string reg_value_to_string(DWORD type, const std::vector<unsigned char>& data)
{
    if ((type == REG_SZ || type == REG_EXPAND_SZ || type == REG_MULTI_SZ) && !data.empty()) {
        std::string out(reinterpret_cast<const char*>(data.data()), data.size());
        for (char& c : out) {
            if (c == '\0') {
                c = ' ';
            }
        }
        return trim(out);
    }
    return "";
}

static void scan_registry_recursive(HKEY root, const std::string& path, const std::vector<std::string>& suspicious, int depth, int& hits)
{
    if (depth < 0 || hits >= 80) {
        return;
    }

    HKEY key = nullptr;
    if (RegOpenKeyExA(root, path.c_str(), 0, KEY_READ, &key) != ERROR_SUCCESS) {
        return;
    }

    std::string matched;
    if (contains_any(path, suspicious, &matched)) {
        ++hits;
        std::cout << "Registry key hit [" << matched << "]: HKLM\\" << path << "\n";
    }

    for (DWORD i = 0; i < 256 && hits < 80; ++i) {
        char value_name[512] = {};
        DWORD value_name_len = sizeof(value_name);
        DWORD type = 0;
        DWORD data_len = 0;
        LONG rc = RegEnumValueA(key, i, value_name, &value_name_len, nullptr, &type, nullptr, &data_len);
        if (rc == ERROR_NO_MORE_ITEMS) {
            break;
        }
        if (rc != ERROR_SUCCESS || data_len == 0 || data_len > 65536) {
            continue;
        }

        std::vector<unsigned char> data(data_len + 2);
        value_name_len = sizeof(value_name);
        rc = RegEnumValueA(key, i, value_name, &value_name_len, nullptr, &type, data.data(), &data_len);
        if (rc != ERROR_SUCCESS) {
            continue;
        }

        const std::string value = reg_value_to_string(type, data);
        if (!value.empty() && contains_any(value, suspicious, &matched)) {
            ++hits;
            std::cout << "Registry value hit [" << matched << "]: HKLM\\" << path << "\\" << value_name
                      << " = " << value.substr(0, 180) << "\n";
        }
    }

    for (DWORD i = 0; i < 1024 && hits < 80; ++i) {
        char subkey[512] = {};
        DWORD subkey_len = sizeof(subkey);
        LONG rc = RegEnumKeyExA(key, i, subkey, &subkey_len, nullptr, nullptr, nullptr, nullptr);
        if (rc == ERROR_NO_MORE_ITEMS) {
            break;
        }
        if (rc == ERROR_SUCCESS) {
            scan_registry_recursive(root, path + "\\" + subkey, suspicious, depth - 1, hits);
        }
    }

    RegCloseKey(key);
}

static void check_registry_devices()
{
    std::cout << "\n== Device / Registry VM Residue ==\n";
    static const std::vector<std::string> suspicious = {
        "qemu", "bochs", "kvm", "virtio", "red hat", "ven_1b36", "ven_1af4", "spice", "qxldod", "vioscsi",
        "viostor", "netkvm", "balloon", "vdagent", "vmware", "virtualbox", "xen"
    };

    const std::string present_devices = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-PnpDevice -PresentOnly | Where-Object { "
        "$_.InstanceId -match 'QEMU|BOCHS|KVM|VIRTIO|VEN_QEMU|VEN_REDHAT|VEN_1B36|VEN_1AF4|SPICE|QXL|VMWARE|VBOX|XEN' -or "
        "$_.FriendlyName -match 'QEMU|BOCHS|KVM|VIRTIO|Red Hat|SPICE|QXL|VMware|VirtualBox|Xen' "
        "} | Select-Object Status,Class,FriendlyName,InstanceId | Format-Table -AutoSize\" 2>NUL");
    if (!trim(present_devices).empty()) {
        std::cout << "Present suspicious PnP devices:\n" << present_devices << "\n";
        add_finding("FAIL", "Present VM devices", "Windows currently reports suspicious QEMU/KVM/VirtIO-style devices");
    } else {
        add_finding("PASS", "Present VM devices", "Get-PnpDevice -PresentOnly found no obvious VM devices");
    }

    int hits = 0;
    scan_registry_recursive(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System", suspicious, 4, hits);
    scan_registry_recursive(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Enum", suspicious, 5, hits);
    scan_registry_recursive(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Services", suspicious, 2, hits);

    if (hits == 0) {
        add_finding("PASS", "Device/driver VM residue", "no obvious QEMU/KVM/VirtIO/SPICE strings found in scanned registry areas");
    } else {
        std::ostringstream detail;
        detail << hits << " suspicious registry hits found; review whether any are stale drivers or active devices";
        add_finding("WARN", "Device/driver VM residue", detail.str());
    }
}

static void print_summary()
{
    std::cout << "\n== Summary ==\n";
    int pass = 0;
    int warn = 0;
    int fail = 0;
    for (const auto& f : findings) {
        if (f.status == "PASS") {
            ++pass;
        } else if (f.status == "WARN") {
            ++warn;
        } else if (f.status == "FAIL") {
            ++fail;
        }
    }

    std::cout << "PASS=" << pass << " WARN=" << warn << " FAIL=" << fail << "\n";
    if (fail == 0 && warn == 0) {
        std::cout << "Overall: clean across this guest-visible diagnostic set.\n";
    } else if (fail == 0) {
        std::cout << "Overall: no hard failures, but review warnings before treating the setup as ready.\n";
    } else {
        std::cout << "Overall: hard failures remain; fix those before relying on this VM profile.\n";
    }

    std::cout << "\nNote: this is a guest-visible VM compatibility diagnostic. It does not model private software policy checks.\n";
}

int main()
{
    std::cout << "Windows VFIO visibility diagnostic\n";
    std::cout << "Build: " << __DATE__ << " " << __TIME__ << "\n";

    check_cpuid();
    check_timing();
    check_processor_topology();
    check_cache_topology();
    check_smbios();
    check_acpi();
    check_tpm_secure_boot();
    check_windows_security_state();
    check_thermal_topology();
    check_memory_and_pagefile();
    check_physical_disks();
    check_pci_identity();
    check_network_macs();
    check_registry_devices();
    print_summary();

    return 0;
}
