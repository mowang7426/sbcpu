#ifndef SBCPU_MEMORY_METRICS_H
#define SBCPU_MEMORY_METRICS_H

/*
 * Small, Foundation-free memory accounting helper for the SBCPU UI.
 *
 * available_bytes estimates free plus reclaimable inactive pages.
 * HOST_VM_INFO64.free_count ALREADY includes speculative_count in XNU
 * (osfmk/kern/host.c), so adding speculative_count again double-counts it.
 * Purgeable pages can overlap other queues, so are not added separately.
 * Reclaimable pages are not guaranteed immediately allocatable by an app.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t free_count;
    uint64_t inactive_count;
    uint64_t speculative_count; /* informational; ALREADY included in free_count */
    uint64_t purgeable_count; /* informational; can overlap other queues */
} SBCPUMemoryPageCounters;

typedef struct {
    bool valid;
    uint64_t available_bytes;
    uint64_t total_bytes;
    uint64_t page_size;
} SBCPUMemoryMetrics;

/* Return the non-zero, physical-memory-capped display capacity. */
static inline uint64_t SBCPUMemoryMetricsEffectiveTotal(uint64_t kernel_total,
                                                          uint64_t physical_total)
{
    if (physical_total == 0U) {
        return 0U;
    }
    if (kernel_total == 0U || kernel_total > physical_total) {
        return physical_total;
    }
    return kernel_total;
}

static inline uint64_t SBCPUMemoryMetricsSaturatingAdd(uint64_t a, uint64_t b)
{
    return (UINT64_MAX - a < b) ? UINT64_MAX : a + b;
}

/*
 * page_size is obtained from host_page_size(), never assumed to be 4096.
 * physical_total must be NSProcessInfo.physicalMemory.  A false return means
 * that the caller must clear the UI rather than retain its previous value.
 */
static inline bool SBCPUMemoryMetricsCompute(const SBCPUMemoryPageCounters *counters,
                                              uint64_t page_size,
                                              uint64_t kernel_total,
                                              uint64_t physical_total,
                                              SBCPUMemoryMetrics *out)
{
    if (out == NULL) {
        return false;
    }
    out->valid = false;
    out->available_bytes = 0U;
    out->total_bytes = 0U;
    out->page_size = 0U;
    if (counters == NULL || page_size == 0U || physical_total == 0U) {
        return false;
    }

    uint64_t total = SBCPUMemoryMetricsEffectiveTotal(kernel_total, physical_total);
    if (total == 0U) {
        return false;
    }

    /* XNU free_count includes speculative pages. Never add them twice.
     * Purgeable is also not an independent queue to add here. */
    uint64_t pages = SBCPUMemoryMetricsSaturatingAdd(counters->free_count,
                                                      counters->inactive_count);
    uint64_t available;
    if (pages > UINT64_MAX / page_size) {
        available = UINT64_MAX;
    } else {
        available = pages * page_size;
    }
    if (available > total) {
        available = total;
    }
    out->valid = true;
    out->available_bytes = available;
    out->total_bytes = total;
    out->page_size = page_size;
    return true;
}

#ifdef __cplusplus
}
#endif
#endif /* SBCPU_MEMORY_METRICS_H */
