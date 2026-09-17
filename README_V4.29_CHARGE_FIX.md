# SBCPU V4.29 Charge Fix

## 本版针对 V4.28 真机现象

### 1. SMC 写入后强制回读确认
- CH0C/CH0I 写入后立即读取确认 bit0。
- 写入失败或被系统/OBC立即覆盖时，不再把软件状态伪装成“已阻止”。

### 2. 修正浮窗电流的语义
AppleSmartBattery 的 `Amperage` 是电池侧瞬时电流，手机自身耗电时即使已经停止充电，
也可能看到几十 mA 的非零读数。

因此：
- Charge Engine 已确认 `CH0C=1` 时，浮窗“电流”显示为 `0 mA`（表示充电电流为 0）。
- 未停充时，只把正向电流作为“充电电流”显示。
- 电池详情仍可继续查看原始电池电流数据。

### 3. 保留 V4.28 修复
- AppleSMC 168-byte ABI
- CH0C/CH0I 恢复路径
- 互斥锁
- powerd 不再接管 ChargeInhibit/ChargeLimit
- 拔插电重新同步
- OBC 覆盖默认关闭
