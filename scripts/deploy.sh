#!/usr/bin/env bash
#
# deploy.sh —— 从 HAOS 拉取某个配置包的最新文件，同步回本仓库。
#
# 用法：
#   ./scripts/deploy.sh water-purifier          # 同步指定包
#   ./scripts/deploy.sh --list                  # 列出所有包
#
# 环境变量（可选覆盖）：
#   HA_HOST   默认 192.168.31.233
#   HA_USER   默认 root
#   SSH_KEY   默认 ~/.ssh/ahqnzs_ssh_key
#   HA_CONFIG 默认 /homeassistant
#
# 包内需有 sync.conf 描述「拉什么、放哪」（参见任意包的 sync.conf 注释）。
# 该脚本只读 HA 配置 + 写本地仓库，不改动 HA 上的任何文件（除必要的 .bak 备份）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- 参数处理 ----------
PKG="${1:-}"
if [[ "$PKG" == "--list" || "$PKG" == "-l" ]]; then
  echo "可用配置包："
  for d in "$ROOT"/*/; do
    name="$(basename "$d")"
    [[ "$name" == "scripts" ]] && continue
    [[ -f "$d/sync.conf" ]] && echo "  - $name"
  done
  exit 0
fi
if [[ -z "$PKG" ]]; then
  echo "用法: $0 <package>    (用 --list 查看可用包)" >&2
  exit 1
fi

PKG_DIR="$ROOT/$PKG"
[[ -d "$PKG_DIR" ]] || { echo "✗ 找不到配置包: $PKG" >&2; exit 1; }
CONF="$PKG_DIR/sync.conf"
[[ -f "$CONF" ]] || { echo "✗ 缺少清单文件: $PKG/sync.conf" >&2; exit 1; }

# ---------- 默认值（可被 sync.conf 覆盖）----------
HA_HOST="${HA_HOST:-192.168.31.233}"
HA_USER="${HA_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ahqnzs_ssh_key}"
HA_CONFIG="${HA_CONFIG:-/homeassistant}"

TAR_PATHS=()            # 远端要打包的路径
CONFIG_YAML=""          # 远端 configuration.yaml（可选，用于脱敏示例）
DASHBOARD_VIEW_PATH=""  # Lovelace 视图 path（可选）
DASHBOARD_LOCAL=""      # 视图导出到本地的位置

# shellcheck source=/dev/null
source "$CONF"

TS="$(date +%Y%m%d_%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
SCP_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "════════════════════════════════════════"
echo " 包     : $PKG"
echo " 主机   : ${HA_USER}@${HA_HOST}:${HA_CONFIG}"
echo " 仓库   : $ROOT"
echo "════════════════════════════════════════"

[[ ${#TAR_PATHS[@]} -gt 0 ]] || { echo "✗ sync.conf 未定义 TAR_PATHS" >&2; exit 1; }
REMOTE_BAK="${BACKUP_PATHS[@]:-${TAR_PATHS[*]}}"

# ---------- 1. HA 侧备份 ----------
echo "==> [1/4] HA 侧备份 (.bak_${TS})"
ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" bash -s <<EOF
cd ${HA_CONFIG}
for f in ${REMOTE_BAK}; do
  [ -d "\$f" ] || continue
  while IFS= read -r y; do
    case "\$y" in *.bak_*) continue;; esac
    cp -n "\$y" "\$y.bak_${TS}"
  done < <(find "\$f" -maxdepth 1 -name '*.yaml')
done
echo '  backup ok'
EOF

# ---------- 2. 打包拉取 ----------
echo "==> [2/4] 拉取配置文件"
REMOTE_TAR="/tmp/hapkg_${PKG}_${TS}.tar.gz"
ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" \
  "cd ${HA_CONFIG} && tar czf ${REMOTE_TAR} ${TAR_PATHS[*]} ${CONFIG_YAML} 2>/dev/null"
scp "${SCP_OPTS[@]}" "${HA_USER}@${HA_HOST}:${REMOTE_TAR}" "${TMP}/src.tar.gz"
ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "rm -f ${REMOTE_TAR}"
mkdir -p "${TMP}/src"
tar xzf "${TMP}/src.tar.gz" -C "${TMP}/src"

# ---------- 3. 按目录同步 + 脱敏 ----------
echo "==> [3/4] 同步到仓库"
synced=0

# 目录映射在 sync.conf 中以 DIR_MAP 数组声明，元素形如 "远端目录:本地相对目录"
for entry in "${DIR_MAP[@]}"; do
  remote="${entry%%:*}"
  localdir="${entry##*:}"
  [[ -d "${TMP}/src/${remote}" ]] || { echo "  ! 远端目录不存在，跳过: $remote"; continue; }
  mkdir -p "${PKG_DIR}/${localdir}"
  while IFS= read -r f; do
    case "$f" in *.bak_*) continue;; esac
    cp "$f" "${PKG_DIR}/${localdir}/"
    echo "  + ${localdir}/$(basename "$f")"
    synced=$((synced+1))
  done < <(find "${TMP}/src/${remote}" -maxdepth 1 -name '*.yaml')
done

# configuration.yaml 脱敏示例
if [[ -n "$CONFIG_YAML" && -f "${TMP}/src/${CONFIG_YAML}" ]]; then
  python3 "$ROOT/scripts/redact.py" "${TMP}/src/${CONFIG_YAML}" \
      "${PKG_DIR}/config/configuration.example.yaml"
fi

# Lovelace 视图导出
if [[ -n "$DASHBOARD_VIEW_PATH" ]]; then
  echo "==> 导出仪表盘视图: $DASHBOARD_VIEW_PATH"
  ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "cd ${HA_CONFIG} && python3 -c \"
import json
d = json.load(open('.storage/lovelace.lovelace'))
for v in d['data']['config']['views']:
    if v.get('path') == '${DASHBOARD_VIEW_PATH}':
        open('/tmp/view_${TS}.json','w').write(json.dumps(v, ensure_ascii=False, indent=2))
\"" || true
  if ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "test -f /tmp/view_${TS}.json"; then
    mkdir -p "$(dirname "${PKG_DIR}/${DASHBOARD_LOCAL}")"
    scp "${SCP_OPTS[@]}" "${HA_USER}@${HA_HOST}:/tmp/view_${TS}.json" "${PKG_DIR}/${DASHBOARD_LOCAL}"
    ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "rm -f /tmp/view_${TS}.json"
    echo "  + ${DASHBOARD_LOCAL}"
  fi
fi

# ---------- 4. 敏感信息复查 ----------
echo "==> [4/4] 敏感信息复查"
if grep -rInE "(token|password|api_key|secret|access_token)[\":= ]{1,4}[A-Za-z0-9_/+=-]{16,}" \
     "${PKG_DIR}" --exclude="*.example.yaml" --exclude="*.md" 2>/dev/null; then
  echo ""
  echo "  ⚠️  以上位置疑似真实凭据！确认并处理后才能提交。" >&2
  exit 1
fi
echo "  ✓ 未发现疑似凭据"

echo ""
echo "==> 完成（同步 $synced 个文件；HA 侧备份后缀 .bak_${TS}）"
echo "    下一步：python3 scripts/gh_commit.py . ccbslsx/ha-packages main \"sync: $PKG $TS\""
