#!/bin/sh
set -e

INSTALLER_DIR="/installer"
FACTORY_BIN="${INSTALLER_DIR}/factory.bin"

# ---- Factory layout offsets ----
FACTORY_BASE_OFF=$((0x00401000))
EEPROM_REL_OFF=$((0x4000))
EEPROM_LEN=$((0x1e00))
EEPROM_ABS_OFF=$((FACTORY_BASE_OFF + EEPROM_REL_OFF))
DSD_OFF=$((0x00400000))
DSD_LEN=$((0x00001000))

# ---- Temp paths ----
FACTORY_TMP="/tmp/factory-build"
EEPROM_DUMP="${FACTORY_TMP}/eeprom.bin"
DSD_BIN="${FACTORY_TMP}/dsd.bin"
DSD_STR="${FACTORY_TMP}/dsd.strings"
FACTORY_BLOB="${FACTORY_TMP}/factory.bin"

log() {
  printf '[installer] %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  if [ ! -f "$1" ]; then
    die "Missing required file: $1"
  fi
}

already_partitioned() {
  ubinfo /dev/ubi0 >/dev/null 2>&1
}

prompt_confirm() {
  printf 'Existing UBI layout detected. Proceed and overwrite? (yes/no)\n'
  read -r answer
  [ "$answer" = "yes" ]
}

ubi_mknod() {
  local dev="$1"
  dev="${dev##*/}"

  # If device node already exists, no need to create it
  [ -e "/dev/$dev" ] && return 0

  [ -e "/sys/class/ubi/$dev/uevent" ] || return 2
  source "/sys/class/ubi/$dev/uevent"
  mknod "/dev/$dev" c $MAJOR $MINOR
}

mac_valid() {
  echo "$1" | grep -Eq '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$'
}

mac_to_hex() {
  echo "$1" | tr -d :
}

str_to_hex() {
  # ASCII string to hex (no separators)
  printf '%s' "$1" | hexdump -v -e '1/1 "%02x"'
}

hex_to_bytes() {
  # hex string -> binary bytes
  echo "$1" | sed 's/../\\x&/g'
}

get_dsd_value() {
  key="$1"
  src="$2"
  grep -m1 "^${key}=" "$src" | cut -d= -f2-
}

detect_device() {
  case "$SERIAL_NUMBER" in
    W1700K*)
      DEV_MODEL="w1700k"
      ;;
    W1701K*)
      DEV_MODEL="w1701k"
      ;;
    XR1710G*)
      DEV_MODEL="xr1710g"
      ;;
    *)
      die "Unsupported device serial: $SERIAL_NUMBER"
      ;;
  esac

  RECOVERY_IMAGE="${INSTALLER_DIR}/openwrt-airoha-an7581-gemtek_${DEV_MODEL}-ubi-initramfs-recovery.itb"
  SYSUPGRADE_IMAGE="${INSTALLER_DIR}/openwrt-airoha-an7581-gemtek_${DEV_MODEL}-ubi-squashfs-sysupgrade.itb"
  log "Detected $DEV_MODEL via serial number."
}

get_factory_eeprom() {
  local init_off="$1"
  local eeprom_len="$2"
  local magic="$3"
  local eeprom_dump="$4"
  local ebs
  local off
  local skip
  local found

  [ -d "$FACTORY_TMP" ] || mkdir -p "$FACTORY_TMP"

  ebs="$(cat /sys/class/mtd/mtd0/erasesize)"
  off="$init_off"
  skip="$((init_off / ebs))"

  while [ $((off)) -lt $((init_off + 4 * ebs)) ]; do
    magic_read="$(hexdump -v -s "$off" -n 2 -e '"%02x"' /dev/mtd0)"
    if [ "$magic_read" = "$magic" ]; then
      found=1
      break
    fi
    off=$((off + ebs))
    skip=$((skip + 1))
  done

  if [ "$found" != "1" ]; then
    die "factory partition not found on raw flash offset"
  fi

  log "found factory partition at offset $(printf %08x $((off)))"
  dd if=/dev/mtd0 bs=1 skip="$off" count="$eeprom_len" of="$eeprom_dump"
}

get_factory_macs() {
  local dsd_off="$1"
  local dsd_len="$2"

  [ -d "$FACTORY_TMP" ] || mkdir -p "$FACTORY_TMP"

  dd if=/dev/mtd0 of="$DSD_BIN" bs=1 skip="$dsd_off" count="$dsd_len" 2>/dev/null
  strings "$DSD_BIN" > "$DSD_STR"

  WAN_MAC="$(get_dsd_value wan_mac "$DSD_STR")"
  LAN_MAC="$(get_dsd_value lan_mac "$DSD_STR")"
  FAN_ID="$(get_dsd_value fan_id "$DSD_STR")"
  SERIAL_NUMBER="$(get_dsd_value serial_number "$DSD_STR")"
}

build_factory_volume() {
  local eeprom_bin="$1"
  local factory_bin_path="$2"
  local eeprom_size

  log "Rebuild factory volume as UBI"

  # ---- New factory blob layout ----
  FACTORY_SIZE=$((0x10000))
  EEPROM_DST_OFF=$((0x0))
  WAN_MAC_OFF=$((0x5000))
  LAN_MAC_OFF=$((0x6000))
  FAN_ID_OFF=$((0x7000))
  SERIAL_OFF=$((0x8000))

  require_file "$eeprom_bin"

  [ -n "$WAN_MAC" ] || die "wan_mac missing"
  [ -n "$LAN_MAC" ] || die "lan_mac missing"
  [ -n "$FAN_ID" ] || die "fan_id missing"
  [ -n "$SERIAL_NUMBER" ] || die "serial_number missing"

  mac_valid "$WAN_MAC" || die "wan_mac invalid: $WAN_MAC"
  mac_valid "$LAN_MAC" || die "lan_mac invalid: $LAN_MAC"

  log "DSD validation OK:"
  log "  wan_mac       = $WAN_MAC"
  log "  lan_mac       = $LAN_MAC"
  log "  fan_id        = $FAN_ID"
  log "  serial_number = $SERIAL_NUMBER"

  eeprom_size="$(wc -c < "$eeprom_bin")"

  log "Creating empty factory blob (${FACTORY_SIZE} bytes)..."
  dd if=/dev/zero of="$FACTORY_BLOB" bs=1 count="$FACTORY_SIZE" 2>/dev/null

  log "Copying EEPROM (len 0x$(printf %x $eeprom_size)) -> blob @0x0..."
  dd if="$eeprom_bin" of="$FACTORY_BLOB" bs=1 seek="$EEPROM_DST_OFF" count="$eeprom_size" conv=notrunc 2>/dev/null

  log "Writing WAN/LAN MACs as hex bytes..."
  WAN_HEX="$(mac_to_hex "$WAN_MAC")"
  LAN_HEX="$(mac_to_hex "$LAN_MAC")"
  printf "$(hex_to_bytes "$WAN_HEX")" | dd of="$FACTORY_BLOB" bs=1 seek="$WAN_MAC_OFF" conv=notrunc 2>/dev/null
  printf "$(hex_to_bytes "$LAN_HEX")" | dd of="$FACTORY_BLOB" bs=1 seek="$LAN_MAC_OFF" conv=notrunc 2>/dev/null

  log "Writing fan_id and serial_number as hex bytes..."
  FAN_HEX="$(str_to_hex "$FAN_ID")"
  SER_HEX="$(str_to_hex "$SERIAL_NUMBER")"
  printf "$(hex_to_bytes "$FAN_HEX")" | dd of="$FACTORY_BLOB" bs=1 seek="$FAN_ID_OFF" conv=notrunc 2>/dev/null
  printf "$(hex_to_bytes "$SER_HEX")" | dd of="$FACTORY_BLOB" bs=1 seek="$SERIAL_OFF" conv=notrunc 2>/dev/null

  log "Factory volume built at $FACTORY_BLOB ."
  cp "$FACTORY_BLOB" "$factory_bin_path"
}

install_prepare_ubi() {
  mtddev="$1"

  log "Formatting NAND and creating UBI volumes on $mtddev..."
  [ -e /sys/class/ubi/ubi0 ] && ubidetach -p "$mtddev"

  ubiformat "$mtddev"
  ubiattach -p "$mtddev"
  sync
  sleep 1

  [ -e /dev/ubi0 ] || ubi_mknod ubi0

  ubimkvol /dev/ubi0 -n 0 -s 126976 -N ubootenv
  ubi_mknod ubi0_0
  ubimkvol /dev/ubi0 -n 1 -s 126976 -N ubootenv2
  ubi_mknod ubi0_1
}

install_write_factory() {
  local factory_bin_path="$1"

  ubimkvol /dev/ubi0 -n 2 -t static -s "$(wc -c < "$factory_bin_path")" -N factory
  ubi_mknod ubi0_2
  ubiupdatevol /dev/ubi0_2 "$factory_bin_path"
  sync
  sleep 1
}

install_write_recovery() {
  recovery_image="$1"

  ubimkvol /dev/ubi0 -n 3 -s "$(wc -c < "$recovery_image")" -N recovery
  ubi_mknod ubi0_3
  ubiupdatevol /dev/ubi0_3 "$recovery_image"
  sync
  sleep 1
}

install_write_openwrt() {
  ubimkvol /dev/ubi0 -n 4 -s 126976 -N fit
  ubi_mknod ubi0_4

  # Load OpenWrt upgrade helpers only when needed
  . /lib/functions.sh
  . /lib/upgrade/common.sh
  . /lib/upgrade/nand.sh
  . /lib/upgrade/fit.sh

  export CI_KERNPART=fit CI_UBIPART=ubi

  log "Installing sysupgrade image via nand_upgrade_fit..."
  nand_upgrade_fit "$1" cat
}

log "Generating factory.bin on device..."
get_factory_eeprom "$EEPROM_ABS_OFF" "$EEPROM_LEN" "7990" "$EEPROM_DUMP"
get_factory_macs "$DSD_OFF" "$DSD_LEN"
detect_device

require_file "$RECOVERY_IMAGE"
require_file "$SYSUPGRADE_IMAGE"

if already_partitioned; then
  if ! prompt_confirm; then
    log "User aborted."
    exit 0
  fi
fi

build_factory_volume "$EEPROM_DUMP" "$FACTORY_BIN"
require_file "$FACTORY_BIN"

install_prepare_ubi /dev/mtd2
install_write_factory "$FACTORY_BIN"
install_write_recovery "$RECOVERY_IMAGE"
install_write_openwrt "$SYSUPGRADE_IMAGE"

sync
sleep 5

log "Install complete. Rebooting..."

reboot
