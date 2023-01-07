#!/bin/bash
# Assumes that the current environment is a privileged container
# with the host mounted at /run/host.  We can basically write
# whatever we want, however we can't actually *reboot* the host.
set -euo pipefail

sysroot=/run/host
# Current stable image fixture
image=quay.io/fedora/fedora-coreos:testing-devel
# An unchunked v1 image
old_image=quay.io/cgwalters/fcos:unchunked
imgref=ostree-unverified-registry:${image}
stateroot=testos

set -x

if test '!' -e "${sysroot}/ostree"; then
    ostree admin init-fs --modern "${sysroot}"
    ostree config --repo $sysroot/ostree/repo set sysroot.bootloader none
fi
if test '!' -d "${sysroot}/ostree/deploy/${stateroot}"; then
    ostree admin os-init "${stateroot}" --sysroot "${sysroot}"
fi
ostree-ext-cli container image deploy --sysroot "${sysroot}" \
    --stateroot "${stateroot}" --imgref "${imgref}"
ostree admin --sysroot="${sysroot}" status
ostree-ext-cli container image remove --repo "${sysroot}/ostree/repo" registry:"${image}"
ostree admin --sysroot="${sysroot}" undeploy 0
for img in "${image}" "${old_image}"; do
    ostree-ext-cli container image deploy --sysroot "${sysroot}" \
        --stateroot "${stateroot}" --imgref ostree-unverified-registry:"${img}"
    ostree admin --sysroot="${sysroot}" status
    ostree --repo="${sysroot}/ostree/repo" refs > initrefs.txt
    initial_refs=$(wc -l < initrefs.txt)
    ostree-ext-cli container image remove --repo "${sysroot}/ostree/repo" registry:"${img}"
    ostree --repo="${sysroot}/ostree/repo" refs > refs.txt
    pruned_refs=$(wc -l < refs.txt)
    # Removing the image should only drop the image reference, not its layers
    if test "$(($initial_refs - 1))" '!=' "$pruned_refs"; then
        cat refs.txt
        echo "unexpected ref count"
        exit 1
    fi
    ostree admin --sysroot="${sysroot}" undeploy 0
    # TODO: when we fold together ostree and ostree-ext, automatically prune layers
    ostree-ext-cli container image prune-layers --repo="${sysroot}/ostree/repo"
    ostree --repo="${sysroot}/ostree/repo" refs > refs.txt
    if test "$(wc -l < refs.txt)" -ne 0; then
        cat refs.txt
        echo "found refs"
        exit 1
    fi
done

# Verify we have systemd journal messages
nsenter -m -t 1 journalctl _COMM=ostree-ext-cli > logs.txt
grep 'layers stored: ' logs.txt

echo ok privileged integration
