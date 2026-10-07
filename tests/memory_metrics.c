#include "../SBCPUMemoryMetrics.h"
#include <assert.h>
#include <stdio.h>

static void test_page_size_and_non_overlap(void) {
    SBCPUMemoryPageCounters c = { .free_count = 100, .inactive_count = 200,
        .speculative_count = 30, .purgeable_count = 999 };
    SBCPUMemoryMetrics m;
    assert(SBCPUMemoryMetricsCompute(&c, 4096, 16ULL * 1024 * 1024,
                                     16ULL * 1024 * 1024, &m));
    /* HOST_VM_INFO64.free_count includes speculative pages; do not double-count. */
    assert(m.available_bytes == 300ULL * 4096);
    assert(m.total_bytes == 16ULL * 1024 * 1024);
    assert(m.page_size == 4096);
    assert(SBCPUMemoryMetricsCompute(&c, 16384, 16ULL * 1024 * 1024,
                                     16ULL * 1024 * 1024, &m));
    assert(m.available_bytes == 300ULL * 16384);
}

static void test_cap_and_saturation(void) {
    SBCPUMemoryPageCounters c = { UINT64_MAX, UINT64_MAX, UINT64_MAX, 0 };
    SBCPUMemoryMetrics m;
    assert(SBCPUMemoryMetricsCompute(&c, 16384, 1000, 1000, &m));
    assert(m.available_bytes == 1000);
    assert(SBCPUMemoryMetricsEffectiveTotal(9000, 8000) == 8000);
    assert(SBCPUMemoryMetricsEffectiveTotal(0, 8000) == 8000);
}

static void test_failure_clears_output(void) {
    SBCPUMemoryMetrics m = { true, 123, 456, 789 };
    SBCPUMemoryPageCounters c = { 1, 2, 3, 4 };
    assert(!SBCPUMemoryMetricsCompute(&c, 0, 1000, 1000, &m));
    assert(!m.valid && m.available_bytes == 0 && m.total_bytes == 0 && m.page_size == 0);
    m.valid = true; m.available_bytes = 123; m.total_bytes = 456; m.page_size = 789;
    assert(!SBCPUMemoryMetricsCompute(NULL, 4096, 1000, 1000, &m));
    assert(!m.valid && m.available_bytes == 0 && m.total_bytes == 0 && m.page_size == 0);
    assert(!SBCPUMemoryMetricsCompute(&c, 4096, 1000, 0, &m));
}

int main(void) {
    test_page_size_and_non_overlap();
    test_cap_and_saturation();
    test_failure_clears_output();
    puts("memory metrics regression tests passed");
    return 0;
}
