# 架构与数据流

## 总览

```
┌─────────────────┐
│  ESP8266 / TDS  │  原水TDS · 纯水TDS · 累计进水 · 累计制水(raw, 断电归零)
└────────┬────────┘
         │
┌────────▼─────────────────────────────────────────────────┐
│ 第 1 层：HA 侧单调累计器                                  │
│  automation.waterpurifier_espchun_shui_lei_ji_hace         │
│  delta = (cur - prev) if cur >= prev else cur   # 归零容忍 │
│  input_number.esp_purified_accum += delta       # 只增不减 │
└────────┬─────────────────────────────────────────────────┘
         │
┌────────▼─────────────────────────────────────────────────┐
│ 第 2 层：已用量 sensor.waterpurifier_<滤芯>_used           │
│  = accum - waterpurifier_start_<滤芯>          (L)         │
│  入户PP 例外 = (水务抄码 - start_pp_20inch) × 1000         │
└────────┬─────────────────────────────────────────────────┘
         │
┌────────▼─────────────────────────────────────────────────┐
│ 第 3 层：状态判定 sensor.status_<滤芯>                     │
│  四态： 正常 / 警告 / 更换 / 未设置                        │
│  阈值来自 input_number.use_date_<滤芯>（变量，非硬编码）   │
│  RO 额外走「脱盐率 + 纯水TDS」双信号                       │
└────────┬─────────────────────────────────────────────────┘
         │
┌────────▼─────────────────────────────────────────────────┐
│ 第 4 层：提醒 + 仪表盘                                     │
│  notify.gotify（10min 防抖 + 6h 巡检兜底）                 │
└───────────────────────────────────────────────────────────┘
```

---

## 实体清单

### 输入类（持久化状态）

| 实体模式 | 类型 | 用途 | 有无 `initial` |
|---|---|---|---|
| `input_number.waterpurifier_start_<滤芯>` | input_number | 换芯时的起始基线（L） | 无 → 状态恢复 |
| `input_number.waterpurifier_start_pp_20inch` | input_number | 入户PP起始抄码（**m³**） | 无 |
| `input_number.use_date_<滤芯>` | input_number | **寿命阈值（天）** | **有** → 见下方警告 |
| `input_datetime.waterpurifier_change_time_<滤芯>` | input_datetime | 上次更换时间 | — |
| `input_button.reset_waterpurifier_<滤芯>` | input_button | 一键换芯重置 | — |
| `input_text.history_<滤芯>` | input_text | 维护历史（追加日期串） | — |
| `input_number.esp_purified_accum` | input_number | **HA 侧单调累计总量（L）** | 无 → 状态恢复 |
| `input_number.esp_purified_last` | input_number | 上次原始读数（L） | 无 → 状态恢复 |

### 派生 sensor（template）

| sensor | 说明 |
|---|---|
| `sensor.ro_salt_rejection` | 脱盐率 = (原水TDS − 纯水TDS) / 原水TDS × 100 % |
| `sensor.waterpurifier_<滤芯>_used` | 已用制水量 L（`esp_purified_accum` − 基线） |
| `sensor.waterpurifier_pp_20inch_used` | 入户PP已用进水量 L（抄码差 × 1000） |
| `sensor.days_used_<滤芯>` | 已用天数（自 `change_time` 计算） |
| `sensor.time_remaining_<滤芯>` | 剩余天数 + 文案 |
| `sensor.status_<滤芯>` | 四态状态 |

---

## 单调累计器详解

### 问题

ESP8266 没有持久化累计，**断电/重启后 `total_purified` 归零重算**。后果：

- `*_used` 制水量**回退**（例如 32 L → 0.5 L）
- 换芯基线相对失真（基线是 32 L 时记的，读数变 0.5 L 后算出负值）
- 依赖制水量的判定（PP/UDF/CTO/T33 的 `used_water >= 1000/1200`）全部失效

> 定性：这是设备能力限制（无持久化），不是固件 bug。**不动设备，在 HA 侧解决。**

### 解法

自动化 [`water_purifier_accum.yaml`](../config/automations/water_purifier/water_purifier_accum.yaml)：

```yaml
trigger:
  - platform: state
    entity_id: sensor.tds_esp8266_total_purified_water_usage
action:
  - variables:
      cur:   "{{ trigger.to_state.state | float(0) }}"
      prev:  "{{ states('input_number.esp_purified_last') | float(0) }}"
      accum: "{{ states('input_number.esp_purified_accum') | float(0) }}"
      delta: "{{ (cur - prev) if cur >= prev else cur }}"
  - service: input_number.set_value   # accum += delta
  - service: input_number.set_value   # last = cur
```

**关键一行**：`delta = (cur - prev) if cur >= prev else cur`

| 场景 | cur | prev | delta | accum |
|---|---|---|---|---|
| 正常制水 | 33.0 | 32.634 | 0.366 | +0.366（累积） |
| **断电归零** | 0.5 | 32.634 | **0.5**（不是 −32.134） | +0.5（继续爬升） |
| 设备离线恢复 | unknown | — | 被 condition 过滤 | 不变 |

- `mode: queued` + `max: 10`：高频制水事件串行处理，不丢更新
- `accum` / `last` **都不设 `initial`** → HA 状态恢复机制保证跨重启不丢

### 初始化

首次部署时手工设一次（`accum` = `last` = 当前原始读数）：

```yaml
service: input_number.set_value
data: { entity_id: input_number.esp_purified_accum, value: 32.634 }
```

> 若设备已经历过归零、历史数据已丢，只能从当前点起累计 —— 换芯基线需同步重置一次。

---

## 状态判定逻辑

### 通用滤芯（PP/UDF/CTO/T33）

```jinja
更换 = used_water >= 1200  或  days >= use_date_<滤芯>
警告 = used_water >= 1000  或  days >= use_date_<滤芯> // 2
```

用水量阈值（1000/1200 L）目前仍硬编码在 `sensors.yaml`，寿命天数已变量化。

### RO 膜（双信号）

```jinja
warn = 脱盐率 < 90%  或  纯水TDS > 15 ppm
repl = 脱盐率 < 85%  或  纯水TDS > 25 ppm
# 两项都健康 → 天数兜底（警告线 = use_date_ro // 2）
```

**方向性**：脱盐率**越低越差**，TDS **越高越差**。判定矩阵（已验证单调）：

| 脱盐率 | 纯水TDS | 结果 |
|---|---|---|
| 98% | 2 ppm | 健康 → 走天数兜底 |
| 98% | 20 ppm | 警告 |
| 98% | 30 ppm | 更换 |
| 92% | 2 ppm | 健康 → 走天数兜底 |
| 87% | 2 ppm | **警告** |
| 87% | 30 ppm | 更换 |
| 80% | 2 ppm | **更换** |

> ⚠️ 历史 bug（已修）：早期版本写成 `warn < 85 / repl < 90`，方向反了 —— 脱盐率 87% 会**跳过警告直接判更换**，而 87% 实际比 85% 更健康。见 CHANGELOG。

### 入户 20 寸 PP 棉

装在入户总水管（全屋进水第一道），**进水量取水务账单抄码**，不是净水机内部流量计：

```jinja
used_L = (sensor.0021030105848_ben_ci_chao_ma − start_pp_20inch) × 1000
更换 = days >= use_date_pp_20inch              # 365
警告 = days >= use_date_pp_20inch − 35         # 330（接近寿命才提醒）
```

水务账单是**离散两月一跳**（逢单月抄表报前两个月），故用「累计抄码」做基线减法，而非「本月用水量」。

---

## 提醒机制

`water_purifier_alert.yaml` 里有两类自动化：

1. **到期提醒**（6 条，每滤芯一条）
   - trigger：`status_*` → `警告` / `更换`
   - `for: 00:10:00` 防抖 —— 过滤 HA 重启/重载时的瞬时抖动
2. **滤芯到期巡检**（1 条兜底）
   - trigger：HA 启动 + `time_pattern` 每 6 小时
   - 扫描当前所有 `警告`/`更换` 项并推送

> 兜底是必需的：仅靠状态跳变触发，**已逾期但状态未跳变**的项会永远不提醒（尤其 HA 重启后状态未变化）。

通知走 Gotify（`notify.gotify`），Markdown 表格格式。换渠道改 `notify.gotify` 即可。

---

## ⚠️ input_number 的两个坑

### 1. 设了 `initial` 就不做状态恢复

`input_number` 一旦配置 `initial`，**每次 HA 重启强制回到 `initial`**，不做上次状态恢复。

- ✅ `esp_purified_accum` / `last` / `waterpurifier_start_*`：不设 `initial` → 状态恢复，安全
- ⚠️ `use_date_*`：设了 `initial`（这是刻意的，作为可调常量）→ **想持久改寿命必须改 YAML 的 `initial`**，仅在 UI 拖滑块会被下次重启覆盖

### 2. `initial` 超出 `max` 会让 reload 静默失败

`input_number.reload` 遇到 `initial > max` 会返回 400 失败，此时**实体仍保留旧配置** —— 表面看"值没变"，实际是重载失败了。

排查方式：看 reload 的返回/日志，不要只看实体状态。

> 历史事故：把寿命从 365 改成 1095 时，`max` 还是 1000 → reload 失败 → 用 `set_value` 临时顶成 1095。若此后重启，`initial: 365` 会把寿命打回 365 天，386 天用量直接**误报更换**。现已把涉及 helper 的 `max` 提到 2000。

**正确做法**：`initial` 与 `max` 成对改，同一次写入后 reload，并确认 reload 返回成功。

---

## 部署与重载顺序

改配置后按此顺序重载（**无需重启 HA**）：

1. `input_number.reload` —— 先建/更新 helper
2. `automation.reload`
3. （如需初始化）`input_number.set_value` 播种累计器
4. `template.reload` —— 最后重载模板

顺序不能乱：模板依赖 helper 与自动化产物，先重载模板会读到不存在的实体。

改完建议跑 `ha core check`（或 `ha_get_system_health(include="config_check")`）确认配置合法。
