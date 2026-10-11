# 变更日志

本项目是**在既有系统上渐进改造**的结果，原则是「修改而非重建」。三轮改造全部记录在此，包括踩过的坑 —— 那是这份配置里最有价值的部分。

---

## 第一轮（2026-10-11）：让系统从「不可用」到「可用」

初始状态：入户 PP 维度完全缺失、寿命判定恒为正常、提醒漏报、有 2 个孤儿自动化。

| 编号 | 改动 | 文件 |
|---|---|---|
| M1A | 新增 `input_number.waterpurifier_start_pp_20inch`（单位 **m³**，step 0.001） | input_number.yaml |
| M1B | 新建 `sensor.waterpurifier_pp_20inch_used`（原文件整段缺失，非补缺）—— 按「抄码 − 基线」×1000 转 L | sensors.yaml |
| M1C | 入户 PP 重置写**抄码 m³**（而非制水量 L） | water_purifier_reset.yaml |
| M2 | `status_pp_20inch` 改回从 `change_time` 直接算天数 | sensors.yaml |
| M3 | 6 条提醒补 `to: ["警告","更换"]` + `for: "00:10:00"` 防抖；删冗余 `not 正常` condition | water_purifier_alert.yaml |
| M4 | 新增「滤芯到期巡检」自动化（HA 启动 + 每 6h），扫当前警告/更换项 | water_purifier_alert.yaml |
| M5 | 删除 2 个孤儿 UDF 提醒自动化（`unavailable`，yaml 无定义），保留活着的 `_3` | — |
| — | 设入户 PP 基线 `start_pp_20inch = 455.0`（2026-03-24 换芯抄码） | HA 状态 |

### 关键 bug：天数解析恒为 0

`status_pp_20inch` 原用 `int()` 解析 `"200天16小时"` 这类字符串 → **恒得 0** → 永远判「正常」。改为直接对 `change_time` 做时间戳差值。

### 关键 bug：提醒只认「更换」

原 `to: "更换"` 漏了「警告」档 —— 警告态从不提醒。且仅靠状态跳变触发，**已逾期但未跳变的项永远不提醒**。M3 补档 + M4 加巡检兜底。

---

## 第二轮（2026-10-11）：寿命阈值变量化 + RO 双信号

| 编号 | 改动 | 文件 |
|---|---|---|
| M6 | 不重置历史，维持 5 个净水端 `change_time = 2025-09-19`（用户确认真换过芯） | HA 状态 |
| M7-1 | 寿命阈值：`use_date_pp_10inch/udf/cto/t33 = 1095`（3 年）、`use_date_ro = 1460`（4 年）、`use_date_pp_20inch = 365`（1 年） | input_number.yaml |
| M7-2 | 4 个 helper 的 `max: 1000 → 2000`（撑住 1095，RO 原本已是 2000） | input_number.yaml |
| M7-3 | 6 个 `status_*` 判定从**写死常量**升级为**读 `use_date_*` 变量**（更换线=寿命，警告线=寿命//2） | sensors.yaml |
| M7-4 | `status_ro` 双信号：脱盐率 + 纯水 TDS 判定 | sensors.yaml |
| M7-5 | 入户 PP 警告线 = `use_date_pp_20inch − 35`（365 时 = 330，接近寿命才警告） | sensors.yaml |

### 踩坑：`initial` 超出 `max` → reload 静默失败

把寿命改成 1095 时，`max` 仍是 1000 → `input_number.reload` 返回 **400 失败**（`Initial value 1095.0 not in range 1.0-1000.0`）。当时用 `set_value` 把值临时顶成 1095，**实体配置里的 `initial` 其实一直是 365**。

危害：若此后重启 HA，`initial: 365` 会把 5 个净水端寿命打回 365 天 → 386 天用量**直接误报「更换」**。

这颗雷埋了整整一天才发现（从 MCP 审计日志里翻出来的）。教训见下。

### 用户决策记录

- 入户 PP 在 200 天时初显「警告」（365//2 = 182），用户接受逻辑但认为太早 → 警告线改 `寿命−35`。
- M6 明确**不重置**历史数据。

---

## 第三轮（2026-10-11）：ESP8266 累计归零根治 + 发布前 bug 修复

| 编号 | 改动 | 文件 |
|---|---|---|
| M8-1 | 新增 `input_number.esp_purified_accum`（HA 侧累计总量 L）+ `esp_purified_last`（上次原始读数 L） | input_number.yaml |
| M8-2 | 新建 `water_purifier_accum.yaml`：监听 raw 变化，`delta = (cur−prev) if cur>=prev else cur`，`accum += delta` | 新建 |
| M8-3 | 5 个 `*_used` 数据源从 raw → `esp_purified_accum` | sensors.yaml |
| M8-4 | 5 个净水端重置基线写值 → `esp_purified_accum` | water_purifier_reset.yaml |
| M8-5 | 报告卡片「纯水累计用量」→ `esp_purified_accum` | water_purifier_alert.yaml |
| M8-6 | 仪表盘「水量统计」卡片制水量 → `esp_purified_accum`（经 Lovelace API，非手改 `.storage`） | dashboard |
| M8-7 | 播种 `accum = last = 32.634`（当前原始值，无历史丢失） | HA 状态 |

### 同时修掉的历史 bug

1. **文案误替换**：第一轮改入户 PP 重置文案时用 `str.replace`，**误把 6 条重置通知的「起始制水量」全换成水务抄码** —— 5 个净水端重置通知显示错误。本轮修正：净水端恢复为「起始制水量(accum, L)」，仅入户 PP 保留「进水量(抄码 m³)」。
2. **消除 M7 遗留隐患**：文件 `initial` 已是正确常量 + `max: 2000` 自洽，重启只会得到正确阈值。

### 发布前新增修复（本项目归档时发现）

| Bug | 症状 | 修复 |
|---|---|---|
| **`status_pp_10inch` 漏改** | M7 改了 5 个 `status_*` 读变量，**漏了这一个**，仍是硬编码 1095/730 | 改为读 `use_date_pp_10inch` |
| **RO 阈值方向反了** | 原 `warn < 85 / repl < 90` —— 脱盐率 **87% 会跳过警告直接判更换**，而 87% 实际比 85% 更健康 | 改为 `warn < 90 / repl < 85`（脱盐率越低越严重） |

RO 修复后的判定矩阵已验证单调：98%→健康、87%→警告、80%→更换。

---

## 沉淀的教训

1. **`input_number` 设了 `initial` 就不做状态恢复**，每次重启强制回 `initial`。持久改值必须改 YAML。
2. **`initial` 不能超 `max`**，否则 reload 返回 400 失败且**表面看不出来**（实体保留旧配置）。成对改 `initial` + `max`，并确认 reload 成功。
3. **改 YAML 用 `str.replace` 前先数出现次数**（`s.count(pattern)`），确认命中范围 —— 一次误替换波及 6 处通知文案。
4. **状态判定优先读变量，别写死常量** —— 否则每次调阈值都要改模板。
5. **只靠状态跳变触发的提醒必然漏报**，必须有定时巡检兜底。
6. **数据源「会归零」时加单调层**，而不是修设备。
