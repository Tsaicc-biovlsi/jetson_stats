#!/usr/bin/env bash
# =============================================================================
# Orin Nano 一鍵設定：
#   1. 從 fork 安裝 jetson-stats (jtop)，含 R39 手動風扇修正
#   2. 安裝 Rime 繁體中文輸入法（預設注音、台灣正體），移除新酷音
#
# 用法（請用一般使用者執行，不要加 sudo）：
#   bash setup_orin_nano.sh                # 兩個都裝
#   bash setup_orin_nano.sh --jtop-only    # 只裝 jtop
#   bash setup_orin_nano.sh --ime-only     # 只裝輸入法
#   bash setup_orin_nano.sh --keep-chewing # 保留新酷音（與 Rime 並存）
#
# 可用環境變數覆蓋 jtop 來源，例如指定分支或 commit：
#   JTOP_REF="git+https://github.com/Tsaicc-biovlsi/jetson_stats.git@master" bash setup_orin_nano.sh
# =============================================================================
set -Eeuo pipefail

JTOP_REF="${JTOP_REF:-git+https://github.com/Tsaicc-biovlsi/jetson_stats.git@master}"
VENV_DIR="$HOME/.local/share/jtop"
JTOP_BIN="$VENV_DIR/bin/jtop"
SYMLINK_PATH="/usr/local/bin/jtop"
SYSTEMD_UNIT="/etc/systemd/system/jtop.service"
RIME_DIR="$HOME/.config/ibus/rime"

DO_JTOP=1
DO_IME=1
KEEP_CHEWING=0

for arg in "$@"; do
  case "$arg" in
    --jtop-only)    DO_IME=0 ;;
    --ime-only)     DO_JTOP=0 ;;
    --keep-chewing) KEEP_CHEWING=1 ;;
    -h|--help)      sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知參數: $arg（用 --help 查看用法）" >&2; exit 1 ;;
  esac
done

trap 'echo "❌ 第 $LINENO 行出錯：$BASH_COMMAND" >&2' ERR

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
  echo "請用一般使用者執行（不要加 sudo），腳本會在需要時自己呼叫 sudo。" >&2
  exit 1
fi

# 先取得 sudo 權限，避免中途卡住
sudo -n true 2>/dev/null || sudo -v

# 是否在圖形桌面 session 裡（gsettings / ibus 需要）
have_desktop_bus() {
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || [[ -S "/run/user/$(id -u)/bus" ]]
}

# -----------------------------------------------------------------------------
# 1. jetson-stats (jtop)
# -----------------------------------------------------------------------------
install_jtop() {
  log "安裝 jtop 前置套件"
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends curl ca-certificates git python3-pip

  if ! command -v uv >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/uv" ]]; then
    log "安裝 uv"
    curl -fsSL https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$HOME/.local/bin:$PATH"

  sudo groupadd -f jtop

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    log "建立 Python 虛擬環境 $VENV_DIR"
    uv venv "$VENV_DIR" -p python3.12 --seed
  fi

  log "從 fork 安裝 jetson-stats：$JTOP_REF"
  # 舊版 service 可能在 venv 裡留下 root 擁有的 __pycache__，先停掉 service 再清理
  sudo systemctl stop jtop.service 2>/dev/null || true
  sudo find "$VENV_DIR" -name '__pycache__' -user root -prune -exec rm -rf {} + 2>/dev/null || true
  uv pip install --python "$VENV_DIR/bin/python" --reinstall-package jetson-stats --upgrade "$JTOP_REF"

  # Thor 等機型才有的 pylibjetsonpower，存在就連進 venv（可選）
  for p in /usr/lib/python3/dist-packages/pylibjetsonpower \
           /usr/local/lib/python3*/dist-packages/pylibjetsonpower \
           /usr/lib/python3*/dist-packages/pylibjetsonpower; do
    if [[ -f "$p/__init__.py" ]]; then
      site="$("$VENV_DIR/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
      rm -rf "$site/pylibjetsonpower"
      ln -s "$p" "$site/pylibjetsonpower"
      echo "已連結 pylibjetsonpower: $p"
      break
    fi
  done

  [[ -x "$JTOP_BIN" ]] || { echo "安裝失敗：找不到 $JTOP_BIN" >&2; exit 1; }
  sudo ln -sf "$JTOP_BIN" "$SYMLINK_PATH"

  log "建立並啟動 jtop service"
  sudo tee "$SYSTEMD_UNIT" >/dev/null <<EOF
[Unit]
Description=Jetson Stats (jtop service)
After=network.target

[Service]
Environment="JTOP_SERVICE=True"
ExecStart=${SYMLINK_PATH} --force
Restart=on-failure
RestartSec=10s
TimeoutStartSec=30s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable jtop.service
  sudo systemctl restart jtop.service
  sleep 3

  version="$("$VENV_DIR/bin/python" -c 'import jtop; print(jtop.__version__)')"
  state="$(systemctl is-active jtop.service || true)"
  if grep -q '_set_kernel_control' "$VENV_DIR"/lib/python3*/site-packages/jtop/core/fan.py; then
    fanfix="有"
  else
    fanfix="沒有（fork 上可能還沒推送風扇修正）"
  fi
  echo "jetson-stats $version，service: $state，R39 手動風扇修正：$fanfix"
}

# -----------------------------------------------------------------------------
# 2. Rime 繁體中文輸入法
# -----------------------------------------------------------------------------
backup_if_exists() {
  [[ -f "$1" ]] && cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"
  return 0
}

install_ime() {
  log "安裝 Rime 輸入法與注音／拼音方案"
  sudo apt-get update -y
  sudo apt-get install -y ibus ibus-rime \
    rime-data-bopomofo rime-data-terra-pinyin rime-data-luna-pinyin rime-data-emoji

  log "寫入 Rime 設定（$RIME_DIR）"
  mkdir -p "$RIME_DIR"
  backup_if_exists "$RIME_DIR/default.custom.yaml"
  cat > "$RIME_DIR/default.custom.yaml" <<'EOF'
# Rime 個人設定（覆蓋 /usr/share/rime-data/default.yaml）
patch:
  schema_list:
    - schema: bopomofo_tw      # 注音（台灣正體字形）— 預設
    - schema: bopomofo         # 注音（傳統字形）
    - schema: terra_pinyin     # 地球拼音（可打出聲調）
    - schema: luna_pinyin_tw   # 朙月拼音（台灣正體）
  menu/page_size: 9
  # F4 或 Ctrl+` 叫出方案選單
  switcher/hotkeys:
    - F4
    - Control+grave
  # 左右 Shift 都切換中英文；切換時把已打的字根當英文送出
  ascii_composer/switch_key/Shift_L: commit_code
  ascii_composer/switch_key/Shift_R: commit_code
EOF
  backup_if_exists "$RIME_DIR/ibus_rime.custom.yaml"
  cat > "$RIME_DIR/ibus_rime.custom.yaml" <<'EOF'
patch:
  style/horizontal: true     # 候選字橫排
EOF

  log "部署 Rime 設定"
  (cd "$RIME_DIR" && rime_deployer --build "$RIME_DIR" /usr/share/rime-data "$RIME_DIR/build" >/dev/null)

  if have_desktop_bus && command -v gsettings >/dev/null 2>&1; then
    if [[ $KEEP_CHEWING -eq 1 ]]; then
      sources="[('ibus', 'chewing'), ('ibus', 'rime')]"
    else
      sources="[('ibus', 'rime')]"
    fi
    gsettings set org.gnome.desktop.input-sources sources "$sources"
    echo "輸入來源：$sources"
    if pgrep -u "$(id -u)" -x ibus-daemon >/dev/null; then
      ibus restart || true
      sleep 3
      ibus engine rime || true
    fi
  else
    warn "目前不在桌面 session（例如透過 SSH 執行），沒辦法設定輸入來源。"
    warn "登入桌面後到「設定 → 鍵盤 → 輸入來源」加入「Rime」，或在桌面終端機重新執行："
    warn "  bash $0 --ime-only"
  fi

  if [[ $KEEP_CHEWING -eq 0 ]] && dpkg -s ibus-chewing >/dev/null 2>&1; then
    log "移除新酷音"
    sudo apt-get remove -y ibus-chewing
    sudo apt-get autoremove -y
  fi
}

# -----------------------------------------------------------------------------
[[ $DO_JTOP -eq 1 ]] && install_jtop
[[ $DO_IME  -eq 1 ]] && install_ime

log "全部完成"
[[ $DO_JTOP -eq 1 ]] && echo "  • jtop：執行 'jtop' 開啟監控畫面"
[[ $DO_IME  -eq 1 ]] && echo "  • 輸入法：Shift 切換中英文，F4 選方案；若沒出現 Rime，請登出再登入一次"
exit 0
