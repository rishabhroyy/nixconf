#!/usr/bin/env bash
# QEMU Libvirt Hook for Ghost-Host Power Sync
# This script is called by libvirtd on guest lifecycle events.
# Arguments provided by libvirt: $1=Guest_Name, $2=Lifecycle_Operation, $3=Sub_Operation, $4=Extra_Info

GUEST_NAME="$1"
OPERATION="$2"
SUB_OPERATION="$3"

if [ "$GUEST_NAME" == "win11" ]; then
    # Log the event for debugging
    echo "$(date): win11 $OPERATION $SUB_OPERATION" >> /tmp/qemu-hook.log
    
    if [[ "$OPERATION" == "stopped" || "$OPERATION" == "release" ]]; then
        # The Windows 11 guest has stopped.
        # We initiate a shutdown of the NixOS host to keep them fully synced.
        echo "Windows 11 guest $OPERATION. Syncing power off to NixOS host." | /run/current-system/sw/bin/systemd-cat -t qemu-hook
        /run/current-system/sw/bin/systemctl poweroff
    fi
fi
