# HA Packages

我的 Home Assistant **自建子系统配置包**集合。每套子系统一个子目录，共享部署与同步工具。

> 这里放的是 **YAML 配置包**（实体定义 / 自动化 / 仪表盘），不是 HACS 集成。
> HA 自定义集成（Python）在各自独立的仓库，因为 HACS 要求一仓一集成：
> [`towngas-ha`](https://github.com/ccbslsx/towngas-ha) · [`MasWater-Homeassistant-Integration`](https://github.com/ccbslsx/MasWater-Homeassistant-Integration)

---

## 包含的包

| 包 | 说明 | 维度 |
|---|---|---|
| [`water-purifier`](water-purifier/) | 净水机全生命周期管理：用量计算、寿命判定、换芯重置、到期提醒 | 6 滤芯（PP/UDF/CTO/RO/T33/入户PP） |

---

## 目录约定

```
ha-packages/
├── scripts/                    # 全域共享工具
│   ├── deploy.sh               # 从 HAOS 拉某个包的最新配置回仓库
│   ├── gh_commit.py            # 走 gh api 提交（绕开 git 443 不稳）
│   └── redact.py               # 共享脱敏规则（新增敏感项改这里）
├── water-purifier/             # 一套子系统 = 一个目录
│   ├── README.md               # 该包的详细说明
│   ├── sync.conf               # ⭐ 告诉 deploy.sh「拉什么、放哪」
│   ├── config/                 # 拷到 HA /config 的文件
│   ├── dashboard/              # 仪表盘视图导出
│   └── docs/                   # 架构 / 变更日志
└── <下一个包>/                  # 照抄 water-purifier 的结构
```

**新增一套包**：`mkdir <新包>/` → 拷一份 `water-purifier/sync.conf` 改路径 → 写 README → `deploy.sh` 首次同步 → `gh_commit.py` 提交。不用碰 `scripts/`。

---

## 常用操作

```bash
# 列出所有包
./scripts/deploy.sh --list

# 从 HAOS 拉取某包最新配置（自动备份 + 脱敏 + 提交前凭据复查）
./scripts/deploy.sh water-purifier

# 提交到 GitHub（走 API，不经 git 传输层）
python3 scripts/gh_commit.py . ccbslsx/ha-packages main "sync: water-purifier 20261011"
```

### 连接参数

默认连 `root@192.168.31.233:/homeassistant`，密钥 `~/.ssh/ahqnzs_ssh_key`。可覆盖：

```bash
HA_HOST=192.168.31.1 SSH_KEY=~/.ssh/other ./scripts/deploy.sh water-purifier
```

---

## 安全约定

**这个仓库会累积多套配置，泄密面比单仓大。** 因此：

1. **绝不提交真实凭据。** `configuration.yaml` 一律经 `redact.py` 脱敏后以 `*.example.yaml` 入库。
2. `deploy.sh` 在提交前会**扫描并拒绝**疑似凭据（token / password / api_key 等长串）。
3. 新增敏感项时，在 `scripts/redact.py` 的 `RULES` 里补一条 —— **所有包共用**。
4. HA 侧的 `.bak_*` 备份文件不纳入版本控制（见 `.gitignore`）。

---

## 许可

MIT
