#ifndef SBCPU_WRITER_STATUS_H
#define SBCPU_WRITER_STATUS_H
#include <stdint.h>
#include <notify.h>
static const char *SBCTWriterName = "com.yourname.sbcpufloating/thermal.telemetry.writer.v1";
enum { SBCTHello = 1, SBCTSuccess, SBCTSerialize, SBCTOversize, SBCTOpen, SBCTOwner, SBCTMode, SBCTWrite, SBCTClose, SBCTRename };
// protocol/schema 1, status 8 bits, errno 16 bits, attempt sequence 32 bits.
// No paths or PID. Retained notify state is not proof of current process identity.
static inline uint64_t SBCTWriterEncode(unsigned code, int error, uint64_t sequence) {
    return (UINT64_C(1)<<56) | ((uint64_t)(code & 255)<<48) | ((uint64_t)(error & 65535)<<32) | (sequence & UINT64_C(0xffffffff));
}
static inline void SBCTWriterPublish(unsigned code, int error, uint64_t sequence) {
    int token;
    if (notify_register_check(SBCTWriterName, &token) != NOTIFY_STATUS_OK) return;
    if (notify_set_state(token, SBCTWriterEncode(code, error, sequence)) == NOTIFY_STATUS_OK) notify_post(SBCTWriterName);
    notify_cancel(token);
}
static inline NSString *SBCTWriterReport(uint64_t state, BOOL missing) {
    if ((state >> 56) != 1) return @"未观察到记录器握手（protocol/schema 1）：可能旧核心、未加载或通知状态空间不同；旧心跳不能证明新记录器已运行。";
    unsigned code = (unsigned)((state >> 48) & 255), error = (unsigned)((state >> 32) & 65535);
    NSArray *names = @[@"未知", @"记录器构造握手，尚无写入结果", @"写入成功", @"序列化失败", @"快照超限", @"临时文件打开失败", @"设置属主失败", @"设置权限失败", @"写入失败", @"关闭失败", @"原子替换失败"];
    NSString *label = code < names.count ? names[code] : @"未知状态码";
    return [NSString stringWithFormat:@"protocol/schema=1；%@；code=%u errno=%u sequence=%llu。%@通知为保留状态、无 PID；只能有限关联，不证明当前进程或此快照对应。", label, code, error, (unsigned long long)(state & UINT64_C(0xffffffff)), code == SBCTSuccess && missing ? @"写端报告成功但读端文件缺失：可能状态陈旧或路径视图不同。" : @""];
}
#endif
