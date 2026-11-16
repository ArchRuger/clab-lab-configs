#!/usr/bin/env bash
# validate.sh: check the lab from the validator node.
#
# The validator logs in to each lab node with the SSH key of the lab, over the
# management network. It runs show commands on the PE and CE nodes and pings
# from the end devices. It changes no configuration.
#
#   bash /opt/validator/validate.sh [options]
#
#   --wait MIN       First wait until all nodes accept the key login, MIN minutes at most.
#   --phase LIST     Phases to run, in this order: access,services,ping (default: all three).
#   --nodes LIST     Only these nodes, separated by commas (default: all nodes of the inventory).
#   --retries N      Run a failed check again, N times at most (default 2). A first ping can
#                    fail before the far end has sent a frame.
#   --jobs N         Nodes checked at the same time (default 8). One command at a time per node.
#   --verbose        Print each check, not only the checks that did not pass.
#   --list           Print the checks and stop.
#   --out DIR        Folder for the report (default /tmp/validator/TIME).
#
# Environment, for a lab file that sets "env" on the node: VALIDATOR_PHASES,
# VALIDATOR_NODES, VALIDATOR_JOBS. An option on the command line takes priority.
#
# Files next to this script: inventory.tsv, checks.tsv (both made by
# deploy/gen-mix-configs.py) and id_rsa (the private key, not in git). If id_rsa
# is not next to the script, /opt/validator/id_rsa is used.
#
# Result of each check:
#   PASS   the output has the expected state
#   FAIL   the output does not have the expected state
#   ERROR  no output: the SSH login failed or the command did not return
#   SKIP   not run: the access phase failed for this node
#   XFAIL  failed, and that was expected (a known limit of the node kind)
#   XPASS  passed, but a failure was expected. Read the output and correct the expectation.
#   INFO   no verdict. The output is in the report folder.
# Exit status: 0 with no FAIL, ERROR or SKIP. 1 with one or more. 2 for a usage or setup error.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
INV=$DIR/inventory.tsv
CHK=$DIR/checks.tsv
KEY_SRC=${VALIDATOR_KEY:-$DIR/id_rsa}
[ -r "$KEY_SRC" ] || KEY_SRC=/opt/validator/id_rsa      # URL form of the lab: the key is the only bind
PHASES=${VALIDATOR_PHASES:-access,services,ping}
NODES=${VALIDATOR_NODES:-}
JOBS=${VALIDATOR_JOBS:-8}
RETRIES=2
WAIT_MIN=0
VERBOSE=0
LIST=0
OUT=
CMD_TIMEOUT=90          # seconds for one command, login included

die() { echo "STOP: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --wait)    WAIT_MIN=${2:?}; shift 2 ;;
    --phase)   PHASES=${2:?}; shift 2 ;;
    --nodes)   NODES=${2:?}; shift 2 ;;
    --retries) RETRIES=${2:?}; shift 2 ;;
    --jobs)    JOBS=${2:?}; shift 2 ;;
    --out)     OUT=${2:?}; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --list)    LIST=1; shift ;;
    -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) die "unknown option $1. Use --help." ;;
  esac
done

for p in ${PHASES//,/ }; do
  case $p in access|services|ping) ;; *) die "unknown phase $p. The phases are access, services and ping." ;; esac
done
for f in "$INV" "$CHK"; do [ -r "$f" ] || die "$f is missing."; done
for c in ssh grep awk sed sort timeout; do command -v "$c" >/dev/null || die "the command '$c' is not in this image."; done

# ---- inventory ---------------------------------------------------------------------------
declare -A KIND IP LOGIN WANT NOACCESS
ALL=()
while IFS=$'\t' read -r name kind ip login; do
  case $name in ''|\#*) continue ;; esac
  KIND[$name]=$kind; IP[$name]=$ip; LOGIN[$name]=$login; ALL+=("$name")
done < "$INV"
if [ -n "$NODES" ]; then
  SEL=()
  for n in ${NODES//,/ }; do
    [ -n "${IP[$n]:-}" ] || die "node $n is not in $INV."
    SEL+=("$n")
  done
else
  SEL=("${ALL[@]}")
fi
for n in "${SEL[@]}"; do WANT[$n]=1; done

if [ "$LIST" = 1 ]; then
  awk -F'\t' -v ph=",$PHASES," '!/^#/ && index(ph, "," $2 ",") {printf "%-18s %-9s %-13s %-6s %s  [%s]\n", $1, $2, $3, $4, $10, $9}' "$CHK" |
    while read -r line; do n=$(echo "$line" | awk '{print $3}'); [ -n "${WANT[$n]:-}" ] && echo "$line"; done
  exit 0
fi

# ---- SSH ---------------------------------------------------------------------------------
ssh -V 2>&1 | grep -q OpenSSH || die "the ssh client of this image is not OpenSSH."
[ -r "$KEY_SRC" ] || die "$KEY_SRC is missing. deploy/lab-from-git.sh on clab-gateway makes the key and copies it to the lab folder."
OUT=${OUT:-/tmp/validator/$(date -u +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/raw" "$OUT/res" || die "cannot write to $OUT."
# A bind file can be readable by all users. ssh refuses such a key, so use a private copy.
KEY=$OUT/.key
( umask 077; cat "$KEY_SRC" > "$KEY" ) || die "cannot copy the key."
trap 'rm -f "$KEY"' EXIT
SSH_OPTS=(-n -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
# An RSA key with an older SSH server: allow the ssh-rsa signature if this client knows the option.
for o in PubkeyAcceptedAlgorithms=+ssh-rsa HostKeyAlgorithms=+ssh-rsa; do
  ssh -G -o "$o" localhost >/dev/null 2>&1 && SSH_OPTS+=(-o "$o")
done

run_cmd() {   # node, command, output file. Status: that of ssh (255: no login), 124: timeout.
  timeout "$CMD_TIMEOUT" ssh "${SSH_OPTS[@]}" "${LOGIN[$1]}@${IP[$1]}" "$2" > "$3" 2>&1
}

# ---- one check ---------------------------------------------------------------------------
replies() {   # number of ping replies in a file. Junos, EOS: "N [packets] received". IOS XR: "(N/M)".
  grep -Eo '[0-9]+ (packets )?received|\([0-9]+/[0-9]+\)' "$1" | head -n 1 | grep -Eo '[0-9]+' | head -n 1
}

run_check() { # id phase node expect mode n pattern reject command description
  local id=$1 phase=$2 node=$3 expect=$4 mode=$5 n=$6 pattern=$7 reject=$8 cmd=$9 desc=${10}
  local raw=$OUT/raw/$id.txt st detail="" rc got
  if [ -n "${NOACCESS[$node]:-}" ] && [ "$phase" != access ]; then
    st=SKIP; detail="no access to the node"
  else
    run_cmd "$node" "$cmd" "$raw"; rc=$?
    if [ $rc = 255 ]; then
      st=ERROR; detail="SSH login failed: $(tail -n 1 "$raw" | cut -c1-80)"
    elif [ $rc = 124 ] || [ $rc = 143 ]; then
      st=ERROR; detail="no result in $CMD_TIMEOUT s"
    else
      case $mode in
        info)  st=INFO; detail="$(wc -l < "$raw") lines" ;;
        match) if grep -Eq -- "$pattern" "$raw"; then st=PASS; else st=FAIL; detail="no line with: $pattern"; fi ;;
        count) if [ "$reject" = - ]; then got=$(grep -Ec -- "$pattern" "$raw")
               else got=$(grep -E -- "$pattern" "$raw" | grep -Evc -- "$reject"); fi
               detail="$got of $n"
               if [ "$got" -ge "$n" ]; then st=PASS; else st=FAIL; fi ;;
        ping)  got=$(replies "$raw"); got=${got:-0}
               detail="$got of 5 replies"
               if [ "$got" -ge "$n" ]; then st=PASS; else st=FAIL; fi ;;
        *)     st=ERROR; detail="unknown mode $mode" ;;
      esac
    fi
  fi
  if [ "$expect" = xfail ]; then
    case $st in PASS) st=XPASS ;; FAIL) st=XFAIL ;; esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$id" "$phase" "$node" "$desc" "$detail" "$cmd" > "$OUT/res/$id"
}

run_node() {  # phase, node, file with the ids to run ("-": all checks of the phase)
  local id phase node expect mode n pattern reject cmd desc
  while IFS=$'\t' read -r id phase node expect mode n pattern reject cmd desc; do
    [ "$phase" = "$1" ] && [ "$node" = "$2" ] || continue
    [ "$3" = - ] || grep -qx -- "$id" "$3" || continue
    run_check "$id" "$phase" "$node" "$expect" "$mode" "$n" "$pattern" "$reject" "$cmd" "$desc"
  done < <(grep -v '^#' "$CHK")
}

run_nodes() { # phase, file with ids or "-": all selected nodes, JOBS at a time
  local n running=0
  for n in "${SEL[@]}"; do
    run_node "$1" "$n" "$2" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
  done
  wait
}

phase_results() {   # phase: result lines in the order of checks.tsv
  local id
  awk -F'\t' -v p="$1" '!/^#/ && $2 == p {print $1}' "$CHK" | while read -r id; do
    [ -f "$OUT/res/$id" ] && cat "$OUT/res/$id"
  done
}

# ---- wait for the nodes ------------------------------------------------------------------
if [ "$WAIT_MIN" -gt 0 ]; then
  end=$(( $(date +%s) + WAIT_MIN * 60 ))
  echo "Waiting for the key login on ${#SEL[@]} nodes, $WAIT_MIN minutes at most."
  while :; do
    for n in "${SEL[@]}"; do
      ( CMD_TIMEOUT=25; run_cmd "$n" "show version" "$OUT/raw/wait.$n.txt" && : > "$OUT/raw/wait.$n.ok" || rm -f "$OUT/raw/wait.$n.ok" ) &
    done
    wait
    up=0; down=""
    for n in "${SEL[@]}"; do if [ -f "$OUT/raw/wait.$n.ok" ]; then up=$((up + 1)); else down="$down $n"; fi; done
    echo "  $(date -u +%H:%M:%S) UTC: $up of ${#SEL[@]} nodes accept the login.${down:+ Not yet:$down}"
    [ "$up" = "${#SEL[@]}" ] && break
    [ "$(date +%s)" -ge "$end" ] && { echo "  The wait time is over. The checks start with the nodes as they are."; break; }
    sleep 30
  done
fi

# ---- the phases --------------------------------------------------------------------------
echo "Validator: ${#SEL[@]} nodes, phases $PHASES. Report folder: $OUT"
for phase in ${PHASES//,/ }; do
  start=$(date +%s)
  run_nodes "$phase" -
  round=0
  while [ "$round" -lt "$RETRIES" ]; do
    phase_results "$phase" | awk -F'\t' '$1 == "FAIL" || $1 == "ERROR" {print $2}' > "$OUT/retry.$phase"
    [ -s "$OUT/retry.$phase" ] || break
    round=$((round + 1))
    sleep 10
    run_nodes "$phase" "$OUT/retry.$phase"
  done
  if [ "$phase" = access ]; then
    while IFS=$'\t' read -r st id ph node rest; do
      case $st in FAIL|ERROR) NOACCESS[$node]=1 ;; esac
    done < <(phase_results access)
  fi
  phase_results "$phase" > "$OUT/$phase.tsv"
  echo
  echo "== Phase $phase: $(awk -F'\t' '{c[$1]++} END {s=""; for (k in c) s = s k " " c[k] "  "; print s}' "$OUT/$phase.tsv")($(( $(date +%s) - start )) s, $round repeat rounds)"
  awk -F'\t' -v v="$VERBOSE" 'v == 1 || ($1 != "PASS" && $1 != "INFO" && $1 != "XFAIL") {printf "%-5s %-18s %-13s %s%s\n", $1, $2, $4, $5, ($6 == "" ? "" : "  (" $6 ")")}' "$OUT/$phase.tsv"
done

# ---- summary -----------------------------------------------------------------------------
cat "$OUT"/access.tsv "$OUT"/services.tsv "$OUT"/ping.tsv 2>/dev/null > "$OUT/results.tsv"
bad=$(awk -F'\t' '$1 == "FAIL" || $1 == "ERROR" || $1 == "SKIP"' "$OUT/results.tsv" | wc -l)
{
  echo
  echo "== Result by node (PASS / FAIL / ERROR / SKIP / XFAIL / XPASS / INFO)"
  awk -F'\t' '{c[$4, $1]++; if (!($4 in seen)) {seen[$4]; order[++k] = $4}}
       END {for (i = 1; i <= k; i++) {n = order[i]
              printf "%-13s %4d /%3d /%3d /%3d /%3d /%3d /%3d\n", n, c[n,"PASS"], c[n,"FAIL"], c[n,"ERROR"], c[n,"SKIP"], c[n,"XFAIL"], c[n,"XPASS"], c[n,"INFO"]}}' "$OUT/results.tsv"
  echo
  echo "== Total: $(awk -F'\t' '{c[$1]++} END {for (k in c) printf "%s %d  ", k, c[k]}' "$OUT/results.tsv")"
  if [ "$bad" = 0 ]; then echo "RESULT: PASS. No check failed."; else echo "RESULT: FAIL. $bad checks have FAIL, ERROR or SKIP."; fi
  echo "Output of each command: $OUT/raw/ID.txt. All results: $OUT/results.tsv"
} | tee "$OUT/summary.txt"
[ "$bad" = 0 ]
