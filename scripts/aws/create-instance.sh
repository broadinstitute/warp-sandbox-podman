#!/usr/bin/env bash
# scripts/aws/create-instance.sh — create (or find) the shared sandbox host on AWS EC2.
#
# Run it from your laptop, NOT from the VM, with credentials for the target
# account:
#
#     AWS_PROFILE=<profile> ./scripts/aws/create-instance.sh
#
# Idempotent. Each resource is looked up by its Name tag first and created only
# when missing, so a re-run after a partial failure continues where it stopped,
# and a re-run against a finished deployment just prints its details.
#
# What it creates, and why:
#
#   security group  <name>-ssh   SSH (tcp/22) only from the Broad's address
#                                ranges: the same ranges the GCP org firewall
#                                admitted. Add your own (e.g. a home IP) with
#                                SANDBOX_EXTRA_SSH_CIDRS="203.0.113.7/32".
#   key pair        <name>-admin Your public key, for the AMI's default `admin`
#                                account only. That is the one sudo account.
#                                Sandbox users get local accounts with no sudo
#                                (scripts/add-sandbox-user.sh).
#   EBS volume      <name>-data  The data disk: encrypted gp3, created on its
#                                own and NEVER deleted with the instance. The
#                                AWS equivalent of the GCP `auto-delete=no` disk:
#                                every user's state, the checkout and the image
#                                store live here, so rebuilding the VM loses
#                                nothing.
#   instance        <name>       Debian 13 (podman 5.4, the verified platform).
#                                NO IAM instance profile, so the metadata service
#                                holds no cloud credential an agent could take
#                                (the GCP equivalent was --no-service-account).
#                                IMDSv2 required. 50 GB encrypted gp3 root.
#   Elastic IP      <name>-ip    A stable address across stop/start and rebuilds.
#
# Everything is tunable by environment variable; see the defaults below.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
NAME="${SANDBOX_NAME:-warp-claude-sandbox-3}"
# 8 vCPU / 64 GiB, the same shape as the GCP e2-highmem-8 it replaces.
# m6a.2xlarge (8 vCPU / 32 GiB) is the same PRICE instead; on AWS a type change
# is a stop / modify-instance-attribute / start, so this is easy to revisit.
INSTANCE_TYPE="${SANDBOX_INSTANCE_TYPE:-r6a.2xlarge}"
ROOT_GB="${SANDBOX_ROOT_GB:-50}"
DATA_GB="${SANDBOX_DATA_GB:-200}"
KEY_NAME="${SANDBOX_KEY_NAME:-${NAME}-admin}"
ADMIN_PUBKEY="${SANDBOX_ADMIN_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
SUBNET_ID="${SANDBOX_SUBNET_ID:-}"
AMI_ID="${SANDBOX_AMI_ID:-}"

# The Broad's public ranges, copied from the org-level GCP firewall policy that
# allowed tcp:22 to warp-claude-sandbox-2 (gcloud compute instances
# network-interfaces get-effective-firewalls). The Broad VPN egresses from them too.
BROAD_CIDRS="69.173.64.0/19 69.173.96.0/24 69.173.97.0/25 69.173.97.128/26
69.173.97.192/27 69.173.98.0/23 69.173.100.0/22 69.173.104.0/22 69.173.108.0/22
69.173.112.0/21 69.173.120.0/22 69.173.124.0/23 69.173.126.0/24 69.173.127.0/25
69.173.127.128/26 69.173.127.192/27 69.173.127.240/28"
SSH_CIDRS="${SANDBOX_SSH_CIDRS:-$BROAD_CIDRS}"
EXTRA_SSH_CIDRS="${SANDBOX_EXTRA_SSH_CIDRS:-}"

# Official Debian cloud-team AWS account (https://wiki.debian.org/Cloud/AmazonEC2Image).
DEBIAN_AMI_OWNER=136693071363

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ec2() { aws --region "$REGION" ec2 "$@"; }
# Tags every resource carries, so they are findable and attributable.
tags() { # $1 = resource type, $2 = Name
    printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=sandbox,Value=%s},{Key=managed-by,Value=warp-sandbox-podman}]' \
        "$1" "$2" "$NAME"
}
none_to_empty() { [[ "$1" == "None" || "$1" == "null" ]] && echo "" || echo "$1"; }

command -v aws >/dev/null || die "aws CLI not found."
command -v jq  >/dev/null || die "jq not found."
ident=$(aws sts get-caller-identity --query Arn --output text) \
    || die "no working AWS credentials (set AWS_PROFILE)."
alias_=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || true)
say "AWS identity: ${ident} (account alias: ${alias_:-none}), region ${REGION}"

# ------------------------------------------------------------------ network --
VPC_ID=$(none_to_empty "$(ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)")
if [[ -n "$SUBNET_ID" ]]; then
    VPC_ID=$(ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
fi
[[ -n "$VPC_ID" ]] || die "no default VPC in ${REGION}; set SANDBOX_SUBNET_ID to a public subnet."

# The data volume pins the availability zone: an EBS volume can only attach to an
# instance in its own AZ. So if it already exists, the instance goes where it is.
VOL_ID=$(none_to_empty "$(ec2 describe-volumes \
    --filters "Name=tag:Name,Values=${NAME}-data" "Name=status,Values=available,in-use,creating" \
    --query 'Volumes[0].VolumeId' --output text)")
if [[ -n "$VOL_ID" ]]; then
    AZ=$(ec2 describe-volumes --volume-ids "$VOL_ID" --query 'Volumes[0].AvailabilityZone' --output text)
fi

if [[ -z "$SUBNET_ID" ]]; then
    offered=$(ec2 describe-instance-type-offerings --location-type availability-zone \
        --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
        --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort)
    [[ -n "$offered" ]] || die "${INSTANCE_TYPE} is not offered in any AZ of ${REGION}."
    for az in ${AZ:-$offered}; do
        SUBNET_ID=$(none_to_empty "$(ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=availability-zone,Values=${az}" \
                      "Name=default-for-az,Values=true" \
            --query 'Subnets[0].SubnetId' --output text)")
        [[ -n "$SUBNET_ID" ]] && { AZ="$az"; break; }
    done
    [[ -n "$SUBNET_ID" ]] || die "no default subnet in a suitable AZ; set SANDBOX_SUBNET_ID."
fi
AZ=$(ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)
say "VPC ${VPC_ID}, subnet ${SUBNET_ID} (${AZ})"

# -------------------------------------------------------------------- AMI ----
if [[ -z "$AMI_ID" ]]; then
    AMI_ID=$(ec2 describe-images --owners "$DEBIAN_AMI_OWNER" \
        --filters 'Name=name,Values=debian-13-amd64-*' 'Name=architecture,Values=x86_64' \
                  'Name=state,Values=available' \
        --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)
fi
read -r AMI_NAME ROOT_DEV < <(ec2 describe-images --image-ids "$AMI_ID" \
    --query 'Images[0].[Name,RootDeviceName]' --output text)
say "AMI ${AMI_ID} (${AMI_NAME}), root device ${ROOT_DEV}"

# --------------------------------------------------------------- key pair ----
if ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    say "key pair ${KEY_NAME}: exists"
else
    [[ -r "$ADMIN_PUBKEY" ]] || die "admin public key not found: ${ADMIN_PUBKEY} (set SANDBOX_ADMIN_PUBKEY)."
    ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "fileb://${ADMIN_PUBKEY}" \
        --tag-specifications "$(tags key-pair "$KEY_NAME")" >/dev/null
    say "key pair ${KEY_NAME}: imported from ${ADMIN_PUBKEY}"
fi

# --------------------------------------------------------- security group ----
SG_NAME="${NAME}-ssh"
SG_ID=$(none_to_empty "$(ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text)")
if [[ -z "$SG_ID" ]]; then
    SG_ID=$(ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
        --description "SSH to ${NAME} from Broad ranges" \
        --tag-specifications "$(tags security-group "$SG_NAME")" \
        --query GroupId --output text)
    say "security group ${SG_NAME}: created ${SG_ID}"
else
    say "security group ${SG_NAME}: exists ${SG_ID}"
fi
add_ssh_rule() { # $1 = CIDR, $2 = description
    local perm out
    perm=$(jq -nc --arg c "$1" --arg d "$2" \
        '[{IpProtocol:"tcp",FromPort:22,ToPort:22,IpRanges:[{CidrIp:$c,Description:$d}]}]')
    if out=$(ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions "$perm" 2>&1); then
        note "ssh allowed from $1 ($2)"
    elif grep -q 'InvalidPermission.Duplicate' <<<"$out"; then
        :
    else
        die "could not add SSH rule for $1: $out"
    fi
}
for c in $SSH_CIDRS; do add_ssh_rule "$c" "Broad"; done
for c in $EXTRA_SSH_CIDRS; do add_ssh_rule "$c" "extra, added $(date +%F)"; done

# ------------------------------------------------------------ data volume ----
if [[ -z "$VOL_ID" ]]; then
    VOL_ID=$(ec2 create-volume --availability-zone "$AZ" --size "$DATA_GB" \
        --volume-type gp3 --encrypted \
        --tag-specifications "$(tags volume "${NAME}-data")" \
        --query VolumeId --output text)
    ec2 wait volume-available --volume-ids "$VOL_ID"
    say "data volume ${NAME}-data: created ${VOL_ID} (${DATA_GB} GB gp3, encrypted)"
else
    say "data volume ${NAME}-data: exists ${VOL_ID}"
fi

# --------------------------------------------------------------- instance ----
IID=$(none_to_empty "$(ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)")
if [[ -z "$IID" ]]; then
    bdm=$(jq -nc --arg d "$ROOT_DEV" --argjson s "$ROOT_GB" \
        '[{DeviceName:$d,Ebs:{VolumeSize:$s,VolumeType:"gp3",Encrypted:true,DeleteOnTermination:true}}]')
    # cloud-init sets a recognisable hostname. Nothing secret goes in user-data:
    # it is readable from the metadata service.
    userdata=$(printf '#cloud-config\nhostname: %s\nfqdn: %s\npreserve_hostname: false\n' "$NAME" "$NAME")
    IID=$(ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
        --block-device-mappings "$bdm" \
        --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
        --user-data "$userdata" \
        --tag-specifications "$(tags instance "$NAME")" "$(tags volume "${NAME}-root")" \
        --query 'Instances[0].InstanceId' --output text)
    say "instance ${NAME}: launched ${IID} (${INSTANCE_TYPE})"
else
    say "instance ${NAME}: exists ${IID}"
fi
ec2 wait instance-running --instance-ids "$IID"

attached_to=$(none_to_empty "$(ec2 describe-volumes --volume-ids "$VOL_ID" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)")
if [[ -z "$attached_to" ]]; then
    ec2 attach-volume --volume-id "$VOL_ID" --instance-id "$IID" --device /dev/sdf >/dev/null
    ec2 wait volume-in-use --volume-ids "$VOL_ID"
    say "data volume attached to ${IID}"
elif [[ "$attached_to" != "$IID" ]]; then
    die "data volume ${VOL_ID} is attached to another instance (${attached_to}). Detach it first."
fi

# ------------------------------------------------------------- Elastic IP ----
ALLOC_ID=$(none_to_empty "$(ec2 describe-addresses --filters "Name=tag:Name,Values=${NAME}-ip" \
    --query 'Addresses[0].AllocationId' --output text)")
if [[ -z "$ALLOC_ID" ]]; then
    ALLOC_ID=$(ec2 allocate-address --domain vpc \
        --tag-specifications "$(tags elastic-ip "${NAME}-ip")" \
        --query AllocationId --output text)
    say "Elastic IP allocated ${ALLOC_ID}"
fi
assoc=$(none_to_empty "$(ec2 describe-addresses --allocation-ids "$ALLOC_ID" \
    --query 'Addresses[0].InstanceId' --output text)")
if [[ "$assoc" != "$IID" ]]; then
    ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$IID" >/dev/null
fi
PUBLIC_IP=$(ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)

# The data disk's stable name on the VM. Nitro instances expose EBS volumes as
# NVMe devices whose order is not guaranteed; the by-id path embeds the volume ID.
DATA_DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_ID/-/}"

cat <<EOF

$(say "done")
    instance     ${IID}  ${INSTANCE_TYPE}  ${AZ}
    public IP    ${PUBLIC_IP}   (Elastic IP ${ALLOC_ID})
    data volume  ${VOL_ID}  -> ${DATA_DEV}
    admin login  ssh admin@${PUBLIC_IP}      (key: ${KEY_NAME})

Next, from the checkout on your laptop (AWS.md, "Bootstrap the host"):

    ssh admin@${PUBLIC_IP} 'sudo bash -s -- --data-device ${DATA_DEV}' \\
        < scripts/setup-debian-host.sh
EOF
