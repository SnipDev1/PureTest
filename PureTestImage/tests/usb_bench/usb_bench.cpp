// usb_bench.cpp - USB Storage Read/Write Throughput & Latency Benchmark
//
// Tests sustained sequential write, sequential read, and random 4K read performance
// on the USB flash drive (DATADISK). Bypasses OS page caching using fsync and
// posix_fadvise(POSIX_FADV_DONTNEED) to measure actual USB bus / NAND flash speed.

#include <iostream>
#include <vector>
#include <string>
#include <chrono>
#include <random>
#include <iomanip>
#include <cstring>
#include <cstdlib>
#include <cerrno>

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>

namespace {

using clock_type = std::chrono::steady_clock;

double to_seconds(clock_type::time_point start, clock_type::time_point end) {
    return std::chrono::duration<double>(end - start).count();
}

std::string get_target_dir() {
    struct stat st{};
    // Check if /data (DATADISK) exists and is a directory
    if (stat("/data", &st) == 0 && S_ISDIR(st.st_mode)) {
        return "/data";
    }
    // Fallback if not mounted
    return "/tmp";
}

} // namespace

int main(int argc, char* argv[]) {
    std::string target_dir = get_target_dir();
    if (argc > 1 && argv[1][0] != '\0') {
        target_dir = argv[1];
    }

    std::string test_file = target_dir + "/.puretest_usb_bench.tmp";

    std::cout << "======================================================================\n";
    std::cout << "                   USB STORAGE BENCHMARK\n";
    std::cout << "======================================================================\n";
    std::cout << "Target Directory : " << target_dir << "\n";

    // Check available space
    struct statvfs svfs{};
    if (statvfs(target_dir.c_str(), &svfs) == 0) {
        unsigned long long free_bytes = svfs.f_bavail * svfs.f_frsize;
        std::cout << "Free Space       : " << (free_bytes / (1024 * 1024)) << " MiB\n";
    }

    const size_t CHUNK_SIZE = 1024 * 1024; // 1 MiB chunk
    const size_t TOTAL_CHUNKS = 64;        // 64 MiB total
    const size_t TOTAL_BYTES = TOTAL_CHUNKS * CHUNK_SIZE;

    std::cout << "Benchmark Size   : " << (TOTAL_BYTES / (1024 * 1024)) << " MiB ("
              << TOTAL_CHUNKS << " x 1 MiB blocks)\n";
    std::cout << "----------------------------------------------------------------------\n";

    // Prepare buffer with pseudo-random data to prevent hardware compression artifacts
    std::vector<char> buffer(CHUNK_SIZE);
    for (size_t i = 0; i < CHUNK_SIZE; ++i) {
        buffer[i] = static_cast<char>((i * 73 + 17) & 0xFF);
    }

    // -------------------------------------------------------------------------
    // 1. Sequential Write Test
    // -------------------------------------------------------------------------
    std::cout << "[1] Testing Sequential Write (with fsync to flash)... " << std::flush;

    int fd = open(test_file.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666);
    if (fd < 0) {
        std::cerr << "\nERROR: Failed to open test file for writing: " 
                  << std::strerror(errno) << "\n";
        return 1;
    }

    auto t_write_start = clock_type::now();
    for (size_t i = 0; i < TOTAL_CHUNKS; ++i) {
        ssize_t written = write(fd, buffer.data(), CHUNK_SIZE);
        if (written != static_cast<ssize_t>(CHUNK_SIZE)) {
            std::cerr << "\nERROR: Incomplete write: " << std::strerror(errno) << "\n";
            close(fd);
            unlink(test_file.c_str());
            return 1;
        }
    }
    // Flush dirty pages to physical media before stopping write timer
    if (fsync(fd) != 0) {
        std::cerr << "\nWARNING: fsync failed: " << std::strerror(errno) << "\n";
    }
    auto t_write_end = clock_type::now();
    close(fd);

    double write_sec = to_seconds(t_write_start, t_write_end);
    double write_speed = (static_cast<double>(TOTAL_BYTES) / (1024.0 * 1024.0)) / write_sec;
    std::cout << "DONE (" << std::fixed << std::setprecision(2) << write_sec << " s)\n";

    // -------------------------------------------------------------------------
    // 2. Sequential Read Test
    // -------------------------------------------------------------------------
    std::cout << "[2] Testing Sequential Read (page cache invalidated)... " << std::flush;

    fd = open(test_file.c_str(), O_RDONLY);
    if (fd < 0) {
        std::cerr << "\nERROR: Failed to open test file for reading: " 
                  << std::strerror(errno) << "\n";
        unlink(test_file.c_str());
        return 1;
    }

    // Tell kernel to evict pages from cache so we measure actual USB read
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

    std::vector<char> read_buf(CHUNK_SIZE);
    auto t_read_start = clock_type::now();
    for (size_t i = 0; i < TOTAL_CHUNKS; ++i) {
        ssize_t bytes_read = read(fd, read_buf.data(), CHUNK_SIZE);
        if (bytes_read != static_cast<ssize_t>(CHUNK_SIZE)) {
            std::cerr << "\nERROR: Incomplete read: " << std::strerror(errno) << "\n";
            close(fd);
            unlink(test_file.c_str());
            return 1;
        }
    }
    auto t_read_end = clock_type::now();

    double read_sec = to_seconds(t_read_start, t_read_end);
    double read_speed = (static_cast<double>(TOTAL_BYTES) / (1024.0 * 1024.0)) / read_sec;
    std::cout << "DONE (" << std::fixed << std::setprecision(2) << read_sec << " s)\n";

    // -------------------------------------------------------------------------
    // 3. Random 4K Read Latency & IOPS
    // -------------------------------------------------------------------------
    std::cout << "[3] Testing Random 4K Reads (500 samples)... " << std::flush;

    const size_t BLOCK_4K = 4096;
    const size_t NUM_RANDOM_OPS = 500;
    const size_t MAX_OFFSET = (TOTAL_BYTES - BLOCK_4K);
    char buf_4k[BLOCK_4K];

    std::mt19937 rng(42);
    std::uniform_int_distribution<size_t> dist(0, MAX_OFFSET / BLOCK_4K);

    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

    auto t_rand_start = clock_type::now();
    for (size_t i = 0; i < NUM_RANDOM_OPS; ++i) {
        off_t offset = static_cast<off_t>(dist(rng) * BLOCK_4K);
        ssize_t r = pread(fd, buf_4k, BLOCK_4K, offset);
        if (r != static_cast<ssize_t>(BLOCK_4K)) {
            break;
        }
    }
    auto t_rand_end = clock_type::now();
    close(fd);

    // Clean up temporary benchmark file
    unlink(test_file.c_str());
    sync();

    double rand_sec = to_seconds(t_rand_start, t_rand_end);
    double iops = static_cast<double>(NUM_RANDOM_OPS) / rand_sec;
    double avg_latency_ms = (rand_sec / static_cast<double>(NUM_RANDOM_OPS)) * 1000.0;
    std::cout << "DONE (" << std::fixed << std::setprecision(2) << rand_sec << " s)\n";

    // -------------------------------------------------------------------------
    // Results Summary
    // -------------------------------------------------------------------------
    std::cout << "======================================================================\n";
    std::cout << "                   BENCHMARK RESULTS\n";
    std::cout << "======================================================================\n";
    std::cout << "  Sequential Write : " << std::setw(8) << std::fixed << std::setprecision(2) 
              << write_speed << " MiB/s\n";
    std::cout << "  Sequential Read  : " << std::setw(8) << std::fixed << std::setprecision(2) 
              << read_speed << " MiB/s\n";
    std::cout << "  Random 4K Read   : " << std::setw(8) << std::fixed << std::setprecision(1) 
              << iops << " IOPS  (" << std::setprecision(2) << avg_latency_ms << " ms avg latency)\n";
    std::cout << "----------------------------------------------------------------------\n";

    // Quick sanity assessment
    std::cout << "Speed Classification:\n";
    if (read_speed > 100.0) {
        std::cout << "  -> High-performance USB 3.0/3.1 flash drive or SSD (Read > 100 MiB/s)\n";
    } else if (read_speed > 35.0) {
        std::cout << "  -> Standard USB 3.0 / High-end USB 2.0 (Read: 35-100 MiB/s)\n";
    } else {
        std::cout << "  -> USB 2.0 speed tier or slow flash controller (Read < 35 MiB/s)\n";
    }
    std::cout << "======================================================================\n";

    return 0;
}
