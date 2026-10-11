#!/usr/bin/env python3
"""
redact.py —— 共享脱敏器。

把 HA 的 configuration.yaml 里的敏感信息替换成占位符，输出为 *.example.yaml。
被 scripts/deploy.sh 调用，也可单独使用：

    python3 scripts/redact.py <输入 configuration.yaml> <输出 example.yaml>

⚠️ 新增敏感项（新的 notify 平台、新的 API key 等）时，在下面的
   RULES 列表里追加一条即可，所有包共用。
"""
import re
import sys

# (正则, 替换) —— 顺序敏感：先具体后笼统
RULES = [
    # --- 通知 / 推送平台 token ---
    (r"(?im)^(\s*token:\s*)\S+",                    r"\1YOUR_GOTIFY_APP_TOKEN"),
    (r"(?im)^(\s*api_key:\s*)\S+",                  r"\1YOUR_API_KEY"),
    (r"(?im)^(\s*password:\s*)\S+",                 r"\1YOUR_PASSWORD"),
    (r"(?im)^(\s*secret:\s*)\S+",                   r"\1YOUR_SECRET"),

    # --- 企微 / 钉钉 / 飞书 webhook ---
    (r"key=[0-9a-fA-F-]{8,}",                       "key=YOUR_WEBHOOK_KEY"),
    (r"(?i)(oapi\.dingtalk\.com/robot/send\?access_token=)\S+", r"\1YOUR_DINGTALK_TOKEN"),

    # --- 内网地址 / 端口 ---
    (r"https?://192\.168\.\d+\.\d+:\d+/?",          "http://YOUR_HOST:PORT/"),
    (r"https?://10\.\d+\.\d+\.\d+:\d+/?",           "http://YOUR_HOST:PORT/"),

    # --- 长串 base64 / 十六进制密钥（兜底） ---
    (r"(?i)((?:key|token|secret|pass)\w*\s*[:=]\s*)[A-Za-z0-9+/_-]{24,}={0,2}",
     r"\1YOUR_CREDENTIAL"),
]


def redact(text: str) -> str:
    for pat, rep in RULES:
        text = re.sub(pat, rep, text)
    return text


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    try:
        with open(src, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        print(f"! 读取失败 {src}: {e}")
        return 1

    out = redact(text)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(out)

    # 回显命中的占位符，便于人工复核
    hits = sorted(set(re.findall(r"YOUR_[A-Z_]+", out)))
    print(f"  + {dst}  (脱敏占位符: {', '.join(hits) if hits else '无命中'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
