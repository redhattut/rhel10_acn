#!/bin/bash
# =============================================================================
# iso_gen.sh — assembles the bootable install ISO
#
# kickstart_gen.sh only produces the .ks *content*. Something still has to:
#   1. stage the actual RHEL installer boot binaries (vmlinuz, initrd.img,
#      isolinux.bin, boot.cat, ...) per RHEL major version + boot mode
#   2. drop the generated .ks file alongside them
#   3. write the isolinux.cfg (BIOS/Legacy) or EFI/BOOT/grub.cfg (UEFI) file
#      with the correct kernel append line — which is DIFFERENT depending on
#      whether the server uses LACP/bonding or a single NIC. This is the
#      "isolinux.cfg being variable based or not" piece.
#   4. run mkisofs to produce build_<host>.iso
#
# IMPORTANT TOPOLOGY NOTE: the installer boilerplate (TEMPLATE8, TEMPLATE8EFI,
# ...) and the tmpiso staging area live under /mnt/installs/kickstart/SERVERS
# on **lmrg34ga** — a different host from lmrg34ja, where build.sh/
# build_server.sh run. The old create_ks_rhel8_dell.sh/create_ks_rhel8_cisco.sh
# scripts lived there too and were invoked over SSH from build_a_dell.sh/
# build_a_cisco.sh. This module preserves that same hop rather than assuming
# everything is local to lmrg34ja.
# =============================================================================

ISO_HOST="lmrg34ga"
ISO_BASE="/mnt/installs/kickstart/SERVERS"
ISO_HTTP_BASE="http://lmrg34ga.prod.pncint.net/PNC/installs/kickstart/SERVERS/tmpiso"

# rhel_major() is defined in common.sh (shared with kickstart_gen.sh)

# template_dir_for <os_version> <boot_mode>
# e.g. (8.10, UEFI) -> TEMPLATE8EFI ; (9.8, Legacy) -> TEMPLATE9
template_dir_for(){
  local osver="$1" boot_mode="$2"
  local major; major=$(rhel_major "$osver")
  if [[ "$boot_mode" == "UEFI" ]]; then
    echo "TEMPLATE${major}EFI"
  else
    echo "TEMPLATE${major}"
  fi
}

# build_kernel_append_line
# Reproduces the two branches the original create_ks_rhel8_dell.sh had for
# LACP vs. non-LACP, using the *actual MAC address* in the bond= parameter
# for the bonded case (this is baked into the ISO at boot time, before the
# installed OS's NetworkManager config even exists — it has to be the MAC,
# not an interface name, since interface naming isn't guaranteed yet at this
# point in boot).
build_kernel_append_line(){
  local ks_url="${ISO_HTTP_BASE}/${HOSTNAME_SHORT}/${HOSTNAME}.ks"
  if [[ "$LACP" == "Yes" ]]; then
    echo "initrd=initrd.img ramdisk_size=7497 ip=${IP}::${GATEWAY}:255.255.255.0:${HOSTNAME}:bond0:none bond=bond0:[${MAC}]:mode=802.3ad,lacp_rate=fast,miimon=100,xmit_hash_policy=layer2+3 ipv6.disable=1 inst.ks=${ks_url} ksdevice=link nompath kssendmac"
  else
    echo "initrd=initrd.img ramdisk_size=7497 ip=${IP}::${GATEWAY}:255.255.255.0:${HOSTNAME}:${NIC}:none ifname=${NIC}:${MAC} inst.ks=${ks_url} ksdevice=link kssendmac"
  fi
}

# build_boot_iso <local_ks_path>
# Main entry point. Everything after this runs on lmrg34ga over SSH.
build_boot_iso(){
  local local_ks_path="$1"
  local tmpl_dir; tmpl_dir=$(template_dir_for "$OS_VERSION" "$BOOT_MODE")
  local remote_tmpiso="${ISO_BASE}/tmpiso/${HOSTNAME_SHORT}"
  local append_line; append_line=$(build_kernel_append_line)
  local major; major=$(rhel_major "$OS_VERSION")

  log STEP "Checking installer boilerplate for RHEL${major} / ${BOOT_MODE} on ${ISO_HOST}"
  if ! ssh $SSH_OPTS "$ISO_HOST" "[ -d '${ISO_BASE}/${tmpl_dir}' ]"; then
    die "Missing installer boilerplate: ${ISO_HOST}:${ISO_BASE}/${tmpl_dir} does not exist. \
Stage the RHEL${major} install media's vmlinuz/initrd.img/isolinux(.bin,.cfg)/boot.cat \
(and efiboot.img for the *EFI variant) there before building this OS version — see README."
  fi

  log INFO "Staging ${tmpl_dir} -> ${remote_tmpiso}"
  ssh $SSH_OPTS "$ISO_HOST" "
    rm -rf '${remote_tmpiso}'
    mkdir -p '${remote_tmpiso}'
    cp -r ${ISO_BASE}/${tmpl_dir}/* '${remote_tmpiso}/'
  " || die "Failed to stage installer boilerplate on ${ISO_HOST}"

  [[ -s "$local_ks_path" ]] || die "Local kickstart is empty or missing: $local_ks_path — generate_kickstart should have caught this; something is wrong upstream"

  log INFO "Copying generated kickstart to ${ISO_HOST}:${remote_tmpiso}/${HOSTNAME}.ks"
  scp $SSH_OPTS "$local_ks_path" "${ISO_HOST}:${remote_tmpiso}/${HOSTNAME}.ks" \
    || die "Failed to copy kickstart to ${ISO_HOST}"

  local remote_ks_size; remote_ks_size=$(ssh $SSH_OPTS "$ISO_HOST" "stat -c %s '${remote_tmpiso}/${HOSTNAME}.ks' 2>/dev/null || echo 0")
  if [[ "$remote_ks_size" -eq 0 ]]; then
    die "Kickstart copied to ${ISO_HOST}:${remote_tmpiso}/${HOSTNAME}.ks but landed empty (0 bytes) — scp reported success but the remote file is empty; check disk space / permissions on ${ISO_HOST}"
  fi

  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    log INFO "Writing EFI/BOOT/grub.cfg (UEFI boot)"
    local rhel_label="RHEL-${major} x86_64"
    ssh $SSH_OPTS "$ISO_HOST" "cat > '${remote_tmpiso}/EFI/BOOT/grub.cfg'" <<EOF
label ${HOSTNAME_SHORT}
menuentry 'Install Red Hat Enterprise Linux ${major}' --class fedora --class gnu-linux --class gnu --class os {
	linuxefi /images/pxeboot/vmlinuz ${append_line}
	initrdefi /images/pxeboot/initrd.img
}
EOF
  else
    log INFO "Writing isolinux.cfg (Legacy/BIOS boot)"
    ssh $SSH_OPTS "$ISO_HOST" "cat > '${remote_tmpiso}/isolinux.cfg'" <<EOF
default ${HOSTNAME_SHORT}
prompt 1
timeout 5
display boot.msg

label ${HOSTNAME_SHORT}
  kernel vmlinuz
  append ${append_line}
EOF
  fi

  log INFO "Running mkisofs on ${ISO_HOST}"
  local iso_out="${remote_tmpiso}/build_${HOSTNAME_SHORT}.iso"
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    ssh $SSH_OPTS "$ISO_HOST" "cd '${remote_tmpiso}' && mkisofs -U -A '${rhel_label:-RHEL-${major} x86_64}' -V '${rhel_label:-RHEL-${major} x86_64}' -volset '${rhel_label:-RHEL-${major} x86_64}' -J -joliet-long -r -v -T -o '${iso_out}' -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot . >/dev/null 2>&1" \
      || die "mkisofs (UEFI) failed on ${ISO_HOST}"
  else
    ssh $SSH_OPTS "$ISO_HOST" "cd '${remote_tmpiso}' && mkisofs -J -R -v -T -V KickStart -o '${iso_out}' -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-in . >/dev/null 2>&1" \
      || die "mkisofs (Legacy) failed on ${ISO_HOST}"
  fi

  log INFO "ISO built: ${ISO_HOST}:${iso_out}"
  log INFO "iDRAC will mount it from: ${ISO_HTTP_BASE}/${HOSTNAME_SHORT}/build_${HOSTNAME_SHORT}.iso"
}
