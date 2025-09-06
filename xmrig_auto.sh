#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\033[1;32m[+] \033[0m%s\n" "$1"; }
warn(){ printf "\033[1;33m[!] \033[0m%s\n" "$1"; }
die(){ printf "\033[1;31m[x] \033[0m%s\n" "$1"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Command '$1' required but not found."; }

# === Input wallet ===
read -rp "Masukkan wallet Monero (XMR) Anda: " WALLET
[[ -z "$WALLET" ]] && die "Wallet tidak boleh kosong."

# === Menu pool ===
cat <<'MENU'
Pilih pool (boleh lebih dari 1, pisahkan dengan koma):
1. pool.supportxmr.com:3333   (recommended)
2. pool.moneroocean.stream:10128
3. de.monero.herominers.com:1111
4. p2pool.io:3333
5. Custom pool (masukkan manual)
MENU

read -rp "Pilihan (mis. 1,3 atau 1 untuk default): " POOL_CHOICE
POOL_CHOICE=${POOL_CHOICE:-1}

IFS=',' read -ra CHOICES <<< "$POOL_CHOICE"
POOLS=()
for CH in "${CHOICES[@]}"; do
  CH=$(echo "$CH" | tr -d '[:space:]')
  case "$CH" in
    1) POOLS+=("pool.supportxmr.com:3333") ;;
    2) POOLS+=("pool.moneroocean.stream:10128") ;;
    3) POOLS+=("de.monero.herominers.com:1111") ;;
    4) POOLS+=("p2pool.io:3333") ;;
    5) read -rp "Masukkan URL pool custom (host:port): " CUSTOM_POOL
       POOLS+=("$CUSTOM_POOL") ;;
    *) warn "Pilihan tidak valid: $CH (diabaikan)" ;;
  esac
done
[[ ${#POOLS[@]} -eq 0 ]] && die "Tidak ada pool yang dipilih."

# === Threads ===
DEFAULT_THREADS=$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 1 )
read -rp "Jumlah threads total (Enter=auto $DEFAULT_THREADS): " TOTAL_THREADS
TOTAL_THREADS=${TOTAL_THREADS:-$DEFAULT_THREADS}
[[ ! "$TOTAL_THREADS" =~ ^[0-9]+$ ]] && die "Jumlah threads harus angka."

# === Background run ===
read -rp "Jalankan miner di background? [y/N]: " RUN_BG
RUN_BG=${RUN_BG,,}

# === Directories ===
WORKDIR=${PWD}
INSTALL_DIR="$WORKDIR/xmrig_auto_install"
BIN_DIR="$INSTALL_DIR/bin"
BUILD_DIR="$INSTALL_DIR/build"
LOG_DIR="$INSTALL_DIR/logs"
PID_FILE="$INSTALL_DIR/xmrig_pids.txt"
mkdir -p "$BIN_DIR" "$BUILD_DIR" "$LOG_DIR"

# === Env detect ===
OS=$(uname -s)
ARCH=$(uname -m)
TERMUX=0
if command -v pkg >/dev/null 2>&1 && [[ -d "/data/data/com.termux/files/usr" ]]; then
  TERMUX=1
fi
log "Detected OS: $OS ($ARCH)"
[[ $TERMUX -eq 1 ]] && log "Termux/Android detected"

# === Hugepages (best-effort) ===
enable_hugepages(){
  if [[ $(id -u) -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 && SUDO="sudo" || return
  else
    SUDO=""
  fi
  [[ -d /sys/kernel/mm/hugepages/hugepages-2048kB ]] && \
    $SUDO bash -c "echo 128 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages" 2>/dev/null || true
}

# === MSR (best-effort) ===
enable_msr(){
  if [[ $(id -u) -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 && SUDO="sudo" || return
  else
    SUDO=""
  fi
  $SUDO modprobe msr 2>/dev/null || true
}

# === Download prebuilt binary ===
download_xmrig_binary(){
  need_cmd curl; need_cmd wget
  log "Mencari release binary XMRig..."
  LATEST_URL=$(curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest \
    | grep browser_download_url | grep linux | grep x64 | head -n1 | cut -d '"' -f4 || true)
  [[ -z "$LATEST_URL" ]] && return 1
  wget -q "$LATEST_URL" -O "$WORKDIR/xmrig.tar.gz" || return 1
  tar -xzf "$WORKDIR/xmrig.tar.gz" -C "$WORKDIR" || return 1
  BINPATH=$(find "$WORKDIR" -maxdepth 2 -type f -name xmrig -perm /111 | head -n1 || true)
  [[ -n "$BINPATH" ]] || return 1
  cp "$BINPATH" "$BIN_DIR/xmrig"
  chmod +x "$BIN_DIR/xmrig"
  return 0
}

# === Compile from source ===
compile_xmrig_from_source(){
  need_cmd git; need_cmd cmake; need_cmd make
  if [[ $TERMUX -eq 1 ]]; then
    pkg install -y clang make cmake git openssl-tool libuv
  fi
  git clone https://github.com/xmrig/xmrig.git "$INSTALL_DIR/xmrig" || true
  cd "$BUILD_DIR"
  cmake "$INSTALL_DIR/xmrig" -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON
  make -j$(nproc)
  cp "$BUILD_DIR/xmrig" "$BIN_DIR/xmrig"
  chmod +x "$BIN_DIR/xmrig"
}

# === Install flow ===
if [[ "$OS" == "Linux" || "$TERMUX" -eq 1 ]]; then
  if [[ $TERMUX -eq 1 ]]; then
    pkg update -y && pkg install -y git build-essential cmake automake libtool autoconf hwloc libuv openssl wget curl tar
  elif command -v apt >/dev/null 2>&1; then
    sudo apt update -y && sudo apt install -y git build-essential cmake automake libtool autoconf libhwloc-dev libuv1-dev libssl-dev wget curl tar
  fi
  download_xmrig_binary || compile_xmrig_from_source
  enable_msr
  enable_hugepages
else
  die "Windows/Unknown OS tidak didukung script otomatis."
fi

# === Run instances ===
POOL_COUNT=${#POOLS[@]}
THREADS_PER=$((TOTAL_THREADS / POOL_COUNT))
REM=$((TOTAL_THREADS % POOL_COUNT))
> "$PID_FILE"

idx=0
for P in "${POOLS[@]}"; do
  idx=$((idx+1))
  extra=0
  [[ $REM -gt 0 ]] && { extra=1; REM=$((REM-1)); }
  threads_for_instance=$((THREADS_PER + extra))
  logfile="$LOG_DIR/xmrig_pool_${idx}.log"
  cmd="$BIN_DIR/xmrig -o $P -u $WALLET -p x --threads=$threads_for_instance --donate-level=1 --randomx-1gb-pages --huge-pages --cpu-priority=5"
  if [[ "$RUN_BG" == "y" || "$RUN_BG" == "yes" ]]; then
    nohup bash -c "$cmd" > "$logfile" 2>&1 &
    pid=$!
    printf "%s %s %s\n" "$pid" "$P" "$logfile" >> "$PID_FILE"
    log "Started bg -> Pool: $P, Threads: $threads_for_instance, Log: $logfile"
  else
    exec bash -c "$cmd"
  fi
done
[[ "$RUN_BG" == "y" || "$RUN_BG" == "yes" ]] && log "Semua instance jalan. PID di $PID_FILE"