# rishabhroyy nixconf

This repository contains the completely declarative NixOS configuration for a highly stealthy Windows 11 VFIO hypervisor, featuring:
- Full AMD RX 6700 XT GPU & Audio Passthrough (Multifunction)
- NVMe, SATA SSD, and Motherboard USB Passthrough
- Tailscale-hardened Docker containers (Immich, Seanime, Portainer) with NVIDIA CUDA Support
- Seamless Host-Guest Power Sync
- Automated SOPS-Nix secret injection

### Deployment Instructions

The entire installation and bootstrapping process is documented step-by-step. 

**Please read and follow [DEPLOYMENT.md](./DEPLOYMENT.md) to install this system.**