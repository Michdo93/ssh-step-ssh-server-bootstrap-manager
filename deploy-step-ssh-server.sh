#!/usr/bin/env bash
# Scan an IPv4 range for SSH hosts and run step-ssh-server-bootstrap-kit on the selected devices:
# the SSH server then accepts SSH user certificates of your step-ca (TrustedUserCAKeys),
# optional principal mappings and local accounts are set up, and sshd is restarted safely.
#   https://github.com/Michdo93/step-ssh-server-bootstrap-kit
#
# Optionally every finished device is tested with a certificate login from this machine.
set -uo pipefail

readonly SSH_PORT="${SSH_PORT:-22}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"
readonly SCAN_PARALLEL="${SCAN_PARALLEL:-32}"

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in
      y|yes|j|ja) return 0 ;;
      n|no|nein) return 1 ;;
      '') [[ "$default" == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }
valid_name() { [[ "$1" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; }

# Prints the address if an SSH server answers. An authentication failure for a user that
# does not exist still proves that sshd is there. No host keys are stored while scanning.
# shellcheck disable=SC2317  # called through xargs/bash -c
probe_ssh() {
  local ip=$1 out
  out=$(timeout "$((CONNECT_TIMEOUT + 3))" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ssh-scan@$ip" true 2>&1) && { printf '%s\n' "$ip"; return; }
  case "$out" in
    *'Permission denied'*|*'Too many authentication failures'*|*'no mutual signature'*) printf '%s\n' "$ip" ;;
  esac
}

ask_range() {
  while true; do
    printf '\nEnter the first and last IPv4 address in the range.\n'
    read -r -p 'First address: ' first || exit 0
    read -r -p 'Last address:  ' last || exit 0
    first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
    last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
    (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
    (( last_n - first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
    if ask_yes_no "Scan ${first} through ${last}?" y; then break; fi
  done
}

# Fills the array "reachable" (sorted) with all addresses of the range that run sshd.
# shellcheck disable=SC2016  # $1 is expanded by the inner bash
scan_range() {
  local n
  printf '\nScanning for SSH services on TCP port %d (%d parallel probes)...\n' "$SSH_PORT" "$SCAN_PARALLEL"
  export -f probe_ssh
  export SSH_PORT CONNECT_TIMEOUT
  mapfile -t reachable < <(
    for ((n=first_n; n<=last_n; n++)); do int_to_ipv4 "$n"; printf '\n'; done |
      xargs -P "$SCAN_PARALLEL" -I{} bash -c 'probe_ssh "$1"' _ {} |
      sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
  if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
  printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"
}

# run_remote USER IP SCRIPT [ARG...]
# The POSIX-sh script is sent base64-encoded as the remote command, NOT on stdin. That way
# the remote terminal (-tt) is connected to the local keyboard: password prompts of sudo and
# questions of the script work, and the script text is never echoed back (an echoed script
# would contain its own result markers). Output is shown live and copied to $LOG.
# Returns the exit code of ssh (255 = connection/authentication failed).
run_remote() {
  local user=$1 ip=$2 script=$3 b64 cmd arg q="'"
  shift 3
  b64=$(printf '%s' "$script" | base64 | tr -d '\n')
  cmd="sh -c \"\$(echo $b64 | base64 -d)\" remote"
  for arg in "$@"; do cmd+=" '${arg//$q/$q\\$q$q}'"; done
  ssh -tt -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=15 \
    -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,keyboard-interactive,password \
    -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd" 2>&1 | tee "$LOG"
  return "${PIPESTATUS[0]}"
}

# Last result marker the remote script printed ("" if none).
remote_result() { grep -ao '@@RESULT:[A-Z_]*@@' "$LOG" | tail -n 1 | sed 's/^@@RESULT://; s/@@$//'; }

# with_login IP REMOTE_SCRIPT [ARG...] - asks for the user name and tries up to three
# logins. Sets "result" to the marker of the remote script, or LOGIN_FAILED / NO_RESULT.
with_login() {
  local ip=$1 rc attempt
  shift
  result=LOGIN_FAILED
  read -r -p "SSH username${last_user:+ [$last_user]}: " username || return 1
  username=${username:-$last_user}
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; result=SKIPPED; return 1; }
  last_user=$username
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    run_remote "$username" "$ip" "$@"; rc=$?
    result=$(remote_result)
    [[ -n "$result" ]] && return 0
    if (( rc != 255 )); then result=NO_RESULT; return 0; fi
    if grep -aq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$LOG"; then
      printf 'The host key of %s has changed. Verify the device, then remove the old key with: ssh-keygen -R %s\n' "$ip" "$ip"
      return 1
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  return 1
}

# cert_test IP -> 0 if every test account can log in with the certificate
cert_test() {
  local ip=$1 acc out ok=0
  for acc in "${test_accounts[@]}"; do
    if out=$(ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o IdentitiesOnly=yes -i "$test_key" -o CertificateFile="$test_key-cert.pub" \
        -o StrictHostKeyChecking=accept-new "$acc@$ip" 'id -un' 2>&1); then
      printf '  certificate login %-12s -> OK (%s)\n' "$acc@$ip" "$(printf '%s' "$out" | tail -n 1)"
    else
      printf '  certificate login %-12s -> FAILED: %s\n' "$acc@$ip" "$(printf '%s' "$out" | tail -n 1)"
      if [[ "$out" == *'Host key verification failed'* || "$out" == *'IDENTIFICATION HAS CHANGED'* ]]; then
        printf '  The host key of %s changed (e.g. Dropbear was replaced by OpenSSH). Verify it, then: ssh-keygen -R %s\n' "$ip" "$ip"
      elif [[ "$out" == *'Permission denied'* ]]; then
        printf '  Not allowed: does the account exist, and is the certificate principal accepted for it (map-principals.sh)?\n'
      fi
      ok=1
    fi
  done
  return "$ok"
}

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."
command -v base64 >/dev/null || die "The 'base64' command is required."
command -v xargs >/dev/null || die "The 'xargs' command is required."


INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/Michdo93/step-ssh-server-bootstrap-kit/main/install.sh}"

# Remote part (POSIX sh), arguments: installer URL, VAR=value words for the installer
# ("" for none), installer arguments...
# The server kit changes /etc/ssh and must run as root: it is started with sudo (the sudo
# password is asked in this terminal) or directly when logged in as root.
read -r -d '' REMOTE_SCRIPT <<'REMOTE'
mark() { printf '@@RESULT:%s@@\r\033[K' "$1"; }
url=$1; envspec=$2; shift 2
[ "$(uname -s 2>/dev/null)" = Linux ] || { mark UNSUPPORTED; exit 0; }
command -v apt-get >/dev/null 2>&1 || { mark UNSUPPORTED; exit 0; }
command -v bash >/dev/null 2>&1 || { mark UNSUPPORTED; exit 0; }
if [ "$(id -u)" = 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else mark PRIVILEGE; exit 0; fi
if [ -n "$SUDO" ]; then $SUDO -v || { mark PRIVILEGE; exit 0; }; fi
tmp=$(mktemp) || { mark DOWNLOAD_FAILED; exit 0; }
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  echo 'Installing wget...'
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null &&
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget ca-certificates </dev/null >/dev/null
fi
if command -v wget >/dev/null 2>&1; then wget -qO "$tmp" "$url"
elif command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$tmp"
fi
[ -s "$tmp" ] || { rm -f "$tmp"; mark DOWNLOAD_FAILED; exit 0; }
# shellcheck disable=SC2086  # VAR=value words (no spaces in values)
$SUDO env $envspec bash "$tmp" "$@"
rc=$?
rm -f "$tmp"
if [ "$rc" -eq 0 ]; then mark SUCCESS; else mark INSTALL_FAILED; fi
REMOTE

installer_message() {  # result ip
  case "$1" in
    SUCCESS) printf 'step-ssh-server-bootstrap-kit finished successfully on %s.\n' "$2" ;;
    PRIVILEGE) printf 'Skipped: administrator privileges (root or sudo) are unavailable on %s.\n' "$2" ;;
    UNSUPPORTED) printf 'Skipped: %s is not a Debian-based Linux system with bash.\n' "$2" ;;
    DOWNLOAD_FAILED) printf 'Could not download the installer on %s (no Internet access or neither wget nor curl).\n' "$2" ;;
    INSTALL_FAILED) printf 'The installer reported an error on %s - see the output above (a rejected sshd configuration is rolled back automatically).\n' "$2" ;;
    *) printf 'The remote session ended without a result on %s (unsupported shell or interrupted).\n' "$2" ;;
  esac
}

# ---------------------------------------------------------------- settings
declare -a kit_args=() test_accounts=()
test_key=""
last_user="${SSH_USER:-}"
printf 'Installer: %s\n' "$INSTALLER_URL"
printf 'Every selected SSH server will trust SSH user certificates of your step-ca.\n'
while true; do
  kit_args=(--yes)
  read -r -p 'step-ca URL (e.g. https://192.168.0.150): ' ca_url || exit 0
  [[ "$ca_url" == https://* ]] || { printf 'The URL must start with https://\n'; continue; }
  read -r -p 'Root certificate fingerprint (on the CA: step-ca-ssh.sh info): ' fp || exit 0
  fp=${fp//[: ]/}; fp=${fp,,}
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || { printf 'The fingerprint must be 64 hex characters (SHA-256).\n'; continue; }
  kit_args+=(--ca-url "$ca_url" --fingerprint "$fp")

  read -r -p 'Local accounts to create if missing (comma separated, e.g. ansible,sysadmin; Enter: none): ' users || exit 0
  users=${users// /}
  bad=0
  if [[ -n "$users" ]]; then
    IFS=',' read -r -a ul <<<"$users"
    for u in "${ul[@]}"; do valid_name "$u" || { printf 'Invalid user name: %s\n' "$u"; bad=1; }; done
    ((bad)) && continue
    read -r -p 'Of these, accounts that should be in group sudo (comma separated, Enter: none): ' sudo_users || exit 0
    sudo_users=${sudo_users// /}
    kit_args+=(--ensure-user "$users")
    [[ -n "$sudo_users" ]] && kit_args+=(--sudo-user "$sudo_users")
  fi

  printf 'Principal mapping: an account may also accept certificates of other principals,\n'
  printf 'e.g. "root=sysadmin" lets a sysadmin certificate log in as root. Format ACCOUNT=P1[,P2]\n'
  while true; do
    read -r -p 'Mapping (Enter: done): ' m || exit 0
    [[ -z "$m" ]] && break
    m=${m// /}
    if [[ "$m" =~ ^[a-z_][a-z0-9_.-]*=[a-z_][a-z0-9_.,-]*$ ]]; then kit_args+=(--map "$m")
    else printf 'Invalid mapping (ACCOUNT=PRINCIPAL[,PRINCIPAL]).\n'; fi
  done
  if ask_yes_no 'DietPi with Dropbear (cannot use certificates): replace it by OpenSSH automatically?' n; then
    kit_args+=(--switch-dropbear)
  fi
  printf 'Installer options: %s\n' "${kit_args[*]}"
  if ask_yes_no 'Are these settings correct?' y; then break; fi
done

if ask_yes_no 'Test a certificate login from this machine after each device?' y; then
  while true; do
    def="$HOME/.ssh/step_${USER:-sysadmin}"
    if [[ ! -f "$def" ]]; then
      def=""
      for k in "$HOME"/.ssh/step_*; do
        [[ -f "$k" && "$k" != *.pub ]] && { def=$k; break; }
      done
    fi
    read -r -p "Private key with certificate (<key>-cert.pub)${def:+ [$def]}: " test_key || exit 0
    test_key=${test_key:-$def}
    test_key=${test_key/#\~/$HOME}
    [[ -f "$test_key" && -f "$test_key-cert.pub" ]] || { printf 'Need %s and %s-cert.pub (step-ssh-client-bootstrap-kit).\n' "$test_key" "$test_key"; continue; }
    if command -v ssh-keygen >/dev/null; then
      ssh-keygen -L -f "$test_key-cert.pub" | sed -n -e 's/^[[:space:]]*Valid:/  Valid:/p' -e '/Principals:/,/Critical/p' | grep -v Critical
    fi
    read -r -p 'Accounts to test (comma separated, e.g. sysadmin,root): ' ta || exit 0
    ta=${ta// /}
    IFS=',' read -r -a test_accounts <<<"$ta"
    ((${#test_accounts[@]})) && break
  done
fi

ask_range
scan_range

declare -a done_hosts=() failed_hosts=() test_failed=()
for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Configure this SSH server for step-ca certificates?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  if with_login "$ip" "$REMOTE_SCRIPT" "$INSTALLER_URL" "${INSTALLER_ENV:-}" "${kit_args[@]}"; then
    installer_message "$result" "$ip"
    if [[ "$result" == SUCCESS ]]; then
      done_hosts+=("$ip")
      if [[ -n "$test_key" ]]; then cert_test "$ip" || test_failed+=("$ip"); fi
    else
      failed_hosts+=("$ip")
    fi
  else
    [[ "$result" == SKIPPED ]] || failed_hosts+=("$ip")
  fi
done
printf '\nFinished. Configured: %d' "${#done_hosts[@]}"
((${#done_hosts[@]})) && printf ' (%s)' "${done_hosts[*]}"
printf ', failed: %d' "${#failed_hosts[@]}"
((${#failed_hosts[@]})) && printf ' (%s)' "${failed_hosts[*]}"
if [[ -n "$test_key" ]]; then
  printf ', certificate test failed: %d' "${#test_failed[@]}"
  ((${#test_failed[@]})) && printf ' (%s)' "${test_failed[*]}"
fi
printf '\n'
exit 0
