# WSL2 Docker GPU Support Configuration Guide

## Problem Description

When running Docker containers with the `--gpus all` flag in WSL2, the following error occurs:

```
docker: Error response from daemon: could not select device driver "" with capabilities: [[gpu]]
```

Although the `nvidia-smi` command displays GPU information correctly, Docker cannot access the GPU.

## Root Cause

The **NVIDIA Container Toolkit** is not installed or properly configured. While `nvidia-smi` working indicates that the Windows NVIDIA driver has been correctly passed through to WSL2, Docker requires additional container runtime tools to access the GPU.

## Solution

### Step 1: Add NVIDIA Container Toolkit Repository

```bash
# Get distribution info
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)

# Add GPG key
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Add package repository
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

> **Note**: If using Ubuntu 22.04 and the above commands fail to find the corresponding version, manually specify:
> ```bash
> distribution="ubuntu22.04"
> ```

### Step 2: Install NVIDIA Container Toolkit

```bash
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```

### Step 3: Configure Docker Runtime

```bash
sudo nvidia-ctk runtime configure --runtime=docker
```

### Step 4: Restart Docker Service

```bash
sudo systemctl restart docker
```

## Verification

Run the following command to verify that Docker can access the GPU:

```bash
sudo docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

If GPU information is displayed, the configuration is successful.

## Run Your Script Again

After configuration is complete, execute:

```bash
bash scripts/docker-tools/docker.sh run
```

## FAQ

### Q: Package not found during installation?

Ensure the repository has been added correctly, and try manually specifying the distribution variable:

```bash
distribution="ubuntu22.04"
```

### Q: Still getting errors after restarting Docker?

Try completely restarting WSL2:

```powershell
# Execute in Windows PowerShell
wsl --shutdown
```

Then reopen the WSL2 terminal.

## References

- [NVIDIA Container Toolkit Official Documentation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [WSL2 GPU Support Documentation](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)