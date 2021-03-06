#!/usr/bin/env bash
RUN_ID="$RANDOM"
source init.sh

die() {
    local _ret=$2
    test -n "$_ret" || _ret=1
    test "$_PRINT_HELP" = yes && print_help >&2
    echo "$1" >&2
    exit ${_ret}
}

print_help() {
printf 'Usage: %s COMMAND [--name APP] [ARGUMENTS]\n' "$0"
printf "\t%s\n" " "
printf "\t%s\n" "Arguments:"
printf "\t%s\n" "--aws-key: access_key_id"
printf "\t%s\n" "--aws-secret: secret_access_key"
printf "\t%s\n" "--vault-pass: (optional) Vault password for acquiring Ansible secrets"
printf "\t%s\n" "--registry-user: Docker Hub username"
printf "\t%s\n" "--registry-pass: Docker Hub password"
printf "\t%s\n" "--force-new-cluster: Destroy existing Swarm and create a new one"
printf "\t%s\n" "--use-sssd: use SSSD"
printf "\t%s\n" "-h,--help: Prints help"
}

arg_required() {
    if test "$1" = "$2"; then
        test $# -lt 3 && die "Missing value for '$2'." 1
        echo "$3"
        shift
    else
        echo "$1"
    fi
}

_arg_aws_key=
_arg_aws_secret=
_arg_vault_pass=
_arg_registry_user=
_arg_registry_pass=
_arg_force_new_cluster=
_arg_use_sssd=

while test $# -gt 0; do
    _key="$1"
    case "$_key" in
           --aws-key|--aws-key=*)
            _arg_aws_key=$(arg_required "${_key##--aws-key=}" $1 "${2:-}") || die
        ;; --aws-secret|--aws-secret=*)
            _arg_aws_secret=$(arg_required "${_key##--aws-secret=}" $1 "${2:-}") || die
        ;; --vault-pass|--vault-pass=*)
            _arg_vault_pass=$(arg_required "${_key##--vault-pass=}" $1 "${2:-}") || die
        ;; --registry-user|--registry-user=*)
            _arg_registry_user=$(arg_required "${_key##--registry-user=}" $1 "${2:-}") || die
        ;; --registry-pass|--registry-pass=*)
            _arg_registry_pass=$(arg_required "${_key##--registry-pass=}" $1 "${2:-}") || die
        ;; --force-new-cluster|--force-new-cluster=*)
            _arg_force_new_cluster="1"
        ;; --use-sssd)
            _arg_use_sssd=true
        ;; -h|--help)
            print_help
            exit 0
        ;; *)
            _positionals+=("$1")
        ;;
    esac
    shift
done

exit_on_undefined "$_arg_aws_key" "--aws-key"
exit_on_undefined "$_arg_aws_secret" "--aws-secret"
exit_on_undefined "$_arg_vault_pass" "--vault-pass"
exit_on_undefined "$_arg_vault_pass" "--registry-user"
exit_on_undefined "$_arg_vault_pass" "--registry-pass"

check_env() {

R=$(command -v docker||true)
rg_status "$R" "Docker installed" "https://docs.docker.com/engine/installation/"

R=$(command -v python||true)
rg_status "$R" "Python installed" "brew install python / apt-get install python"

if [[ -n "$_arg_use_sssd" ]]; then
R=$(ssh -T git@github.com > /dev/null 2>&1)
rg_status "$(exit_code_ok $? 1)" "GitHub user configured"
fi

R=$(command -v aws||true)
rg_status "$R" "AWS CLI installed" "-> pip install awscli (requires Python)"

R=$(command -v jq||true)
rg_status "$R" "jq installed" "-> brew install jq / apt-get install jq"

R=$(cat ~/.aws/credentials|cat ~/.aws/credentials|grep -a2 $AWS_PROFILE|grep aws_access_key_id)
rg_status "$R" "AWS credentials configured" "-> See installation.md"
}

yellow "Using Settings: $CDIR"
yellow "Check local configuration..."
check_env

yellow "Prepare AWS resources..."
( . ./prepare_aws.sh )

# ensure SSH_KEY is available
add_ssh_key_to_agent "$SSH_KEY"

NODE_LIST="$(node_list)"
AWS_KEY="$_arg_aws_key"
AWS_SECRET="$_arg_aws_secret"
SECURITY_GROUPS="$TAG"
VAULT_PASS="$_arg_vault_pass"
REGISTRY_USER="$_arg_registry_user"
REGISTRY_PASS="$_arg_registry_pass"

yellow "Create EC2 instances for Swarm..."
create_swarm_instances manager &
create_swarm_instances worker &
wait $(jobs -p)

NODE_LIST="$(node_list)"

if [[ -n "$NODE_LIST" ]]; then
    yellow "Checking instance connectivity health"
    for ip in ${NODE_LIST[@]}; do
        node_access_health "$ip" &
    done
    wait $(jobs -p)
fi

yellow "Update host basics..."
for ip in ${NODE_LIST[@]}; do
    ( HOST=$ip . ./prepare_host.sh ) &
done
wait $(jobs -p)

yellow "Prepare Elastic Load Balancer (ELB)..."
( . ./prepare_elb.sh )

yellow "Install Docker '$DOCKER_VERSION' on all Swarm instances..."
for ip in ${NODE_LIST[@]}; do
    ( HOST=$ip . ./prepare_docker.sh ) &
done
wait $(jobs -p)

yellow "Install REX-Ray '$REXRAY_VERSION' on all Swarm instances..."
# early config preparation to avoid mutating same config files in parallel
prepare_rexray_config
for ip in ${NODE_LIST[@]}; do
    ( HOST=$ip SKIP_REXCONF=y . ./prepare_rexray.sh ) &
done
wait $(jobs -p)

yellow "Install SSSD on all Swarm instances..."
if [[ -n "$_arg_use_sssd" ]]; then
    ( HOSTS="$NODE_LIST" . ./prepare_sssd.sh )
else
    yellow "...skipped"
fi

ec2_ssh_access_ok() {
    R=$(ssh $1 $(echo '{"command":"docker:ps"}'|b64enc) >/dev/null)
    rg_status "$(exit_code_ok $? 0)" "SSH access for $USER@$1"
}

if [[ -n "$_arg_use_sssd" ]]; then
for ip in ${NODE_LIST[@]}; do
    ec2_ssh_access_ok "$ip" &
done
wait $(jobs -p)
fi

yellow "Prepare RDS:Postgres"
( HOST="$(echo "$NODE_LIST"|head -n1)" . ./prepare_rds.sh )

yellow "Preparing restricted shell for users..."
( . ./prepare_restricted_shell.sh )

yellow "Configure Swarm Manager..."
SWARM_MANAGER_LIST="$(swarm_manager_instances|jq -r '.Reservations[].Instances[]|.PublicIpAddress')"
for ip in ${SWARM_MANAGER_LIST[@]}; do
    ( HOST="$ip" . ./prepare_manager.sh ) &
done
wait $(jobs -p)

yellow "Prepare Docker Swarm..."
( FORCE_NEW_CLUSTER="$_arg_force_new_cluster" . ./prepare_swarm.sh )

MANAGER_IP=$(manager_ip)

yellow "Configure Swarm node labels"
cd ../client
HOST="$MANAGER_IP" configure_swarm_nodes
cd - 1>/dev/null

yellow "Prepare core services..."
( HOST="$MANAGER_IP" . ./prepare_core_services.sh )

## undefined RDS_HOST available only after prepare_rds
( . ./prepare_restricted_shell.sh )

yellow "Prepare ACL"
( HOST="$MANAGER_IP" . ./prepare_acl.sh )

yellow "EC2 instance availability..."
check_reachable "$DOMAIN"
check_reachable "$DOMAIN" 443
check_reachable "$(elb $ELB_NAME|jq_elb_dnsname)"
check_reachable "$(elb $ELB_NAME|jq_elb_dnsname)" 443

_IPS="$(swarm_manager_instances|jq -r '.Reservations[].Instances[]|.PublicIpAddress')"
for ip in ${_IPS[@]}; do
    R=$(is_reachable_via_curl "$ip")
    rg_status "$(exit_code_not_ok $? 0)" "$ip:80 is blocked"
done

_IPS="$(swarm_node_instances|jq -r '.Reservations[].Instances[]|.PublicIpAddress')"
for ip in ${_IPS[@]}; do
    R=$(is_reachable_via_curl "$ip")
    rg_status "$(exit_code_not_ok $? 0)" "$ip:80 is blocked"
done

yellow "Checking ELB instance health..."
HEALTH="$(aws elb describe-instance-health --load-balancer-name $ELB_NAME)"
for k in $(echo $HEALTH|jq -r '.InstanceStates[]|[.InstanceId,.State]|@csv'|tr '\n' ' '|sed 's/"//g'); do
    ELB_ID="$(echo $k|cut -f1 -d,)"
    ELB_ST="$(echo $k|cut -f2 -d,)"
    R=$(test "$ELB_ST" = "InService")
    rg_status "$(exit_code_ok $? 0)" "LB listener instance '$ELB_ID' is healthy"
done

yellow "Checking Swarm health..."
health_leader() {
    echo "$1"|grep Ready|grep Active|grep Leader
}
health_node() {
    echo "$1"|grep Ready|grep Active
}
NODE_HEALTH=$(run_user $MANAGER_IP <<EOF
docker node ls
EOF
)
R="$(health_leader "$NODE_HEALTH")"
N="$(echo $R|awk '{print $1}')"
rg_status "$(exit_code_ok $? 0)" "Swarm Manager '$N' is healthy"
while IFS= read -r line; do
    N="$(echo $line|awk '{print $1}')"
    R="$(health_node "$line")"
    rg_status "$(exit_code_ok $? 0)" "Swarm Node '$N' is healthy"
done <<< "$(echo "$NODE_HEALTH"|sed '1d'|grep -v Leader)";

yellow "Preparing CLI for users..."
( HOST="$MANAGER_IP" . ./prepare_cli.sh )
yellow "Cronjobs..."
( HOST="$MANAGER_IP" KEY=$SERVICE_LISTING_KEY . ./prepare_swarm_cronjobs.sh )

yellow "Preparing Secrets..."
( . ./prepare_secrets.sh )

yellow "Prepare futuswarm container..."
( . ./prepare_futuswarm_container.sh )

yellow "Prepare futuswarm-health container..."
( . ./prepare_futuswarm_health_container.sh )

do_post_install "${0##*/}"

FULL_LOG="$(install_log)"
green "Installation complete! Logs available at $FULL_LOG"
echo "Usage instructions at https://$DOMAIN"
RED_ISSUES="$(cat $FULL_LOG|grep ✘)"
if [[ -n "$RED_ISSUES" ]]; then
    echo ""
    yellow "The following issues might require your attention (you can re-run the installer to verify/fix issues):"
    echo "$RED_ISSUES"
fi
