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
# ISO_HTTP_BASE — for the informational log line + the iDRAC virtual-media
# mount URL's shape. Hostname-based ON PURPOSE: this is fetched by iDRAC's
# own firmware over the management network, which has real DNS, unlike the
# installer environment (see KS_FETCH_HTTP_BASE below). Not used for
# inst.ks= — do not reuse this for that.
ISO_HTTP_BASE="http://lmrg34ga.prod.pncint.net/PNC/installs/kickstart/SERVERS/tmpiso"
# KS_FETCH_HTTP_BASE — for inst.ks=, the URL the installer itself fetches
# the kickstart from mid-boot. MUST be IP-based (LMRG34GA_IP, common.sh) —
# no /etc/resolv.conf exists yet at that point, so lmrg34ga.prod.pncint.net
# will not resolve. Also note: NO "/PNC/installs" prefix here, unlike
# ISO_HTTP_BASE above — confirmed against legacy_isolinux.cfg /
# legacy_create_ks_rhel8_dell.sh, the IP vhost's docroot for this path
# is laid out differently than the hostname vhost's. Don't "align" the two
# without confirming with whoever owns lmrg34ga's web server config.
KS_FETCH_HTTP_BASE="http://${LMRG34GA_IP}/kickstart/SERVERS/tmpiso"

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
#
# LACP yes/no is evaluated via is_lacp_enabled() (common.sh) — same function
# kickstart_gen.sh's network_device_part() uses. Keeping this in one place
# means the boot-time network config (here) and the install-time network
# config (the .ks file) can never silently disagree about bonded vs.
# non-bonded for the same server.
#
# Two additions vs. the original legacy append line, both aimed at the same
# real-world failure mode: LACP negotiation (plus switch-side spanning-tree
# convergence, if the port isn't set to portfast/edge) can legitimately take
# well past the ~1s x 3-retry window Anaconda gives the one-shot kickstart
# fetch. If the link isn't fully up and routable yet, that fetch fails fast
# and permanently — it does not wait around for the network to finish
# coming up, it just gives up.
#   1. rd.net.timeout.ifup / rd.net.timeout.route — tell dracut's network
#      bring-up itself to wait longer for the interface and its route to be
#      ready BEFORE anaconda ever attempts the kickstart fetch, instead of
#      relying on the fetch's own short retry loop to paper over a network
#      that isn't ready yet. Generous, not exact — tune down once you've
#      confirmed real-world negotiation time on this switch/port config.
#   2. ksdevice=bond0 (bonded case only) — explicit, instead of
#      ksdevice=link. "ksdevice=link" tells Anaconda to use whichever
#      configured device gets carrier FIRST. During LACP negotiation, an
#      individual slave NIC commonly shows physical link/carrier before the
#      bond itself has finished aggregating — Anaconda can grab that slave
#      directly (which has no IP of its own; the address is on bond0) and
#      then fail to fetch anything over it. Naming bond0 explicitly makes
#      Anaconda wait for the actual device the ip= line configures.
build_kernel_append_line(){
  local ks_url="${KS_FETCH_HTTP_BASE}/${HOSTNAME_SHORT}/${HOSTNAME}.ks"
  # rd.net.timeout.carrier added on top of ifup/route: this is the knob that
  # actually matters for "link light is up but the switch isn't forwarding
  # yet" (e.g. spanning-tree listening/learning on a port without
  # portfast/edge-port set) — the failure mode confirmed on lmrg181a. ifup
  # and route only wait for local interface/route state, which is already
  # satisfied with a static ip= config; they don't wait for the switch to
  # actually start passing frames. carrier is the one that inserts real
  # wall-clock patience before Anaconda's one-shot kickstart fetch fires.
  # This is a workaround, not a fix — the real fix is portfast/edge-port on
  # the switch port itself; ask network team to confirm/set that.
  local net_timeouts="rd.net.timeout.carrier=60 rd.net.timeout.ifup=120 rd.net.timeout.route=90"
  if is_lacp_enabled "$LACP"; then
    log INFO "LACP='${LACP}' -> bonded boot params (bond0, ksdevice=bond0)"
    echo "initrd=initrd.img ramdisk_size=7497 ip=${IP}::${GATEWAY}:255.255.255.0:${HOSTNAME}:bond0:none bond=bond0:[${MAC}]:mode=802.3ad,lacp_rate=fast,miimon=100,xmit_hash_policy=layer2+3 ipv6.disable=1 ${net_timeouts} inst.ks=${ks_url} ksdevice=bond0 nompath kssendmac"
  else
    log INFO "LACP='${LACP}' -> non-bonded boot params (${NIC}, ksdevice=link)"
    echo "initrd=initrd.img ramdisk_size=7497 ip=${IP}::${GATEWAY}:255.255.255.0:${HOSTNAME}:${NIC}:none ifname=${NIC}:${MAC} ${net_timeouts} inst.ks=${ks_url} ksdevice=link kssendmac"
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

  log INFO "Kernel append line: ${append_line}"

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
