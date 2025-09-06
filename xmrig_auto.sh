#!/usr/bin/env bash
# xmrig_auto.sh — All-in-one XMRig installer + multi-instance runner + balance checker
# Save as xmrig_auto.sh, chmod +x xmrig_auto.sh
set -euo pipefail

### ----------------------- Globals & Paths -----------------------
WORKDIR="${PWD}"
INSTALL_DIR="${WORKDIR}/xmrig_auto_install"
BIN_DIR="${INSTALL_DIR}/bin"
SRC_DIR="${INSTALL_DIR}/src"
BUILD_DIR="${INSTALL_DIR}/build"
LOG_DIR="${INSTALL_DIR}/logs"
PID_FILE="${INSTALL_DIR}/xmrig_pids.txt"
BAL_PID_FILE="${INSTALL_DIR}/balance_pid.txt"
POOLS_CONF="${INSTALL_DIR}/pools.conf"
BAL_LOG="${LOG_DIR}/balance.log"

mkdir -p "${BIN_DIR}" "${SRC_DIR}" "${BUILD_DIR}" "${LOG_DIR}"

### ----------------------- Helpers -----------------------
log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
warn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
die(){ printf "\033[1;31m[x] \033[0m%s\n" "$*"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found. Please install it."; }

### ----------------------- Stop Mode -----------------------
if [[ "${1:-}" == "stop" ]]; then
  log "Stop requested. Killing miner processes and balance checker..."
  if [[ -f "${PID_FILE}" ]]; then
    while read -r pid rest; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
  fi
  if [[ -f "${BAL_PID_FILE}" ]]; then
    BALPID=$(cat "${BAL_PID_FILE}" 2>/dev/null || echo "")
    [[ -n "${BALPID}" ]] && kill "${BALPID}" 2>/dev/null || true
    rm -f "${BAL_PID_FILE}"
  fi
  log "Stopped."
  exit 0
fi

### ----------------------- Detect environment -----------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
TERMUX=0
if command -v pkg >/dev/null 2>&1 && [[ -d "/data/data/com.termux/files/usr" ]]; then
  TERMUX=1
fi
log "Detected OS: ${OS} (${ARCH})"
[[ ${TERMUX} -eq 1 ]] && log "Termux/Android environment detected"

### ----------------------- Interactive input -----------------------
read -rp "Masukkan wallet Monero (XMR) Anda: " WALLET
[[ -z "${WALLET}" ]] && die "Wallet tidak boleh kosong."

cat <<'EOF'

Pilih pool (boleh lebih dari 1, pisahkan dengan koma):
 1) pool.supportxmr.com:3333   (recommended)
 2) pool.moneroocean.stream:10128
 3) de.monero.herominers.com:1111
 4) p2pool.io:3333
 5) Custom pool (masukkan manual)

EOF

read -rp "Pilihan (mis. 1,3 atau 1 untuk default): " POOL_CHOICE
POOL_CHOICE=${POOL_CHOICE:-1}

IFS=',' read -ra CHOICES <<< "${POOL_CHOICE}"
POOLS=()
for CH in "${CHOICES[@]}"; do
  CH=$(echo "${CH}" | tr -d '[:space:]')
  case "${CH}" in
    1) POOLS+=("pool.supportxmr.com:3333") ;;
    2) POOLS+=("pool.moneroocean.stream:10128") ;;
    3) POOLS+=("de.monero.herominers.com:1111") ;;
    4) POOLS+=("p2pool.io:3333") ;;
    5) read -rp "Masukkan URL pool custom (host:port): " CUSTOM_POOL; POOLS+=("${CUSTOM_POOL}") ;;
    *) warn "Pilihan tidak valid: ${CH} (diabaikan)" ;;
  esac
done
[[ ${#POOLS[@]} -eq 0 ]] && die "Tidak ada pool yang dipilih."

read -rp "Simpan pilihan pool ke ${POOLS_CONF}? [y/N]: " SAVE_POOLS
SAVE_POOLS=${SAVE_POOLS,,}
if [[ "${SAVE_POOLS}" == "y" || "${SAVE_POOLS}" == "yes" ]]; then
  printf "%s\n" "${POOLS[@]}" > "${POOLS_CONF}"
  log "Pool list disimpan ke ${POOLS_CONF}"
fi

DEFAULT_THREADS=$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 1 )
read -rp "Jumlah threads total yang ingin dipakai? (Enter=auto ${DEFAULT_THREADS}): " TOTAL_THREADS
TOTAL_THREADS=${TOTAL_THREADS:-${DEFAULT_THREADS}}
[[ "${TOTAL_THREADS}" =~ ^[0-9]+$ ]] || die "Jumlah threads harus angka."

read -rp "Jalankan miner di background? [y/N]: " RUN_BG
RUN_BG=${RUN_BG,,}

### ----------------------- Prereq & install tools -----------------------
if [[ "${TERMUX}" -eq 1 ]]; then
  log "Install paket dasar di Termux (git, cmake, build tools)..."
  pkg update -y || true
  pkg install -y git build-essential cmake automake libtool autoconf hwloc libuv openssl wget curl tar jq || true
else
  if command -v apt >/dev/null 2>&1; then
    log "Detected apt — installing dependencies..."
    sudo apt update -y
    sudo apt install -y git build-essential cmake automake libtool autoconf libhwloc-dev libuv1-dev libssl-dev wget curl tar jq || true
  elif command -v dnf >/dev/null 2>&1; then
    log "Detected dnf — installing dependencies..."
    sudo dnf install -y git gcc gcc-c++ cmake automake libtool autoconf hwloc-devel libuv-devel openssl-devel make wget curl tar jq || true
  elif command -v pacman >/dev/null 2>&1; then
    log "Detected pacman — installing dependencies..."
    sudo pacman -S --needed --noconfirm git base-devel cmake hwloc libuv openssl wget curl tar jq || true
  else
    warn "Package manager unknown — ensure git, cmake, build tools, hwloc, libuv, openssl, jq exist."
  fi
fi

### ----------------------- Best-effort optimizations -----------------------
enable_msr(){
  log "Attempting to load 'msr' kernel module (best-effort)..."
  if [[ $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      if sudo modprobe msr 2>/dev/null; then log "msr module loaded (sudo)." ; else warn "Failed to load msr (sudo)."; fi
    else
      warn "No sudo/root — cannot load msr."
    fi
  else
    if modprobe msr 2>/dev/null; then log "msr module loaded (root)." ; else warn "Failed to load msr (root)." ; fi
  fi
}
enable_hugepages(){
  log "Attempting to allocate hugepages (best-effort; may fail on VPS/containers)..."
  if [[ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ]]; then
    if [[ $(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo bash -c 'echo 1 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages' 2>/dev/null && log "Allocated 1 x 1GB hugepage (sudo)." || warn "Cannot allocate 1GB hugepages (permission)."
    else
      bash -c 'echo 1 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages' 2>/dev/null && log "Allocated 1 x 1GB hugepage." || warn "Cannot allocate 1GB hugepages (permission)."
    fi
  else
    warn "Kernel does not support 1GB hugepages (hugepages-1048576kB missing)."
  fi
  if [[ -d /sys/kernel/mm/hugepages/hugepages-2048kB ]]; then
    if [[ $(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo bash -c 'echo 128 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages' 2>/dev/null && log "Allocated 128 x 2MB hugepages (sudo)." || warn "Cannot allocate 2MB hugepages (permission)."
    else
      bash -c 'echo 128 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages' 2>/dev/null && log "Allocated 128 x 2MB hugepages." || warn "Cannot allocate 2MB hugepages (permission)."
    fi
  fi
}

### ----------------------- Download prebuilt binary (best-effort) -----------------------
download_xmrig_prebuilt(){
  log "Trying to download prebuilt XMRig binary from GitHub releases..."
  need_cmd curl || return 1
  need_cmd wget || return 1
  # query releases API with User-Agent header
  LATEST_URL=$(curl -s -H "Accept: application/vnd.github.v3+json" -H "User-Agent: xmrig-auto" \
    "https://api.github.com/repos/xmrig/xmrig/releases/latest" \
    | grep browser_download_url || true)
  # pick linux x64 static / linux-x64 if present
  LATEST_URL=$(echo "${LATEST_URL}" | grep -E "linux.*(x64|x86_64|linux-static)" | head -n1 | cut -d '"' -f4 || true)
  if [[ -z "${LATEST_URL}" ]]; then
    warn "Could not determine prebuilt binary URL from GitHub API."
    return 1
  fi
  log "Downloading: ${LATEST_URL}"
  wget -q "${LATEST_URL}" -O "${WORKDIR}/xmrig_prebuilt.tar.gz" || { warn "wget failed"; return 1; }
  tar -xzf "${WORKDIR}/xmrig_prebuilt.tar.gz" -C "${WORKDIR}" || { warn "tar extract failed"; return 1; }
  # find xmrig binary
  BINPATH=$(find "${WORKDIR}" -maxdepth 2 -type f -name xmrig -perm /111 | head -n1 || true)
  if [[ -z "${BINPATH}" ]]; then
    warn "Prebuilt binary not found after extract."
    return 1
  fi
  cp "${BINPATH}" "${BIN_DIR}/xmrig"
  chmod +x "${BIN_DIR}/xmrig"
  log "Prebuilt xmrig copied to ${BIN_DIR}/xmrig"
  return 0
}

### ----------------------- Compile from source -----------------------
compile_xmrig(){
  log "Compile XMRig from source (this may take several minutes)..."
  need_cmd git
  need_cmd cmake
  need_cmd make
  # clone or update
  if [[ -d "${SRC_DIR}/xmrig" ]]; then
    log "Updating existing xmrig source..."
    git -C "${SRC_DIR}/xmrig" pull --ff-only || true
  else
    git clone https://github.com/xmrig/xmrig.git "${SRC_DIR}/xmrig"
  fi
  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"
  cmake "${SRC_DIR}/xmrig" -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON
  make -j"$(nproc)"
  if [[ -f "${BUILD_DIR}/xmrig" ]]; then
    cp "${BUILD_DIR}/xmrig" "${BIN_DIR}/xmrig"
    chmod +x "${BIN_DIR}/xmrig"
    log "Compiled xmrig copied to ${BIN_DIR}/xmrig"
  else
    die "Build failed; check ${BUILD_DIR} for details."
  fi
}

### ----------------------- Prepare binary -----------------------
if [[ ! -x "${BIN_DIR}/xmrig" ]]; then
  if download_xmrig_prebuilt; then
    log "Using prebuilt binary."
  else
    warn "Prebuilt binary unavailable — compiling from source."
    compile_xmrig
  fi
else
  log "xmrig binary already exists at ${BIN_DIR}/xmrig"
fi

### ----------------------- Try optimizations -----------------------
enable_msr || true
enable_hugepages || true

### ----------------------- Spawn multi-instance miners -----------------------
POOL_COUNT=${#POOLS[@]}
THREADS_TOTAL=${TOTAL_THREADS}
THREADS_BASE=$(( THREADS_TOTAL / POOL_COUNT ))
REMAIN=$(( THREADS_TOTAL % POOL_COUNT ))
if [[ ${THREADS_BASE} -lt 1 ]]; then THREADS_BASE=1; fi

log "Spawning ${POOL_COUNT} instance(s). Total threads: ${THREADS_TOTAL}. Base threads per instance: ${THREADS_BASE}. Remainder: ${REMAIN}."

# clear existing pid file
: > "${PID_FILE}"

idx=0
for P in "${POOLS[@]}"; do
  idx=$((idx+1))
  extra=0
  if [[ ${REMAIN} -gt 0 ]]; then extra=1; REMAIN=$((REMAIN-1)); fi
  THREADS_FOR=$(( THREADS_BASE + extra ))
  LOGFILE="${LOG_DIR}/xmrig_pool_${idx}.log"
  CMD="${BIN_DIR}/xmrig -o ${P} -u ${WALLET} -p x --threads=${THREADS_FOR} --donate-level=1 --randomx-1gb-pages --huge-pages --cpu-priority=5"
  if [[ "${RUN_BG}" == "y" || "${RUN_BG}" == "yes" ]]; then
    nohup bash -c "${CMD}" > "${LOGFILE}" 2>&1 &
    PID=$!
    printf "%s %s %s\n" "${PID}" "${P}" "${LOGFILE}" >> "${PID_FILE}"
    log "Started bg -> Pool: ${P} | Threads: ${THREADS_FOR} | PID: ${PID} | Log: ${LOGFILE}"
  else
    log "Running foreground -> Pool: ${P} | Threads: ${THREADS_FOR}"
    exec bash -c "${CMD}"
  fi
done

### ----------------------- Balance checker (background) -----------------------
# Requires jq for JSON parsing; we attempted to install earlier.
check_balance_once_supportxmr(){
  local wallet="$1"
  # supportxmr: API endpoint /api/miner/<wallet>/stats  or /api/miner/<wallet>/payment
  local api="https://supportxmr.com/api/miner/${wallet}/stats"
  local resp
  resp=$(curl -s "${api}" || echo "")
  if [[ -n "${resp}" ]]; then
    local pending
    pending=$(echo "${resp}" | jq -r '.amtDue // .amtDue' 2>/dev/null || echo "0")
    echo "${pending}"
    return 0
  fi
  echo "0"
  return 1
}

check_balance_once_moneroocean(){
  local wallet="$1"
  local api="https://api.moneroocean.stream/miner/${wallet}/currentpaid"
  # Moneroocean has various endpoints; try stats endpoint as fallback
  local resp
  resp=$(curl -s "https://api.moneroocean.stream/miner/${wallet}" || echo "")
  if [[ -n "${resp}" ]]; then
    local pending
    pending=$(echo "${resp}" | jq -r '.data.unpaid // .unpaid // 0' 2>/dev/null || echo "0")
    echo "${pending}"
    return 0
  fi
  echo "0"
  return 1
}

check_balance_once_herominers(){
  local wallet="$1"
  local api="https://monero.herominers.com/api/stats_address?address=${wallet}"
  local resp
  resp=$(curl -s "${api}" || echo "")
  if [[ -n "${resp}" ]]; then
    local pending
    pending=$(echo "${resp}" | jq -r '.stats.unpaid // .stats.balance // 0' 2>/dev/null || echo "0")
    echo "${pending}"
    return 0
  fi
  echo "0"
  return 1
}

balance_loop(){
  log "Balance checker started; writing to ${BAL_LOG} every 10 minutes."
  while true; do
    {
      echo "=== $(date -u +"%Y-%m-%d %H:%M:%SZ") Balance Check ==="
      # supportxmr
      if printf "%s\n" "${POOLS[@]}" | grep -q "supportxmr"; then
        SUP=$(check_balance_once_supportxmr "${WALLET}") || SUP="0"
        echo "[supportxmr] pending: ${SUP} XMR"
      fi
      if printf "%s\n" "${POOLS[@]}" | grep -q "moneroocean"; then
        MO=$(check_balance_once_moneroocean "${WALLET}") || MO="0"
        echo "[moneroocean] pending: ${MO} XMR"
      fi
      if printf "%s\n" "${POOLS[@]}" | grep -q "herominers"; then
        HM=$(check_balance_once_herominers "${WALLET}") || HM="0"
        echo "[herominers] pending: ${HM} XMR"
      fi
      echo ""
    } >> "${BAL_LOG}"
    sleep 600
  done
}

if [[ "${RUN_BG}" == "y" || "${RUN_BG}" == "yes" ]]; then
  if command -v jq >/dev/null 2>&1; then
    balance_loop > "${BAL_LOG}" 2>&1 &
    BALPID=$!
    echo "${BALPID}" > "${BAL_PID_FILE}"
    log "Balance checker running in background (PID: ${BALPID}), log: ${BAL_LOG}"
  else
    warn "jq not found; balance checker needs 'jq' to parse JSON. Install 'jq' to enable balance checking."
  fi
  log "All miners started in background. Use './xmrig_auto.sh stop' to stop them."
else
  log "Miner(s) started in foreground (no balance checker background). To run background mode, restart with background option."
fi

# End of script
