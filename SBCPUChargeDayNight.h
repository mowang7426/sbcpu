#ifndef SBCPU_CHARGE_DAY_NIGHT_H
#define SBCPU_CHARGE_DAY_NIGHT_H
#include <stdbool.h>

/* Pure-C local-minute policy. Boundaries are [dayStart,nightStart): day. */
static inline bool sb_charge_day_night_times_valid(int dayStart, int nightStart) {
    return dayStart >= 0 && dayStart < 1440 && nightStart >= 0 && nightStart < 1440 && dayStart != nightStart;
}
static inline bool sb_charge_is_daytime(int minute, int dayStart, int nightStart) {
    if (!sb_charge_day_night_times_valid(dayStart, nightStart)) return true; /* fail safe: day */
    minute = (minute % 1440 + 1440) % 1440;
    if (dayStart < nightStart) return minute >= dayStart && minute < nightStart;
    return minute >= dayStart || minute < nightStart; /* crosses midnight */
}
static inline bool sb_charge_auto_effective_smart(int minute, int dayStart, int nightStart) {
    return sb_charge_is_daytime(minute, dayStart, nightStart);
}
static inline bool sb_charge_auto_effective_schedule(int minute, int dayStart, int nightStart) {
    return !sb_charge_is_daytime(minute, dayStart, nightStart);
}
#endif
