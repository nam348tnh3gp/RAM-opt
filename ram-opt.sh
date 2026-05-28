#!/bin/bash
# ==================================================
#             Auto ZRAM+Swap Optimizer 
# ==================================================

set -euo pipefail

# ========== VERSION ==========
VERSION="3.1.1"
RELEASE_DATE="2026-05-28"

# ========== GLOBAL CONFIG ==========
LOG_FILE="/var/log/zram-optimizer.log"
CONFIG_FILE="/etc/zram-optimizer.conf"
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR="/usr/local/lib/zram-optimizer"
METRICS_PORT="${METRICS_PORT:-9100}"
DRY_RUN="${DRY_RUN:-false}"

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
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "========================================="
    echo "ZRAM Optimizer Suite v$VERSION"
    echo "Started at: $(date)"
    echo "========================================="
}

# ========== LOGGING ==========
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== UTILITY FUNCTIONS ==========
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

show_status() {
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
        local orig_size=$(cat /sys/block/zram0/orig_data_size 2>/dev/null)
        local compr_size=$(cat /sys/block/zram0/compr_data_size 2>/dev/null)
        if [ -n "$compr_size" ] && [ "$compr_size" -gt 0 ] 2>/dev/null; then
            local ratio=$(echo "scale=2; $orig_size / $compr_size" | bc 2>/dev/null || echo "0")
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

# ========== CONTAINER DETECTION ==========
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

# ========== DEPENDENCY CHECK ==========
check_dependencies() {
    local missing=()
    for cmd in free awk grep modprobe swapon swapoff bc systemctl; do
        if ! command -v $cmd &>/dev/null; then
            missing+=($cmd)
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing: ${missing[*]}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y bc util-linux systemd
        elif command -v dnf &>/dev/null; then
            dnf install -y bc util-linux systemd
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm bc util-linux systemd
        fi
    fi
    
    if ! modinfo zram &>/dev/null; then
        log_error "Kernel doesn't support zRAM!"
        exit 1
    fi
}

# ========== LOAD CONFIGURATION ==========
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
    VFS_CACHE_PRESSURE=${VFS_CACHE_PRESSURE:-50}
}

# ========== CHECK DISK SPACE ==========
check_disk_space() {
    local swap_mb=$1
    local available_kb=$(df --output=avail / | tail -1)
    local available_mb=$((available_kb / 1024))
    
    if [ $swap_mb -gt $available_mb ]; then
        log_warning "Need ${swap_mb}MB, have ${available_mb}MB"
        local new_swap_mb=$((available_mb - 512))
        [ $new_swap_mb -lt 512 ] && { log_error "Insufficient disk"; return 1; }
        echo $new_swap_mb
    else
        echo $swap_mb
    fi
}

# ========== CALCULATE SIZES ==========
calculate_sizes() {
    local ram_mb=$1
    local zram_mb=$((ram_mb * ZRAM_PERCENT / 100))
    [ $zram_mb -gt $MAX_ZRAM_MB ] && zram_mb=$MAX_ZRAM_MB
    
    local swap_mb=$(echo "$ram_mb * $SWAP_FACTOR" | bc | cut -d. -f1)
    [ $swap_mb -lt $MIN_SWAP_MB ] && swap_mb=$MIN_SWAP_MB
    [ $swap_mb -gt $MAX_SWAP_MB ] && swap_mb=$MAX_SWAP_MB
    
    swap_mb=$(check_disk_space $swap_mb) || return 1
    echo "$zram_mb $swap_mb"
}

# ========== SMART ALGORITHM ==========
select_best_algorithm() {
    [ "$ALGORITHM" != "auto" ] && { echo "$ALGORITHM"; return; }
    local cpu_cores=$(nproc)
    if [ $cpu_cores -ge 8 ]; then echo "zstd"
    elif [ $cpu_cores -ge 4 ]; then echo "lz4"
    else echo "lzo"
    fi
}

# ========== CREATE ZRAM DEVICES ==========
create_zram_devices() {
    local zram_mb=$1
    log_info "Creating $ZRAM_DEVICES zRAM device(s)..."
    
    swapoff /dev/zram* 2>/dev/null || true
    modprobe -r zram 2>/dev/null || true
    sleep 1
    
    modprobe zram num_devices=$ZRAM_DEVICES
    sleep 0.5
    
    for i in $(seq 0 $((ZRAM_DEVICES - 1))); do
        local dev_mb=$((zram_mb / ZRAM_DEVICES))
        [ $i -eq 0 ] && dev_mb=$((dev_mb + (zram_mb % ZRAM_DEVICES)))
        
        if [ -e "/sys/block/zram${i}/disksize" ]; then
            local algo=$(select_best_algorithm)
            echo $algo > /sys/block/zram${i}/comp_algorithm 2>/dev/null || true
            echo ${dev_mb}M > /sys/block/zram${i}/disksize
            mkswap /dev/zram${i} 2>/dev/null
            swapon /dev/zram${i} -p $((100 + i))
            log_success "zRAM$i: ${dev_mb}MB, $algo"
        fi
    done
}

# ========== CREATE SERVICES ==========
create_zram_service() {
    cat > "$SCRIPT_DIR/zram-setup.sh" << EOF
#!/bin/bash
modprobe zram num_devices=$ZRAM_DEVICES
sleep 0.5
for i in \$(seq 0 \$((ZRAM_DEVICES - 1))); do
    if [ -e "/sys/block/zram\${i}/disksize" ]; then
        echo ${zram_mb}M > /sys/block/zram\${i}/disksize
        mkswap /dev/zram\${i} 2>/dev/null
        swapon /dev/zram\${i} -p \$((100 + i))
    fi
done
EOF
    chmod +x "$SCRIPT_DIR/zram-setup.sh"
    
    cat > /etc/systemd/system/zram-setup.service << EOF
[Unit]
Description=ZRAM Setup
Before=swap.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/zram-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=swap.target
EOF
    systemctl daemon-reload
    systemctl enable zram-setup.service
}

create_health_check() {
    cat > "$SCRIPT_DIR/health-check.sh" << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/zram-health.log"
zram_usage=$(swapon --show=USED -no USED 2>/dev/null | head -1)
zram_total=$(swapon --show=SIZE -no SIZE 2>/dev/null | head -1)
if [ -n "$zram_total" ] && [ "$zram_total" != "0" ]; then
    percentage=$((zram_usage * 100 / zram_total))
    [ $percentage -gt 90 ] && echo "[WARN] $(date): zRAM ${percentage}%" >> "$LOG_FILE"
fi
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
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable zram-health.timer
}

create_metrics_exporter() {
    cat > "$SCRIPT_DIR/metrics-exporter.sh" << 'EOF'
#!/bin/bash
METRICS_FILE="/var/lib/node_exporter/zram.prom"
mkdir -p "$(dirname "$METRICS_FILE")"
while true; do
    for dev in /sys/block/zram*; do
        if [ -d "$dev" ]; then
            dev_name=$(basename "$dev")
            disksize=$(cat "$dev/disksize" 2>/dev/null || echo 0)
            orig_size=$(cat "$dev/orig_data_size" 2>/dev/null || echo 0)
            compr_size=$(cat "$dev/compr_data_size" 2>/dev/null || echo 0)
            cat > "$METRICS_FILE" << METRICS
zram_disksize_bytes{device="$dev_name"} $disksize
zram_orig_data_size_bytes{device="$dev_name"} $orig_size
zram_compr_data_size_bytes{device="$dev_name"} $compr_size
METRICS
        fi
    done
    sleep 60
done
EOF
    chmod +x "$SCRIPT_DIR/metrics-exporter.sh"
    
    cat > /etc/systemd/system/zram-metrics.service << EOF
[Unit]
Description=ZRAM Metrics
[Service]
Type=simple
ExecStart=$SCRIPT_DIR/metrics-exporter.sh
Restart=always
User=nobody
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable zram-metrics.service
}

# ========== RESTORE BACKUP ==========
restore_backup() {
    local backup_dir=$1
    [ ! -d "$backup_dir" ] && { log_error "Backup not found: $backup_dir"; return 1; }
    
    log_info "Restoring from $backup_dir..."
    swapoff -a 2>/dev/null || true
    modprobe -r zram 2>/dev/null || true
    
    [ -f "$backup_dir/sysctl.conf" ] && cp "$backup_dir/sysctl.conf" /etc/sysctl.conf && sysctl -p
    [ -f "$backup_dir/fstab" ] && cp "$backup_dir/fstab" /etc/fstab
    
    for svc in zram-setup zram-health.timer zram-metrics; do
        systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/zram-*.{service,timer}
    systemctl daemon-reload
    
    log_success "Restore completed. Please reboot."
}

# ========== UNINSTALL ==========
uninstall() {
    echo ""
    print_header "UNINSTALL ZRAM OPTIMIZER"
    read -p "Remove ZRAM Optimizer completely? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        return 0
    fi
    
    log_info "Removing ZRAM Optimizer..."
    
    # Turn off all swaps
    swapoff -a 2>/dev/null || true
    
    # Remove zRAM module
    modprobe -r zram 2>/dev/null || true
    
    # Disable and remove services
    for svc in zram-setup zram-health.timer zram-health zram-metrics; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/zram-*.{service,timer}
    
    # Remove files
    rm -rf "$SCRIPT_DIR"
    rm -f "$CONFIG_FILE"
    
    # Restore original configs if backups exist
    local latest_backup=$(ls -td /root/zram-backup-* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        read -p "Restore from latest backup? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            [ -f "$latest_backup/sysctl.conf" ] && cp "$latest_backup/sysctl.conf" /etc/sysctl.conf
            [ -f "$latest_backup/fstab" ] && cp "$latest_backup/fstab" /etc/fstab
            sysctl -p 2>/dev/null || true
            log_success "Restored from $latest_backup"
        fi
    fi
    
    systemctl daemon-reload
    log_success "Uninstall completed. Please reboot."
}

# ========== CONFIGURE SYSTEM ==========
configure_system() {
    log_info "Starting configuration..."
    
    systemctl stop zram-metrics zram-health.timer 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    
    # Create swap file
    local swapfile="/swapfile"
    [ -f "$swapfile" ] && rm -f "$swapfile"
    
    if fallocate -l ${swap_mb}M "$swapfile" 2>/dev/null; then
        log_success "Created swap file (${swap_mb}MB)"
    else
        dd if=/dev/zero of="$swapfile" bs=1M count=$swap_mb status=progress
    fi
    
    chmod 600 "$swapfile"
    mkswap "$swapfile"
    swapon "$swapfile"
    
    # Create zRAM
    create_zram_devices $zram_mb
    
    # Kernel parameters
    local swappiness=${SWAPPINESS:-auto}
    if [ "$swappiness" = "auto" ]; then
        swappiness=10
        [ $total_ram_mb -le 2048 ] && swappiness=20
        [ "${CONTAINER_ENV:-none}" != "none" ] && swappiness=15
    fi
    
    sed -i '/vm.swappiness=/d' /etc/sysctl.conf
    sed -i '/vm.vfs_cache_pressure=/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf << EOF
# ZRAM Optimizer v$VERSION - $BACKUP_DATE
vm.swappiness=$swappiness
vm.vfs_cache_pressure=$VFS_CACHE_PRESSURE
EOF
    sysctl -p
    
    # Auto-start
    grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    
    # Create services
    create_zram_service
    create_health_check
    create_metrics_exporter
    
    log_success "Configuration completed"
}

# ========== MAIN ==========
main() {
    init_environment
    
    case "${1:-}" in
        --restore)
            [ -z "${2:-}" ] && { log_error "Backup path required"; exit 1; }
            restore_backup "$2"
            exit 0
            ;;
        --uninstall)
            uninstall
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            log_warning "DRY RUN MODE"
            ;;
        --help|-h)
            cat << EOF
ZRAM Optimizer v$VERSION

Usage: $0 [OPTIONS]

Options:
    --status            Show current status
    --restore <dir>     Restore from backup
    --uninstall         Completely remove
    --dry-run           Test without changes
    --help              Show this help

Config: $CONFIG_FILE
Log: $LOG_FILE

Examples:
    sudo $0              # Auto-configure
    sudo $0 --status     # Check status
    sudo $0 --uninstall  # Remove completely
EOF
            exit 0
            ;;
    esac
    
    # Kiểm tra quyền root
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
    
    log_info "Planned: zRAM=${zram_mb}MB, Swap=${swap_mb}MB"
    
    if [ "$DRY_RUN" = true ]; then
        log_warning "DRY RUN - No changes made"
        exit 0
    fi
    
    read -p "Proceed with configuration? (y/n): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Cancelled"; exit 0; }
    
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
    
    read -p "Reboot now? (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && reboot
}

# ========== RUN ==========
main "$@"
