#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <string>
#include <vector>

#include <intrin.h>
#include <windows.h>

#pragma intrinsic(__rdtsc)
#pragma comment(lib, "Advapi32.lib")

struct Finding {
    std::string status;
    std::string name;
    std::string detail;
};

static std::vector<Finding> findings;

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

static void check_timing()
{
    std::cout << "\n== RDTSC / VM-exit Timing ==\n";

    constexpr int iterations = 20000;
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
        int cpu_info[4];

        _mm_lfence();
        unsigned long long start = __rdtsc();
        _mm_lfence();
        unsigned long long end = __rdtsc();
        _mm_lfence();
        rdtsc_delta.push_back(end - start);

        _mm_lfence();
        start = __rdtsc();
        __cpuid(cpu_info, 0);
        _mm_lfence();
        end = __rdtsc();
        _mm_lfence();
        cpuid0_delta.push_back(end - start);

        _mm_lfence();
        start = __rdtsc();
        __cpuid(cpu_info, 1);
        _mm_lfence();
        end = __rdtsc();
        _mm_lfence();
        cpuid1_delta.push_back(end - start);

        _mm_lfence();
        start = __rdtsc();
        __cpuid(cpu_info, 0x40000000);
        _mm_lfence();
        end = __rdtsc();
        _mm_lfence();
        cpuid_hv_delta.push_back(end - start);
    }

    auto print_stats = [](const std::string& label, const std::vector<unsigned long long>& values) {
        auto minmax = std::minmax_element(values.begin(), values.end());
        auto sum = std::accumulate(values.begin(), values.end(), 0ull);
        std::cout << label
                  << " median=" << median(values)
                  << " p95=" << percentile(values, 0.95)
                  << " p99=" << percentile(values, 0.99)
                  << " avg=" << (sum / values.size())
                  << " min/max=" << *minmax.first << "/" << *minmax.second << "\n";
    };

    print_stats("RDTSC->RDTSC", rdtsc_delta);
    print_stats("RDTSC+CPUID(0)", cpuid0_delta);
    print_stats("RDTSC+CPUID(1)", cpuid1_delta);
    print_stats("RDTSC+CPUID(0x40000000)", cpuid_hv_delta);

    const auto cpuid0_med = median(cpuid0_delta);
    const auto cpuid0_p95 = percentile(cpuid0_delta, 0.95);
    const auto cpuid0_p99 = percentile(cpuid0_delta, 0.99);
    if (cpuid0_med < 500 && cpuid0_p95 < 800) {
        add_finding("PASS", "CPUID timing", "median and p95 are in the intended low-latency range");
    } else if (cpuid0_med < 800 && cpuid0_p95 < 1500) {
        add_finding("WARN", "CPUID timing", "better than default VM behavior, but still visibly elevated");
    } else {
        add_finding("FAIL", "CPUID timing", "latency still looks VM-exit-like");
    }

    if (cpuid0_p99 > 5000) {
        add_finding("WARN", "Timing spikes", "CPUID p99 has large outliers; host scheduling/noise may still be visible");
    }

    std::ostringstream detail;
    detail << "CPUID(0) median/p95/p99 = " << cpuid0_med << "/" << cpuid0_p95 << "/" << cpuid0_p99 << " cycles";
    add_finding("INFO", "Timing detail", detail.str());
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

    if (l3_count > 0) {
        std::ostringstream cache_detail;
        cache_detail << l3_count << " L3 cache object(s), total visible L3=" << l3_total / (1024 * 1024) << " MiB";
        add_finding("PASS", "L3 cache topology", cache_detail.str());
    } else {
        add_finding("FAIL", "L3 cache topology", "no L3 cache objects visible to Windows");
    }

    if (l2_count > 0) {
        add_finding("PASS", "L2 cache topology", std::to_string(l2_count) + " L2 cache object(s) visible");
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
            print_smbios_field("Memory Manufacturer", smbios_string(strings, data[0x17]), suspicious_count, weak_count);
            print_smbios_field("Memory Serial", smbios_string(strings, data[0x18]), suspicious_count, weak_count);
            print_smbios_field("Memory Part", smbios_string(strings, data[0x1A]), suspicious_count, weak_count);
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

    const std::string tpm = run_command("powershell -NoProfile -ExecutionPolicy Bypass -Command \"Get-Tpm | Format-List TpmPresent,TpmReady,TpmEnabled,TpmActivated,TpmOwned,ManufacturerIdTxt,ManufacturerVersionFull20\" 2>$null");
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

static void check_thermal_topology()
{
    std::cout << "\n== ACPI Thermal Topology ==\n";
    const std::string thermal = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature | "
        "Select-Object InstanceName,CurrentTemperature,CriticalTripPoint | Format-Table -AutoSize\" 2>$null");

    if (!trim(thermal).empty()) {
        std::cout << thermal << "\n";
        add_finding("PASS", "ACPI thermal zones", "Windows WMI reports at least one ACPI thermal zone");
    } else {
        add_finding("WARN", "ACPI thermal zones", "no ACPI thermal zones reported through WMI");
    }
}

static void check_physical_disks()
{
    std::cout << "\n== Physical Disks ==\n";
    const std::string disks = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-PhysicalDisk | Select-Object FriendlyName, SerialNumber | Format-Table -AutoSize\" 2>$null");

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

static void check_network_macs()
{
    std::cout << "\n== Network Adapters ==\n";
    const std::string macs = run_command(
        "powershell -NoProfile -ExecutionPolicy Bypass -Command "
        "\"Get-NetAdapter | Select-Object Name, MacAddress | Format-Table -AutoSize\" 2>$null");

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
        add_finding("WARN", "MAC Address", "Found Hyper-V OUI (00:15:5D); verify this isn't a virtual switch leak");
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
        "} | Select-Object Status,Class,FriendlyName,InstanceId | Format-Table -AutoSize\" 2>$null");
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
        std::cout << "Overall: hard failures remain; fix those before drawing conclusions from game/client behavior.\n";
    }

    std::cout << "\nNote: this is a guest-visible VM compatibility/masking diagnostic. It does not model private anti-cheat logic.\n";
}

int main()
{
    std::cout << "Windows VFIO visibility diagnostic\n";
    std::cout << "Build: " << __DATE__ << " " << __TIME__ << "\n";

    check_cpuid();
    check_timing();
    check_cache_topology();
    check_smbios();
    check_acpi();
    check_tpm_secure_boot();
    check_thermal_topology();
    check_physical_disks();
    check_network_macs();
    check_registry_devices();
    print_summary();

    return 0;
}