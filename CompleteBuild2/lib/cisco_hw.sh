#!/bin/bash
# =============================================================================
# cisco_hw.sh — Cisco / UCSM bring-up functions
#
# Ported from the old get_mac / add_vmedia scripts. Cisco doesn't need the
# racadm-style RAID/vdisk bring-up Dell does — physical disk layout and RAID
# policy live in the UCS service profile itself.
#
# Requires common.sh already sourced and HOSTNAME_SHORT set by the caller.
# =============================================================================

# get_mac_ucsm <ucsm_ip> <service_profile_name> <org_name>
# Prints the first vNIC MAC found in the service profile to stdout.
get_mac_ucsm(){
  local ucsm_ip="$1" profile="$2" org="$3"
  local out
  out=$(run_ucsm "$ucsm_ip" "scope org /${org};scope service-profile ${profile};show vnic")
  echo "$out" | awk '/Name/{f=1} f && /:/{print; exit}' \
    | grep -oE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | head -1
}

# get_boot_mode_ucsm <ucsm_ip> <service_profile_name> <org_name>
get_boot_mode_ucsm(){
  local ucsm_ip="$1" profile="$2" org="$3"
  run_ucsm "$ucsm_ip" "scope org /${org};enter service-profile ${profile};show boot-policy detail" \
    | grep -i "BootMode" | awk -F: '{print $2}' | tr -d ' '
}

# unbind_profile <ucsm_ip> <profile> <org>
# Detaches the service profile from its source template. The corresponding
# rebind happens in cleanup_ucsm_template() after the kickstart callback in
# the old flow, or here in the new flow right after post-install completes
# (see post_install.sh: cleanup_ucsm_template).
unbind_profile(){
  local ucsm_ip="$1" profile="$2" org="$3"
  log INFO "Unbinding service profile $profile from its template"
  run_ucsm "$ucsm_ip" "scope org /${org};enter service-profile ${profile};set src-templ-name \"\";commit-buffer" >/dev/null
}

# bind_template <ucsm_ip> <profile> <org> <template_name>
bind_template(){
  local ucsm_ip="$1" profile="$2" org="$3" template="$4"
  log INFO "Re-binding service profile $profile to template $template"
  run_ucsm "$ucsm_ip" "scope org /${org};enter service-profile ${profile};set src-templ-name ${template};commit-buffer" >/dev/null
}

# get_template_name <ucsm_ip> <profile> <org>
get_template_name(){
  local ucsm_ip="$1" profile="$2" org="$3"
  run_ucsm "$ucsm_ip" "scope org /${org};enter service-profile ${profile};show detail" \
    | grep -i "SourceTemplate" | awk -F: '{print $2}' | tr -d ' '
}

# create_and_mount_vmedia <ucsm_ip> <profile> <org>
# Creates a vmedia-policy named after the server pointing at its ISO, then
# attaches it to the service profile. Mirrors add_vmedia's vmedia() flow.
create_and_mount_vmedia(){
  local ucsm_ip="$1" profile="$2" org="$3"
  log INFO "Creating vmedia policy for $profile"
  # NOT CONFIRMED: remote-ip here needs lmrg34ga's real IP (UCSM's field
  # name suggests it can't take a hostname the way the Dell remoteimage
  # path now does). 100.64.1.101 was confirmed WRONG for the Dell path
  # (RAC0720 — "unable to locate... file or folder path... incorrect"), so
  # don't trust it here either without separately confirming the correct
  # value for lmrg34ga on the UCSM-reachable network.
  run_ucsm "$ucsm_ip" "scope org;enter org /${org};create vmedia-policy ${profile};create vmedia-mapping map${profile};set device-type cdd;set remote-ip 100.64.1.101;set image-file-name build_${profile}.iso;set image-path /PNC/installs/kickstart/SERVERS/tmpiso/${profile};set mount-protocol http;commit-buffer" >/dev/null
  sleep 3
  log INFO "Mounting vmedia policy onto service profile"
  run_ucsm "$ucsm_ip" "scope org;enter org /${org};enter service-profile ${profile} instance;set vmedia-policy ${profile};commit-buffer" >/dev/null
}

# reboot_server_ucsm <blade_slot> <ucsm_ip>
reboot_server_ucsm(){
  local slot="$1" ucsm_ip="$2"
  log INFO "Hard-reset-immediate on blade slot $slot"
  run_ucsm "$ucsm_ip" "scope server ${slot};reset hard-reset-immediate;commit-buffer" >/dev/null
}
