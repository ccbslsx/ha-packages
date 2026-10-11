# WaterPurifier HA

[Home Assistant](https://www.home-assistant.io/) 净水机全生命周期管理方案 —— YAML 配置包（非自定义集成）。

6 个滤芯维度（PP棉 / UDF活性炭 / CTO压缩炭 / RO膜 / T33后置炭 / 入户20寸PP棉）的**用量计算、寿命判定、换芯重置、到期提醒、仪表盘**一体化，无需写任何 Python 代码。

---

## 为什么做这个

家用 RO 净水机常见的 HA 集成只给你三个数：原水 TDS、纯水 TDS、累计流量。但真正要管的是**滤芯什么时候该换**，这需要把这些数据组织起来。

本方案解决四个真实痛点：

| 痛点 | 本方案的解法 |
|---|---|
| 滤芯寿命是黑盒，靠感觉换 | 天数 + 用水量的双维度判定，`use_date_*` 可调寿命常量 |
| RO 膜衰减只看天数不准 | **双信号判定**：脱盐率 `<85%警告/<90%更换` **或** 纯水 TDS `>15警告/>25更换`，任一触发即预警 |
| 换芯后不知何时又到期 | 一键 `input_button` 重置基线 + 自动记录维护历史 |
| ESP8266 断电后累计流量归零 | **HA 侧单调累计器**（`esp_purified_accum`），只增不减，彻底根治 |

---

## 特性

- **6 个滤芯维度**，每维度：已用量 / 已用天数 / 剩余时间 / 四态状态（正常·警告·更换·未设置）
- **寿命可调**：`use_date_*` 常量驱动，改一处即全局生效（`status_*` 模板读变量，不写死）
- **RO 双信号判定**：脱盐率 + 纯水 TDS 双保险，任一异常即预警
- **入户 PP 用真实进水量**：接水务账单抄码（m³），而非净水机内部流量计
- **单调累计器**：设备断电归零不再导致用量回退、换芯基线失真
- **到期提醒**：Gotify 推送，含 10 分钟防抖 + 每 6 小时巡检兜底（避免重启漏报）
- **维护历史**：每次重置自动追加日期到 `input_text.history_*`

---

## 目录结构

```
waterpurifier-ha/
├── config/                          # 拷到 HA 的 /config 下
│   ├── configuration.example.yaml   # ⚠️ 脱敏示例，需合并进你的 configuration.yaml
│   ├── water_purifier/              # 实体定义（6 个 yaml）
│   │   ├── input_number.yaml        # 起始基线 + 寿命阈值 + 累计器
│   │   ├── input_button.yaml        # 换芯重置按钮
│   │   ├── input_datetime.yaml      # 上次更换时间
│   │   ├── input_text.yaml          # 维护历史
│   │   ├── sensors.yaml             # 派生传感器（核心逻辑）
│   │   └── lovelace_card.yaml       # 监控卡片片段（可选）
│   └── automations/water_purifier/  # 自动化
│       ├── water_purifier_reset.yaml  # 换芯重置（6 条）
│       ├── water_purifier_alert.yaml  # 到期提醒 + 巡检兜底
│       └── water_purifier_accum.yaml  # ESP 累计器（单调化）
├── dashboard/
│   └── lovelace_waterpurifier_view.json   # 完整仪表盘视图（可直接导入）
├── docs/
│   ├── ARCHITECTURE.md              # 架构与数据流
│   └── CHANGELOG.md                 # 三轮改造记录
└── scripts/
    └── deploy.sh                    # 从 HA 拉取最新配置回本仓库（备份+同步）
```

---

## 快速开始

### 前置依赖

本方案消费以下实体，**你需要先让它们存在**（ESP8266 / ESPHome TDS 方案、或任何能给出 TDS 与流量的设备）：

| 实体 | 说明 | 单位 |
|---|---|---|
| `sensor.tds_esp8266_tds1` | 纯水 TDS | ppm |
| `sensor.tds_esp8266_tds2` | 原水 TDS | ppm |
| `sensor.tds_esp8266_total_purified_water_usage` | 净水机累计制水量（原始，会归零） | L |
| `sensor.tds_esp8266_total_water_usage` | 净水机累计进水量 | L |
| `sensor.0021030105848_ben_ci_chao_ma` | 水务账单「本次抄码」（入户 PP 专用，可选） | m³ |

> 实体名对不上？改 `sensors.yaml` / `input_number.yaml` 里的引用即可，或给实体设别名。

### 安装步骤

1. **拷文件**：把 `config/water_purifier/` 与 `config/automations/water_purifier/` 拷到 HA 的 `/config/` 对应路径下。

2. **改 configuration.yaml**（参照 `config/configuration.example.yaml`，**不要直接覆盖**）：
   ```yaml
   notify:
     - name: "gotify"
       platform: gotify
       url: http://YOUR_GOTIFY_HOST:PORT/
       token: YOUR_GOTIFY_APP_TOKEN

   # ========== 净水系统监控 ==========
   input_number: !include water_purifier/input_number.yaml
   input_button: !include water_purifier/input_button.yaml
   input_datetime: !include water_purifier/input_datetime.yaml
   input_text: !include water_purifier/input_text.yaml
   template:
     - sensor: !include water_purifier/sensors.yaml
   # =================================
   ```
   自动化若已用 `automation manual: !include_dir_merge_list automations/` 则无需额外配置。

3. **初始化累计器**（关键，只做一次）：
   在 HA **开发者工具 → 服务** 里执行 `input_number.set_value`，把两个值都设为**当前**累计制水量：
   - `input_number.esp_purified_accum` = 当前 `sensor.tds_esp8266_total_purified_water_usage` 的值
   - `input_number.esp_purified_last` = 同一个值

4. **设置换芯基线**：为每个滤芯设一次起始值（否则显示「未设置」）：
   - 5 个净水端：`input_number.waterpurifier_start_<滤芯>` = 当前累计制水量（L）
   - 入户 PP：`input_number.waterpurifier_start_pp_20inch` = 当前水务抄码（**m³**）
   - 同时设 `input_datetime.waterpurifier_change_time_<滤芯>` = 上次换芯日期

   > 懒人办法：直接按一次 `input_button.reset_waterpurifier_<滤芯>`，自动化会把上面两步一起做完。

5. **重载**（无需重启）：开发者工具 → YAML → 依次重载 `input_number`、`automation`、`template`。

6. **导入仪表盘**：`dashboard/lovelace_waterpurifier_view.json` 是一个完整的 sections 视图，在仪表盘编辑器的**原始配置编辑**里粘贴进 `views: []` 数组即可。

   > ⚠️ 视图里用了 `custom:stack-in-card`（HACS 卡片）。没装的话把它替换成 `horizontal-stack`，或删掉那段。

---

## 核心设计

### 1. 三层数据流

```
设备原始读数  →  HA 侧累计器  →  已用量  →  状态判定  →  提醒/仪表盘
(raw, 会归零)    (accum, 单调)   (*_used)   (status_*)   (Gotify)
```

### 2. 单调累计器（本方案的灵魂）

ESP8266 没有持久化累计，**断电即归零**。这会让「已用制水量」回退、换芯基线失真。

解法在 HA 侧加一层，自动化的核心就一行：

```jinja
delta = (cur - prev) if cur >= prev else cur   # 下跌 = 设备重启归零 → 按从 0 重新计
accum += delta                                  # 只增不减
```

- 正常增长：32.634 → 33.0，delta = 0.366，累加
- 断电归零：32.634 → 0.5，delta = 0.5（**不是 −32.1**），累计继续爬升
- `accum` / `last` 都**不设 `initial`** → 依赖 HA 状态恢复，跨重启不丢

### 3. 寿命阈值：变量驱动，不写死

`status_*` 模板**读** `input_number.use_date_*`，而非硬编码常量：

```jinja
更换线 = use_date_*           # 寿命
警告线 = use_date_* // 2      # 一半
```

入户 PP 特殊：`警告线 = use_date_pp_20inch - 35`（365 天时 = 330 天，接近寿命才提醒）。

> ⚠️ **`input_number` 设了 `initial` 就不做状态恢复、每次 HA 重启强制回 `initial`。** 想持久调整寿命，必须改 `input_number.yaml` 的 `initial` 值 —— 仅在 UI 拖滑块会被重启覆盖。同时注意 `initial` 不能超过 `max`（否则 reload 直接失败）。

### 4. RO 双信号判定

RO 膜衰减不能只看天数（用水少时天数到了但膜还行，反之亦然）。本方案同时看两个信号：

| 信号 | 变差方向 | 警告 | 更换 |
|---|---|---|---|
| 脱盐率 `sensor.ro_salt_rejection` | **越低越差** | < 90% | < 85% |
| 纯水 TDS `sensor.tds_esp8266_tds1` | 越高越差 | > 15 ppm | > 25 ppm |

任一触发即预警；两项都健康时，用天数兜底（警告线 = `use_date_ro // 2`）。

判定矩阵（已验证单调）：98% → 健康；87% → 警告；80% → 更换。

> ⚠️ 注意脱盐率的方向与其他指标相反：**数值越低越严重**。早期版本曾写反成 `警告<85 / 更换<90`，导致 87%（比 85% 更健康）反而跳过警告直接判更换 —— 已修复，详见 `docs/CHANGELOG.md`。

---

## 提醒机制

- **触发**：`status_*` 跳变到 `警告` 或 `更换`
- **防抖**：`for: 00:10:00`（10 分钟），过滤重启/重载瞬时抖动
- **兜底**：HA 启动 + 每 6 小时巡检一次，扫描当前所有警告/更换项 —— 解决「已逾期但状态没跳变 → 永远不提醒」的经典漏报
- **渠道**：Gotify（`notify.gotify`），Markdown 格式

---

> 本包属于 [`ha-packages`](../) monorepo（HA 配置包集合）。HA 自定义集成（Python）在独立仓库，因为 HACS 要求一仓一集成。

---

## 维护

### 更新本仓库

改完 HA 配置后，从仓库根目录跑（自动备份、自动排除 `.bak_*`、自动脱敏、提交前凭据复查）：

```bash
./scripts/deploy.sh water-purifier
python3 scripts/gh_commit.py . ccbslsx/ha-packages main "sync: water-purifier $(date +%Y%m%d)"
```

包内 `sync.conf` 声明了「拉哪些远端目录、放到本地哪里」—— 改同步范围只改这个文件。

### 备份与回滚

HA 侧每次改动前会自动留下 `.bak_<日期>` 备份。回滚 = 还原对应文件 + 重载。

---

## 文档

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) —— 架构、数据流、实体清单、判定逻辑
- [`docs/CHANGELOG.md`](docs/CHANGELOG.md) —— 三轮改造的完整记录（含踩过的坑）

---

## 许可

MIT
