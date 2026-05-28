#!/bin/bash
# ==================================================================
#     Auto ZRAM+Swap Optimizer v3.2.2
# ==================================================================

set -euo pipefail

VERSION="3.2.2"
RELEASE_DATE="2026-05-28"

LOG_FILE="/var/log/zram-optimizer.log"
CONFIG_FILE="/etc/zram-optimizer.conf"
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR="/usr/local/lib/zram-optimizer"
METRICS_PORT="${METRICS_PORT:-9100}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_MODE="${FORCE_MODE:-false}"
QUIET_MODE="${QUIET_MODE:-false}"

# ========== COLOR CODES ==========
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# ========== INITIALIZATION ==========
init_environment() {
    mkdir -p "$SCRIPT_DIR" "$(dirname "$LOG_FILE")"
    # In quiet mode, suppress stdout, but keep stderr and log file
    if [ "$QUIET_MODE" = true ]; then
        exec > >(tee -a "$LOG_FILE" > /dev/null)
    else
        exec > >(tee -a "$LOG_FILE")
    fi
    exec 2>&1
    echo "========================================="
    echo "ZRAM Optimizer Suite v$VERSION"
    echo "Started at: $(date)"
    echo "========================================="
}

# ========== LOGGING (quiet-aware) ==========
log_info()    { [ "$QUIET_MODE" != true ] && echo -e "${CYAN}[INFO]${NC} $1" || true; }
log_success() { [ "$QUIET_MODE" != true ] && echo -e "${GREEN}[OK]${NC} $1" || true; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    [ "$QUIET_MODE" = true ] && return
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

show_status() {
    [ "$QUIET_MODE" = true ] && return
    echo ""
    print_header "SYSTEM STATUS"
    echo -e "${CYAN}Active swaps:${NC}"
    swapon --show 2>/dev/null || echo "No active swaps"
    echo ""
    echo -e "${CYAN}Memory usage:${NC}"
    free -h
    echo ""
    if [ -f /sys/block/zram0/comp_algorithm ]; then
        echo -e "${CYAN}Compression algorithm:${NC} $(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -o '\[[^]]*\]' | tr -d '[]' || echo 'default')"
    fi
    if [ -f /sys/block/zram0/orig_data_size ] && [ -f /sys/block/zram0/compr_data_size ]; then
        local orig=$(cat /sys/block/zram0/orig_data_size 2>/dev/null)
        local compr=$(cat /sys/block/zram0/compr_data_size 2>/dev/null)
        if [ -n "$compr" ] && [ "$compr" -gt 0 ] 2>/dev/null; then
            local ratio=$(echo "scale=2; $orig / $compr" | bc 2>/dev/null || echo "0")
            echo -e "${CYAN}Compression ratio:${NC} ${ratio}:1"
        fi
    fi
    echo -e "${CYAN}Service status:${NC}"
    for svc in zram-setup zram-health.timer zram-metrics; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}✓ $svc: Active${NC}"
        else
            echo -e "  ${RED}✗ $svc: Inactive${NC}"
        fi
    done
}

detect_container() {
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        CONTAINER_ENV="docker"
        log_info "Running in container environment"
    elif [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        CONTAINER_ENV="kubernetes"
        log_info "Running in Kubernetes pod"
    else
        CONTAINER_ENV="none"
    fi
}

check_dependencies() {
    local missing=()
    for cmd in free awk grep modprobe swapon swapoff bc systemctl ionice truncate stat; do
        if ! command -v $cmd &>/dev/null; then
            missing+=($cmd)
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing: ${missing[*]}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y bc util-linux systemd coreutils
        elif command -v dnf &>/dev/null; then
            dnf install -y bc util-linux systemd coreutils
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm bc util-linux systemd coreutils
        fi
    fi
    if ! modinfo zram &>/dev/null; then
        log_error "Kernel doesn't support zRAM!"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        log_info "Loaded configuration from $CONFIG_FILE"
    else
        cat > "$CONFIG_FILE" << 'EOF'
# ZRAM Optimizer Configuration
ZRAM_PERCENT=50
MAX_ZRAM_MB=4096
SWAP_FACTOR=1.0
MAX_SWAP_MB=8192
MIN_SWAP_MB=2048
ZRAM_DEVICES=1
ALGORITHM=auto
SWAPPINESS=auto
VFS_CACHE_PRESSURE=50
SWAP_FILE_PATH="/swapfile"
ALERT_EMAIL=
METRICS_PORT=9100
EOF
        log_info "Created default configuration at $CONFIG_FILE"
    fi
    ZRAM_PERCENT=${ZRAM_PERCENT:-50}
    MAX_ZRAM_MB=${MAX_ZRAM_MB:-4096}
    SWAP_FACTOR=${SWAP_FACTOR:-1.0}
    MAX_SWAP_MB=${MAX_SWAP_MB:-8192}
    MIN_SWAP_MB=${MIN_SWAP_MB:-2048}
    ZRAM_DEVICES=${ZRAM_DEVICES:-1}
    SWAP_FILE_PATH=${SWAP_FILE_PATH:-"/swapfile"}
    VFS_CACHE_PRESSURE=${VFS_CACHE_PRESSURE:-50}

    local cpu_count=$(nproc)
    if [ $ZRAM_DEVICES -gt $cpu_count ]; then
        ZRAM_DEVICES=$cpu_count
        log_warning "Reduced ZRAM_DEVICES to $ZRAM_DEVICES to match CPU cores"
    fi
}

check_disk_space() {
    local swap_mb=$1
    local swap_path_dir=$(dirname "$SWAP_FILE_PATH")
    local available_kb=$(df --output=avail "$swap_path_dir" | tail -1)
    local available_mb=$((available_kb / 1024))
    if [ $swap_mb -gt $available_mb ]; then
        log_warning "Need ${swap_mb}MB, have ${available_mb}MB on $swap_path_dir"
        local new_swap=$((available_mb - 512))
        [ $new_swap -lt 512 ] && { log_error "Insufficient disk"; return 1; }
        echo $new_swap
    else
        echo $swap_mb
    fi
}

calculate_sizes() {
    local ram_mb=$1
    local zram_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    [ $zram_mb -gt $MAX_ZRAM_MB ] && zram_mb=$MAX_ZRAM_MB

    local swap_mb=$(echo "$ram_mb * $SWAP_FACTOR" | bc | cut -d. -f1)
    [ $swap_mb -lt $MIN_SWAP_MB ] && swap_mb=$MIN_SWAP_MB
    [ $swap_mb -gt $MAX_SWAP_MB ] && swap_mb=$MAX_SWAP_MB

    swap_mb=$(check_disk_space $swap_mb) || return 1
    echo "$zram_mb $swap_mb"
}

select_best_algorithm() {
    [ "$ALGORITHM" != "auto" ] && { echo "$ALGORITHM"; return; }
    local cpu_cores=$(nproc)
    if [ $cpu_cores -ge 8 ]; then echo "zstd"
    elif [ $cpu_cores -ge 4 ]; then echo "lz4"
    else echo "lzo"
    fi
}

create_zram_devices() {
    local zram_mb=$1
    log_info "Creating $ZRAM_DEVICES zRAM device(s)..."
    swapoff /dev/zram* 2>/dev/null || true
    modprobe -r zram 2>/dev/null || true
    sleep 1
    modprobe zram num_devices=$ZRAM_DEVICES
    sleep 0.5
    for i in $(seq 0 $((ZRAM_DEVICES - 1))); do
        local dev_mb=$(( zram_mb / ZRAM_DEVICES ))
        [ $i -eq 0 ] && dev_mb=$(( dev_mb + (zram_mb % ZRAM_DEVICES) ))
        if [ -e "/sys/block/zram${i}/disksize" ]; then
            local algo=$(select_best_algorithm)
            if ! echo $algo > /sys/block/zram${i}/comp_algorithm 2>/dev/null; then
                log_error "Failed to set algorithm for zram${i} (check kernel support/SELinux)"
                continue
            fi
            if ! echo ${dev_mb}M > /sys/block/zram${i}/disksize; then
                log_error "Failed to set size for zram${i}"
                continue
            fi
            mkswap /dev/zram${i} 2>/dev/null
            swapon /dev/zram${i} -p $((100 + i))
            log_success "zRAM$i: ${dev_mb}MB, $algo"
        fi
    done
}

# ========== SERVICE SCRIPTS (unchanged from 3.2.1, kept brief) ==========
create_zram_service() {
    cat > "$SCRIPT_DIR/zram-setup.sh" << 'EOF'
#!/bin/bash
CONFIG_FILE="/etc/zram-optimizer.conf"
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi
ZRAM_PERCENT=${ZRAM_PERCENT:-50}; MAX_ZRAM_MB=${MAX_ZRAM_MB:-4096}; ZRAM_DEVICES=${ZRAM_DEVICES:-1}; ALGORITHM=${ALGORITHM:-auto}
cpu_count=$(nproc); [ $ZRAM_DEVICES -gt $cpu_count ] && ZRAM_DEVICES=$cpu_count
ram_mb=$(free -m | awk '/^Mem:/{print $2}'); zram_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
[ $zram_mb -gt $MAX_ZRAM_MB ] && zram_mb=$MAX_ZRAM_MB
select_algo() { local c=$(nproc); if [ $c -ge 8 ]; then echo "zstd"; elif [ $c -ge 4 ]; then echo "lz4"; else echo "lzo"; fi; }
algo=$(select_algo); modprobe zram num_devices=$ZRAM_DEVICES; sleep 0.5
for i in $(seq 0 $((ZRAM_DEVICES-1))); do
  dev_mb=$((zram_mb/ZRAM_DEVICES)); [ $i -eq 0 ] && dev_mb=$((dev_mb + zram_mb % ZRAM_DEVICES))
  if [ -e "/sys/block/zram${i}/disksize" ]; then
    echo $algo > /sys/block/zram${i}/comp_algorithm 2>/dev/null || true
    echo ${dev_mb}M > /sys/block/zram${i}/disksize
    mkswap /dev/zram${i} 2>/dev/null; swapon /dev/zram${i} -p $((100+i))
  fi
done
EOF
    chmod +x "$SCRIPT_DIR/zram-setup.sh"
    cat > /etc/systemd/system/zram-setup.service << EOF
[Unit]
Description=ZRAM Setup (dynamic)
Before=swap.target
[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/zram-setup.sh
RemainAfterExit=yes
[Install]
WantedBy=swap.target
EOF
    systemctl daemon-reload && systemctl enable zram-setup.service
}

create_health_check() {
    cat > "$SCRIPT_DIR/health-check.sh" << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/zram-health.log"
uz=$(swapon --show=USED -no USED 2>/dev/null | head -1); tz=$(swapon --show=SIZE -no SIZE 2>/dev/null | head -1)
[ -n "$tz" ] && [ "$tz" != "0" ] && [ $((uz*100/tz)) -gt 90 ] && echo "[WARN] $(date): zRAM $((uz*100/tz))%" >> "$LOG_FILE"
EOF
    chmod +x "$SCRIPT_DIR/health-check.sh"
    cat > /etc/systemd/system/zram-health.service << 'EOF'
[Unit]
Description=ZRAM Health Check
[Service]
Type=oneshot
ExecStart=/usr/local/lib/zram-optimizer/health-check.sh
EOF
    cat > /etc/systemd/system/zram-health.timer << EOF
[Unit]
Description=ZRAM Health Timer
[Timer]
OnCalendar=hourly; Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable zram-health.timer
}

create_metrics_exporter() {
    cat > "$SCRIPT_DIR/metrics-exporter.sh" << 'EOF'
#!/bin/bash
D="/var/lib/node_exporter"; mkdir -p "$D"; F="$D/zram.prom"; T="$D/zram.prom.tmp"
while true; do
  { for dev in /sys/block/zram*; do [ -d "$dev" ] && echo "zram_disksize_bytes{device=\"$(basename $dev)\"} $(cat $dev/disksize 2>/dev/null||echo 0)"; done; } > "$T"
  mv "$T" "$F"; sleep 60
done
EOF
    chmod +x "$SCRIPT_DIR/metrics-exporter.sh"
    cat > /etc/systemd/system/zram-metrics.service << EOF
[Unit]
Description=ZRAM Metrics
[Service]
Type=simple; ExecStart=$SCRIPT_DIR/metrics-exporter.sh; Restart=always; User=nobody
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable zram-metrics.service
}

restore_backup() {
    local backup_dir=$1
    [ ! -d "$backup_dir" ] && { log_error "Backup not found: $backup_dir"; return 1; }
    log_info "Restoring from $backup_dir..."
    swapoff -a 2>/dev/null || true; modprobe -r zram 2>/dev/null || true
    [ -f "$backup_dir/sysctl.conf" ] && cp "$backup_dir/sysctl.conf" /etc/sysctl.conf && sysctl -p
    [ -f "$backup_dir/fstab" ] && cp "$backup_dir/fstab" /etc/fstab
    for svc in zram-setup zram-health.timer zram-metrics; do systemctl disable "$svc" 2>/dev/null || true; done
    rm -f /etc/systemd/system/zram-*.{service,timer}; systemctl daemon-reload
    log_success "Restore completed. Please reboot."
}

uninstall() {
    [ "$QUIET_MODE" != true ] && echo "" && print_header "UNINSTALL ZRAM OPTIMIZER"
    if [ "$FORCE_MODE" != true ]; then
        read -p "Remove ZRAM Optimizer completely? (y/n): " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Uninstall cancelled"; return 0; }
    fi
    log_info "Removing ZRAM Optimizer..."
    swapoff -a 2>/dev/null || true; modprobe -r zram 2>/dev/null || true
    for svc in zram-setup zram-health.timer zram-health zram-metrics; do
        systemctl stop "$svc" 2>/dev/null || true; systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/zram-*.{service,timer}; rm -rf "$SCRIPT_DIR" "$CONFIG_FILE"
    local lb=$(ls -td /root/zram-backup-* 2>/dev/null | head -1)
    if [ -n "$lb" ]; then
        read -p "Restore from latest backup? (y/n): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && { [ -f "$lb/sysctl.conf" ] && cp "$lb/sysctl.conf" /etc/sysctl.conf; [ -f "$lb/fstab" ] && cp "$lb/fstab" /etc/fstab; sysctl -p 2>/dev/null; log_success "Restored from $lb"; }
    fi
    systemctl daemon-reload; log_success "Uninstall completed. Please reboot."
}

update_sysctl() {
    local key="$1" val="$2" file="/etc/sysctl.conf"
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -i "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

# ========== NEW HELPERS ==========
is_block_device() {
    [ -b "$1" ]
}

warn_if_hdd() {
    local target="$1"
    local dev=$(df "$target" | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    [ -z "$dev" ] && return
    local rotational="/sys/block/$(basename $dev)/queue/rotational"
    if [ -r "$rotational" ] && [ "$(cat $rotational)" -eq 1 ]; then
        log_warning "Swap space on HDD ($dev). Performance may degrade. Consider SSD."
    fi
}

# ========== CORE CONFIGURATION ==========
configure_system() {
    log_info "Starting configuration..."
    systemctl stop zram-metrics zram-health.timer 2>/dev/null || true
    swapoff -a 2>/dev/null || true

    # ----- SWAP SETUP -----
    if is_block_device "$SWAP_FILE_PATH"; then
        log_info "Block device detected: $SWAP_FILE_PATH. Using directly as swap partition."
        swapfile="$SWAP_FILE_PATH"
        if swapon --show=NAME | grep -q "^$swapfile$"; then
            log_error "Swap partition $swapfile is already active! Aborting."
            exit 1
        fi
        mkswap "$swapfile"
        swapon "$swapfile"
        warn_if_hdd "$swapfile"
    else
        local swapfile="$SWAP_FILE_PATH"
        if swapon --show=NAME | grep -q "^$swapfile$"; then
            log_error "Swapfile $swapfile is still active! Aborting."
            exit 1
        fi
        [ -f "$swapfile" ] && rm -f "$swapfile"

        local fs_type=$(df -T "$(dirname "$swapfile")" | tail -1 | awk '{print $2}')
        log_info "Filesystem type for swap: $fs_type"
        if [[ "$fs_type" == "zfs" || "$fs_type" == "nfs" || "$fs_type" == "btrfs" ]]; then
            log_info "Using truncate for $fs_type"
            truncate -s ${swap_mb}M "$swapfile"
        elif ! fallocate -l ${swap_mb}M "$swapfile" 2>/dev/null; then
            log_warning "fallocate failed. Using truncate..."
            truncate -s ${swap_mb}M "$swapfile"
            [ ! -f "$swapfile" ] && { log_warning "truncate failed. Falling back to dd with ionice."; ionice -c 3 dd if=/dev/zero of="$swapfile" bs=1M count=$swap_mb status=progress; }
        fi

        # === NEW: verify swap file size ===
        local actual_size=$(stat -c %s "$swapfile" 2>/dev/null || echo 0)
        local expected_size=$((swap_mb * 1024 * 1024))
        if [ "$actual_size" -ne "$expected_size" ]; then
            log_error "Swap file size mismatch! Expected ${expected_size}, got ${actual_size}. Cleaning up."
            rm -f "$swapfile"
            exit 1
        fi
        log_success "Created swap file (${swap_mb}MB) at $swapfile"

        chmod 600 "$swapfile"
        mkswap "$swapfile"
        swapon "$swapfile"
        warn_if_hdd "$(dirname "$swapfile")"

        # Add to fstab if not already present
        if ! grep -q "^$swapfile" /etc/fstab; then
            echo "$swapfile none swap sw 0 0" >> /etc/fstab
            log_info "Added $swapfile to /etc/fstab"
        fi
    fi

    create_zram_devices $zram_mb

    # ----- KERNEL PARAMETERS -----
    local swappiness=${SWAPPINESS:-auto}
    if [ "$swappiness" = "auto" ]; then
        swappiness=10
        [ $total_ram_mb -le 2048 ] && swappiness=20
        [ "${CONTAINER_ENV:-none}" != "none" ] && swappiness=15
    fi
    update_sysctl vm.swappiness "$swappiness"
    update_sysctl vm.vfs_cache_pressure "$VFS_CACHE_PRESSURE"
    sysctl -p

    create_zram_service
    create_health_check
    create_metrics_exporter

    log_success "Configuration completed"
}

# ========== MAIN ==========
main() {
    init_environment
    case "${1:-}" in
        --restore) [ -z "${2:-}" ] && { log_error "Backup path required"; exit 1; }; restore_backup "$2"; exit 0 ;;
        --uninstall) uninstall; exit 0 ;;
        --status) show_status; exit 0 ;;
        --force) FORCE_MODE=true; log_info "Force mode enabled" ;;
        --quiet) QUIET_MODE=true; log_info "Quiet mode enabled" ;;
        --dry-run) DRY_RUN=true; log_warning "DRY RUN MODE" ;;
        --help|-h)
            cat << EOF
ZRAM Optimizer v$VERSION

Usage: $0 [OPTIONS]

Options:
    --status            Show current status
    --restore <dir>     Restore from backup
    --uninstall         Completely remove
    --force             Skip confirmations (for automation)
    --quiet             Minimal output, only warnings/errors
    --dry-run           Test without changes
    --help              Show this help

Config: $CONFIG_FILE
Log: $LOG_FILE
EOF
            exit 0 ;;
    esac

    if [[ $EUID -ne 0 ]]; then
        log_error "Script must be run as root (use sudo)"
        exit 1
    fi

    check_dependencies
    load_config
    detect_container

    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    log_info "Detected RAM: ${total_ram_mb}MB"

    local sizes=$(calculate_sizes $total_ram_mb) || exit 1
    zram_mb=$(echo $sizes | cut -d' ' -f1)
    swap_mb=$(echo $sizes | cut -d' ' -f2)

    log_info "Planned: zRAM=${zram_mb}MB, Swap=${swap_mb}MB at $SWAP_FILE_PATH"

    [ "$DRY_RUN" = true ] && { log_warning "DRY RUN - No changes made"; exit 0; }

    if [ "$FORCE_MODE" != true ]; then
        read -p "Proceed with configuration? (y/n): " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Cancelled"; exit 0; }
    fi

    backup_dir="/root/zram-backup-$BACKUP_DATE"
    mkdir -p "$backup_dir"
    cp /etc/sysctl.conf "$backup_dir/" 2>/dev/null || true
    cp /etc/fstab "$backup_dir/" 2>/dev/null || true
    log_success "Backup saved to $backup_dir"

    configure_system
    show_status

    log_success "=== CONFIGURATION COMPLETE ==="
    log_info "Backup : $backup_dir"
    log_info "Log    : $LOG_FILE"
    log_info "Config : $CONFIG_FILE"

    if [ "$FORCE_MODE" != true ]; then
        read -p "Reboot now? (y/n): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && reboot
    else
        log_info "Skipping reboot prompt (force mode)."
    fi
}

main "$@"
