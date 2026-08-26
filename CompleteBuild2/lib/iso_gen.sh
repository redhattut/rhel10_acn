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

# RHEL8_INSTALL_MEDIA_VERSION — the ONE RHEL 8.x install tree actually
# staged on lmrg34ga (TEMPLATE8/TEMPLATE8EFI) and mirrored at
# /PNC/distros/RHEL8.6-x86_64/ (see the kickstart templates' `url --url`
# line). This is NOT the same thing as $OS_VERSION from the CSV, which is
# the FINAL patched version GOMP/Satellite brings the server to
# post-install (build_server.sh passes $OS_VERSION to gomp_submit for
# exactly that reason, further down the pipeline) — a CSV row asking for
# 8.10 still installs from this same 8.6 media; GOMP is what actually gets
# it to 8.10 afterward. Anything describing the INSTALL ENVIRONMENT itself
# (the grub menu title, the volume label GRUB searches for) must use this
# constant, not $OS_VERSION — using $OS_VERSION there was a real bug,
# confirmed by a generated grub.cfg asking GRUB to search for a
# 'RHEL-8-10-0-BaseOS-x86_64' volume label that was never actually staged,
# only 'RHEL-8-6-0-BaseOS-x86_64' exists.
RHEL8_INSTALL_MEDIA_VERSION="8.6"

# RHEL9_INSTALL_MEDIA_VERSION — same idea as RHEL8_INSTALL_MEDIA_VERSION
# above, for the RHEL 9.x tree staged in TEMPLATE9/TEMPLATE9EFI (confirmed
# 9.6, mirrored at /PNC/distros/RHEL9.6-x86_64/, matching the `url --url`
# line in the RHEL9 kickstart templates).
RHEL9_INSTALL_MEDIA_VERSION="9.6"

# install_media_version_for <os_version>
# Picks the right *_INSTALL_MEDIA_VERSION constant by major version — the
# install media is always fixed per major version, never the CSV's exact
# target minor (see RHEL8_INSTALL_MEDIA_VERSION's comment above for why).
install_media_version_for(){
  local osver="$1"
  local major; major=$(rhel_major "$osver")
  case "$major" in
    8) echo "$RHEL8_INSTALL_MEDIA_VERSION" ;;
    9) echo "$RHEL9_INSTALL_MEDIA_VERSION" ;;
    *) die "No install media version defined for RHEL major version '${major}' (OS_VERSION=$osver)" ;;
  esac
}

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
#   ksdevice — explicit (bond0, or the target NIC name), instead of
#   ksdevice=link in either branch. "ksdevice=link" tells Anaconda to
#   use whichever configured device gets carrier FIRST — on a
#   multi-NIC box (this hardware has 6: onboard eno* ports plus the
#   add-in ens0/ens6f0/ens6f1 ports), that is not guaranteed to be the
#   one actually configured by ip=/ifname=. Confirmed on lmrg181a's
#   boot log: eno12409 got "NIC Link is up" before ens0 did — an
#   onboard port with no IP of its own winning the race against the
#   one we actually configured is exactly the kind of ambiguity that
#   produces "link is up but nothing works." Naming the device
#   explicitly removes the ambiguity entirely, for both branches.
build_kernel_append_line(){
  local ks_url="${KS_FETCH_HTTP_BASE}/${HOSTNAME_SHORT}/${HOSTNAME}.ks"
  # Simplified to match legacy's actual append line as closely as possible,
  # per explicit request after the LACP=Yes run got past the network stage
  # cleanly without needing any of this. Removed here: ipv6.disable=1,
  # nompath, and the rd.net.timeout.*/rd.route= additions from the earlier
  # switch-timing and missing-default-route investigations. initrd=initrd.img
  # is NOT removed globally — it's gone from THIS shared string, but the
  # Legacy/BIOS isolinux.cfg path (further down this file) needs it inline
  # (confirmed against legacy's own isolinux.cfg) since ISOLINUX has no
  # equivalent to GRUB2's separate `initrdefi` directive; that path now adds
  # it explicitly itself instead of relying on it being in this string.
  #
  # WORTH REMEMBERING if either of these symptoms comes back on a future
  # build — both were removed here, but were added in direct response to
  # confirmed failures, not speculatively, so they're the first things to
  # look at restoring rather than re-diagnosing from scratch:
  #   - rd.net.timeout.carrier/ifup/route: a switch port without
  #     portfast/edge-port set produced exactly "link's up but the
  #     kickstart fetch times out anyway."
  #   - rd.route=0.0.0.0/0:<gw>:<device>: a real run on lmrg181a had ip=
  #     correctly assign the address but never install ANY route — not
  #     even the local on-link one — leaving `curl` unable to reach
  #     anything at all.
  if is_lacp_enabled "$LACP"; then
    log INFO "LACP='${LACP}' -> bonded boot params (bond0, ksdevice=bond0)"
    echo "ramdisk_size=7497 ip=${IP}::${GATEWAY}:255.255.255.0:${HOSTNAME}:bond0:none bond=bond0:[${MAC}]:mode=802.3ad,lacp_rate=fast,miimon=100,xmit_hash_policy=layer2+3 inst.ks=${ks_url} ksdevice=bond0 inst.ks.sendmac"
  else
    log INFO "LACP='${LACP}' -> non-bonded boot params (${NIC}, ksdevice=${NIC})"
    echo "ramdisk_size=7497 ip=${IP}::${GATEWAY}:255.255.255.0:${HOSTNAME}:${NIC}:none ifname=${NIC}:${MAC} inst.ks=${ks_url} ksdevice=${NIC} inst.ks.sendmac"
  fi
}

# build_boot_iso <local_ks_path>
# Main entry point. Everything after this runs on lmrg34ga over SSH.
build_boot_iso(){
  local local_ks_path="$1"
  log_section "ISO build (on ${ISO_HOST})"
  local tmpl_dir; tmpl_dir=$(template_dir_for "$OS_VERSION" "$BOOT_MODE")
  local remote_tmpiso="${ISO_BASE}/tmpiso/${HOSTNAME_SHORT}"
  local append_line; append_line=$(build_kernel_append_line)
  local major; major=$(rhel_major "$OS_VERSION")
  local media_version; media_version=$(install_media_version_for "$OS_VERSION")
  local rhel_label="RHEL-${media_version//./-}-0-BaseOS-x86_64"

  log INFO "Kernel append line: ${append_line}"

  log INFO "Checking installer boilerplate for RHEL${major} / ${BOOT_MODE} on ${ISO_HOST}"
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
    # Full GRUB header + explicit `search --set=root`, matching legacy's
    # actual working grub.cfg structure exactly — confirmed against
    # lmrg182a's original legacy-generated grub.cfg (successful install).
    # The version this replaced wrote ONLY the bare label/menuentry block,
    # missing:
    #   - `search --no-floppy --set=root -l '<volume label>'` — tells GRUB
    #     which device/partition actually holds /images/pxeboot/vmlinuz,
    #     instead of relying on whatever $root happens to default to.
    #   - `set timeout=5` — with NO timeout configured at all, GRUB has no
    #     reason to ever proceed past the menu on its own. This alone
    #     explains "doesn't auto-start, have to press Enter" — confirmed
    #     directly against lmrg181a's boot screen, which never had a
    #     timeout in the first place.
    #   - the video/gfxpayload/insmod boilerplate — cosmetic (why the menu
    #     "looked nothing like legacy"), not functional, but worth
    #     matching anyway since it's exactly what's on the media already.
    # Volume label follows the real RHEL install media convention
    # (confirmed: lmrg182a's media used 'RHEL-8-6-0-BaseOS-x86_64') — built
    # from install_media_version_for() (the actual staged media for this
    # server's major version, e.g. always 8.6 for RHEL8), NOT $OS_VERSION
    # (the CSV's final GOMP-patched target, e.g. 8.10) — see
    # RHEL8_INSTALL_MEDIA_VERSION's definition above for why those are two
    # different things. Computed once at function scope above (shared with
    # the Legacy/BIOS branch and the mkisofs volume-label args below).
    ssh $SSH_OPTS "$ISO_HOST" "cat > '${remote_tmpiso}/EFI/BOOT/grub.cfg'" <<EOF
set default="0"

function load_video {
  insmod efi_gop
  insmod efi_uga
  insmod video_bochs
  insmod video_cirrus
  insmod all_video
}

load_video
set gfxpayload=keep
insmod gzio
insmod part_gpt
insmod ext2

set timeout=5
### END /etc/grub.d/00_header ###

search --no-floppy --set=root -l '${rhel_label}'

label ${HOSTNAME_SHORT}
menuentry 'Install Red Hat Enterprise Linux ${media_version}' --class fedora --class gnu-linux --class gnu --class os {
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
  append initrd=initrd.img ${append_line}
EOF
  fi

  log INFO "Running mkisofs on ${ISO_HOST}"
  local iso_out="${remote_tmpiso}/build_${HOSTNAME_SHORT}.iso"
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    ssh $SSH_OPTS "$ISO_HOST" "cd '${remote_tmpiso}' && mkisofs -U -A '${rhel_label}' -V '${rhel_label}' -volset '${rhel_label}' -J -joliet-long -r -v -T -o '${iso_out}' -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot . >/dev/null 2>&1" \
      || die "mkisofs (UEFI) failed on ${ISO_HOST}"
  else
    ssh $SSH_OPTS "$ISO_HOST" "cd '${remote_tmpiso}' && mkisofs -J -R -v -T -V KickStart -o '${iso_out}' -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-in . >/dev/null 2>&1" \
      || die "mkisofs (Legacy) failed on ${ISO_HOST}"
  fi

  log INFO "ISO built: ${ISO_HOST}:${iso_out}"
  log INFO "iDRAC will mount it from: ${ISO_HTTP_BASE}/${HOSTNAME_SHORT}/build_${HOSTNAME_SHORT}.iso"
}
