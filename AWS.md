# Running the shared server on AWS (admin guide)

The shared sandbox runs on an EC2 instance, set up by four scripts instead of the
manual GCP procedure in [SERVER.md](SERVER.md). SERVER.md still explains *why*
each piece exists (the data disk, the shared image store, subuid ranges, the
1777 directories); this page is the AWS runbook. Nothing about the sandbox itself
is cloud-specific: the same Debian 13 + rootless podman host runs on either.

Deployed and verified on 2026-11-18: `warp-claude-sandbox-3` in `us-east-2`.

## What runs where

| Resource | Name tag | Notes |
|---|---|---|
| EC2 instance | `warp-claude-sandbox-3` | `r6a.2xlarge`: 8 vCPU / 64 GiB, AMD EPYC. Debian 13 (official Debian AMI). No IAM role. IMDSv2 only. |
| Root volume | `warp-claude-sandbox-3-root` | 50 GB gp3, encrypted, deleted with the instance. Holds `/home` and the OS only. |
| Data volume | `warp-claude-sandbox-3-data` | 200 GB gp3, encrypted, **not** deleted with the instance. `/mnt/sandbox`: every user's state, the checkout, the image store. |
| Elastic IP | `warp-claude-sandbox-3-ip` | The address users SSH to. Survives stop/start and rebuilds. |
| Security group | `warp-claude-sandbox-3-ssh` | tcp/22 from the Broad's ranges only, plus any CIDR added for the admin. |
| Key pair | `warp-claude-sandbox-3-admin` | The admin's key, for the AMI's `admin` account. The only account with sudo. |

**Cost**, on-demand in us-east-2: instance $0.4536/h (about $331/month if always
on), volumes $20/month, public IPv4 about $3.65/month: roughly **$355/month**. The
GCP `e2-highmem-8` it replaces was about $264/month plus disks. Both shapes are
8 vCPU / 64 GiB; `r6a` is AWS's cheapest current x86 type with that shape.
`m6a.2xlarge` (8 vCPU / 32 GiB, $0.3456/h) matches the old *price* instead, and
switching is cheap; see [Changing the instance type](#changing-the-instance-type).
Stopping the instance outside working hours stops the instance charge; volumes and
the IP are still billed.

## Access

Users SSH straight to the Elastic IP **from the Broad network or the Broad VPN**.
The security group admits the same ranges the GCP org firewall did. There is no
IAP equivalent configured: off-network without the VPN, you cannot connect.

```bash
ssh <user>@<elastic-ip>
```

Each person gets a **local account with no sudo**, made by
[`add-sandbox-user.sh`](#adding-a-user). That is SERVER.md's "route B", the
recommended way to run agents. On GCP every metadata-key user got sudo through
`google-sudoers`; here only `admin` has it. So users cannot read each other's
tokens, and an agent running as a user cannot either.

To admit an extra network, e.g. your home IP while off the VPN, add a /32:

```bash
aws ec2 authorize-security-group-ingress --region us-east-2 \
  --group-id <sg-id> --ip-permissions \
  'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=203.0.113.7/32,Description=admin-home}]'
```

`create-instance.sh` does the same through `SANDBOX_EXTRA_SSH_CIDRS`. Remove a
rule you no longer need with `revoke-security-group-ingress` and the same
arguments.

**Verifying the host key on first connect.** cloud-init prints the fingerprints
to the serial console, which you can read without connecting:

```bash
aws ec2 get-console-output --region us-east-2 --instance-id <id> --latest \
  --output text | grep -A4 'BEGIN SSH HOST KEY FINGERPRINTS'
```

Compare the ED25519 line with what `ssh` shows on first connect.

## Building it from nothing

All four steps are idempotent: re-running any of them after a failure continues
rather than duplicating.

### 1. Create the AWS resources, from your laptop

```bash
AWS_PROFILE=<profile> ./scripts/aws/create-instance.sh
```

Defaults: name `warp-claude-sandbox-3`, `us-east-2`, `r6a.2xlarge`, 50 GB root,
200 GB data, your `~/.ssh/id_ed25519.pub` as the admin key, the default VPC. Every
one is an environment variable at the top of the script (`SANDBOX_NAME`,
`AWS_REGION`, `SANDBOX_INSTANCE_TYPE`, `SANDBOX_DATA_GB`, `SANDBOX_ADMIN_PUBKEY`,
`SANDBOX_SUBNET_ID`, `SANDBOX_EXTRA_SSH_CIDRS`, ...). It prints the IP, the data
volume's stable device path, and the next command.

Choices worth knowing about:

* **No instance profile.** The metadata service is reachable from inside a rootless
  container (pasta opens ordinary host sockets for it, so the IMDSv2 hop limit
  does not stop it). An IAM role would be a cloud credential any agent could take.
  This is the AWS form of GCP's `--no-service-account --no-scopes`.
* **The data volume is created separately**, and the instance goes into the
  volume's availability zone, since EBS volumes only attach within their AZ.
* Nothing secret goes in user-data, which only sets the hostname. Any process
  that can reach the metadata service can read user-data.

### 2. Bootstrap the host

The script is self-contained, so it runs before the checkout exists:

```bash
ssh admin@<ip> 'sudo bash -s -- --data-device /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol<id>' \
  < scripts/setup-debian-host.sh
```

It installs the host packages (SERVER.md's table, plus `google-cloud-cli` and a
current `gh` from their vendors' apt repositories), a pinned and checksummed `uv`,
formats the data volume **only if it is blank**, mounts it by UUID with `nofail`,
creates `users/` and `plans/` (1777) and `reference/` (755), and clones the
checkout to `/mnt/sandbox/repo`, owned by `admin`. It also installs
`/usr/local/bin/sandbox` (a symlink into the checkout), a login hint, and, on EC2
only, an nftables rule rejecting the metadata service for every non-root uid.
Verified from an ordinary account: `curl 169.254.169.254` fails with
"Could not connect"; root, and cloud-init with it, still connect.

### 3. Build the image

```bash
ssh admin@<ip>
sudo systemd-run --unit=sandbox-image-build --collect \
  -p StandardOutput=truncate:/var/log/sandbox-image-build.log \
  -p StandardError=truncate:/var/log/sandbox-image-build.log \
  /mnt/sandbox/repo/scripts/build-shared-image.sh
sudo tail -f /var/log/sandbox-image-build.log
```

`systemd-run` keeps the build going if your SSH session drops; `truncate:` starts
the log afresh (`file:` would overwrite it in place, leaving the end of the
previous build's log after a shorter one). Plain
`sudo /mnt/sandbox/repo/scripts/build-shared-image.sh` works too. **While the
first build runs, users cannot use podman**: the store is root-only until the
build finishes and opens it up, and `podman` reports
`open .../imagestore/overlay-images/images.lock: permission denied`.

### 4. Add users

As in the next section, once per person.

## Adding a user

Ask for their SSH **public** key, then:

```bash
ssh admin@<ip>
sudo /mnt/sandbox/repo/scripts/add-sandbox-user.sh <username> - <<'EOF'
ssh-ed25519 AAAA... them@laptop
EOF
```

or `... add-sandbox-user.sh <username> their_key.pub`. It creates the account with
`useradd` (which allocates the subuid ranges rootless podman needs), installs the
key, enables linger, gives no sudo, and prints the two lines to send them:

```text
ssh <username>@<ip>
sandbox setup
```

Everything after that is theirs ([USER-SETUP.md](USER-SETUP.md)). Re-running it
with another key adds that key. A teammate's existing GCP key works here too: it is
just an SSH key (`~/.ssh/google_compute_engine.pub` on their laptop).

Removing an account is the same as on GCP ([SERVER.md](SERVER.md#removing-an-account)),
minus the metadata step.

## Updating the image

```bash
# laptop: bump the pins, review, test, commit, push
./scripts/bump-versions.sh            # what is newer
./scripts/bump-versions.sh --apply    # rewrite docker/Dockerfile
git diff; git commit -am "bump sandbox tools"; git push

# host
ssh admin@<ip>
cd /mnt/sandbox/repo && git pull && chmod -R a+rX .
sudo ./scripts/build-shared-image.sh          # or under systemd-run as above; a
                                              # cached rebuild takes about a minute
sudo ./scripts/build-shared-image.sh --prune  # reclaim the old image, ~9 GB
```

Users get the new image on their next launch, with no action of their own. A
change to `claude-sandbox-shared/` (settings, hooks, plugins) also needs each user
to run `sandbox update`, with no sandbox running.

## Changing the instance type

On AWS this is a stop and start, not a rebuild. Everything on both volumes stays:

```bash
aws ec2 stop-instances  --region us-east-2 --instance-ids <id>
aws ec2 wait instance-stopped --region us-east-2 --instance-ids <id>
aws ec2 modify-instance-attribute --region us-east-2 --instance-id <id> \
  --instance-type '{"Value": "m6a.2xlarge"}'
aws ec2 start-instances --region us-east-2 --instance-ids <id>
```

The Elastic IP stays attached. A GPU type (`g6.2xlarge`, one NVIDIA L4) is the
same operation, plus the driver and CDI steps in
[SERVER.md](SERVER.md#attaching-a-gpu).

## Rebuilding the VM

For a new Debian release, or a broken boot disk. The data volume carries every
user's state across, as on GCP:

```bash
aws ec2 terminate-instances --region us-east-2 --instance-ids <old-id>
aws ec2 wait instance-terminated --region us-east-2 --instance-ids <old-id>
AWS_PROFILE=<profile> ./scripts/aws/create-instance.sh   # finds the volume, IP, SG and key
ssh admin@<ip> 'sudo bash -s -- --data-device /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol<id>' \
  < scripts/setup-debian-host.sh                     # mounts the existing filesystem, formats nothing
```

Then re-add each user with `add-sandbox-user.sh`. It re-creates an account with
the **uid that owns the user's existing directory** on the data volume.
Otherwise `useradd` would hand out uids in whatever order you add people, and their
files would belong to someone else. The image store survives on the data volume,
so no rebuild is needed. Each user re-runs `sandbox setup`, which redoes only what
lived on the old boot disk: their gcloud and gh logins and their
`~/.config/containers/storage.conf`. Their agent sign-ins are on the data volume
and survive.

The host key changes with the new instance; verify it as above.

## Tearing it down

```bash
aws ec2 terminate-instances --region us-east-2 --instance-ids <id>
aws ec2 delete-volume       --region us-east-2 --volume-id <data-volume-id>   # ALL user data
aws ec2 release-address     --region us-east-2 --allocation-id <eipalloc-id>
aws ec2 delete-security-group --region us-east-2 --group-id <sg-id>
aws ec2 delete-key-pair     --region us-east-2 --key-name warp-claude-sandbox-3-admin
```

Snapshot the data volume first if anything on it might be wanted
(`aws ec2 create-snapshot --volume-id ...`).
