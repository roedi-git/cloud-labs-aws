#!/usr/bin/env bash
# AWS specific helpers. Source after lib/common.sh.

require aws
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
if [[ -n "${AWS_PROFILE:-}" ]]; then export AWS_PROFILE; fi

check_login() {
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "Not logged in to AWS. Run: aws login --remote"
}

account_id() { aws sts get-caller-identity --query Account --output text; }

# Some services (ECS Express Mode) call other services with the caller's
# credentials and reject the session of "aws login". Switch to a role that
# only the current user may assume; it gets the same rights as that user.
use_deployer_role() {   # use_deployer_role <lab>
  local role caller creds=
  role=$(name deployer)
  caller=$(aws sts get-caller-identity --query Arn --output text)
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "Creating IAM role $role ..."
    # shellcheck disable=SC2046
    aws iam create-role --role-name "$role" --tags $(aws_tags "$1") \
      --assume-role-policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{\"Effect\": \"Allow\", \"Principal\": {\"AWS\": \"$caller\"},
                        \"Action\": \"sts:AssumeRole\"}]}" >/dev/null
    aws iam attach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  fi
  # A new role takes a few seconds until STS knows it
  for _ in $(seq 12); do
    creds=$(aws sts assume-role --role-arn "arn:aws:iam::$(account_id):role/$role" \
      --role-session-name "$1" \
      --query '[Credentials.AccessKeyId, Credentials.SecretAccessKey, Credentials.SessionToken]' \
      --output text 2>/dev/null) && break
    sleep 5
  done
  [[ -n "$creds" ]] || die "Could not assume role $role."
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# Tags for "--tags" (S3, ECR, IAM ...) and for "--tag-specifications" (EC2)
aws_tags() { echo "Key=course,Value=$COURSE_TAG Key=lab,Value=$1"; }
tag_spec() {   # tag_spec <resource type> <lab> <name>
  echo "ResourceType=$1,Tags=[{Key=course,Value=$COURSE_TAG},{Key=lab,Value=$2},{Key=Name,Value=$3}]"
}

default_vpc() {
  local vpc
  vpc=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  [[ "$vpc" != "None" ]] || die "No default VPC in $AWS_REGION. Create one: aws ec2 create-default-vpc"
  echo "$vpc"
}

# Current Ubuntu 24.04 LTS image published by Canonical
ubuntu_ami() {   # ubuntu_ami [amd64|arm64]
  aws ssm get-parameter \
    --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/${1:-amd64}/hvm/ebs-gp3/ami-id" \
    --query Parameter.Value --output text
}

# Import the SSH public key once; prints the key pair name
ensure_key_pair() {   # ensure_key_pair <lab>
  local key
  key=$(name key)
  [[ -f "$SSH_PUBLIC_KEY" ]] || die "SSH key $SSH_PUBLIC_KEY not found. Create it in the WSL shell, not in the dev container: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
  if ! aws ec2 describe-key-pairs --key-names "$key" >/dev/null 2>&1; then
    aws ec2 import-key-pair --key-name "$key" --public-key-material "fileb://$SSH_PUBLIC_KEY" \
      --tag-specifications "$(tag_spec key-pair "$1" "$key")" >/dev/null
  fi
  echo "$key"
}

# Settings for tools/tofu.sh
tofu_provider_vars() { export TF_VAR_region="$AWS_REGION"; }
backend_key_arg() { echo "key=$1/terraform.tfstate"; }
