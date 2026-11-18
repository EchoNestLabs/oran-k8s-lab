#!/bin/bash
# lab-bringup: converge the O-RAN rfsim lab after boot (or first boot).
# Idempotent: safe to run every boot. Writes /var/lib/lab-green on success.
set -u
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
LOG=/var/log/lab-bringup.log
exec >> "$LOG" 2>&1
echo "=== lab-bringup start $(date -Is) ==="
# A green marker from a previous boot (or baked image) is not evidence for
# THIS boot; start clean every run.
rm -f /var/lib/lab-green

# Wait for the node to be Ready
for i in $(seq 1 60); do
  kubectl get nodes 2>/dev/null | grep -q Ready && break
  sleep 5
done

# Optional: seed the NMS admin password the launcher chose at launch time.
# Launch wizard user-data marker:  NMS_PASSWORD=<password>
# Parsed strictly and stored ONLY in a k8s Secret (never through helm values
# or --set, which would keep it in release history / describe output).
# Missing or invalid marker -> NMS backend falls back to its documented
# random-password first run (printed to the backend pod logs).
# NOTE: user-data stays readable for the instance lifetime — this is a
# bootstrap password; change it after first login.
nms_pw=""
ud_token=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token 2>/dev/null) && \
  nms_pw=$(curl -sf -H "X-aws-ec2-metadata-token: $ud_token" \
    http://169.254.169.254/latest/user-data 2>/dev/null | \
    awk '/^[[:space:]]*NMS_PASSWORD=/{print; exit}' | \
    grep -oE '^NMS_PASSWORD=[A-Za-z0-9!@#%^&*_.+-]{10,128}$' \
    | head -1 | cut -d= -f2-)
unset ud_token
# The grep above already enforces 10-128 chars, so seed whenever a valid
# marker was found (a length-based case here silently rejected a few valid
# lengths).
if [ -n "$nms_pw" ]; then
  kubectl create secret generic lab-nms-firstrun \
    --from-literal=password="$nms_pw" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null 2>&1 \
    && echo "NMS: admin password seeded from launch user-data"
fi
unset nms_pw

helm upgrade --install lab /opt/lab/chart --wait --timeout 25m || true

gnb_restarted=0
pfcp_last=-10
pfcp_count=0
partial_streak=0
gate_streak=0
tuns=0
ue_total=0
ok=0
for i in $(seq 1 48); do   # up to ~40 min
  sleep 50
  pods=$(kubectl get pods --no-headers 2>/dev/null)
  total=$(echo "$pods" | grep -c .)
  running=$(echo "$pods" | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0) c++} END {print c+0}')
  echo "iter $i: $running/$total pods Ready"

  # A failed helm hook (e.g. subscribers Job) leaves the release un-upgraded;
  # hook-delete-policy=before-hook-creation makes the next upgrade rerun it.
  if echo "$pods" | grep -qE "subscribers.*Error"; then
    echo "hook job failed -> rerun helm upgrade"
    helm upgrade --install lab /opt/lab/chart --wait --timeout 25m || true
    continue
  fi

  # Absorb the known rfsim attach flakiness: one gNB restart, only if it runs
  if [ "$i" = 8 ] && [ "$gnb_restarted" = 0 ] && kubectl get pod lab-gnb-0 >/dev/null 2>&1; then
    kubectl rollout restart statefulset/lab-gnb 2>/dev/null || true
    gnb_restarted=1
    echo "gNB restarted once (CFO-drift mitigation)"
    continue
  fi
  # UE pods wedged in Error/CrashLoop -> recycle
  kubectl get pods --field-selector=status.phase!=Running --no-headers 2>/dev/null \
    | grep "^lab-ue-" | awk '{print $1}' \
    | xargs -r kubectl delete pod --grace-period=0 --force 2>/dev/null || true

  # Data-plane census: a UE without its TUN never recovers on its own.
  # PFCP invariant (proven on-node): SMF resolves the UPF address once at
  # startup and NEVER re-associates after the UPF restarts. So whenever the
  # UPF is recycled, the SMF must be restarted AFTER the new UPF is Ready.
  # A simultaneous restart races (SMF may resolve before the new UPF is in
  # DNS) and keeps the wedge alive -- that is what blocked the v0.1.6 boots.
  if [ "$i" = 8 ] || [ "$i" -ge 10 ]; then
    tuns=0; ue_total=0; stuck=""
    for p in $(kubectl get pods -l app.kubernetes.io/name=ue -o name 2>/dev/null); do
      ue_total=$((ue_total+1))
      if kubectl exec "$p" -- cat /proc/net/dev 2>/dev/null | grep -q oaitun; then
        tuns=$((tuns+1))
      else
        stuck="$stuck $p"
      fi
    done
    echo "iter $i: UE TUNs up = $tuns/$ue_total"
    if [ "$tuns" = 0 ] && [ $((i - pfcp_last)) -ge 4 ]; then
      # No data plane at all: re-establish PFCP in the proven order.
      pfcp_count=$((pfcp_count+1))
      pfcp_last=$i
      echo "no UE data plane -> sequenced PFCP recovery #$pfcp_count"
      [ "$pfcp_count" -ge 2 ] && {
        # Still wedged after one sequenced recovery: recycle the radio side
        # too, so UEs re-register cleanly once PFCP is back.
        echo "persistent wedge -> also recycling AMF + gNB"
        kubectl rollout restart deployment/lab-amf 2>/dev/null || true
        kubectl delete pod lab-gnb-0 --grace-period=0 --force 2>/dev/null || true
      }
      kubectl rollout restart deployment/lab-upf 2>/dev/null || true
      kubectl rollout status deployment/lab-upf --timeout=180s 2>/dev/null || true
      kubectl rollout restart deployment/lab-smf 2>/dev/null || true
      kubectl rollout status deployment/lab-smf --timeout=180s 2>/dev/null || true
      sleep 20
      kubectl get pods -l app.kubernetes.io/name=ue -o name 2>/dev/null \
        | xargs -r kubectl delete pod --grace-period=0 --force 2>/dev/null || true
    elif [ "$tuns" -gt 0 ] && [ -n "$stuck" ]; then
      partial_streak=$((partial_streak+1))
      if [ "$partial_streak" -ge 4 ]; then
        # Persistent partial attach: per-UE recycles did not heal it (rfsim
        # contention wedge seen on cold boots). Nuclear recovery: reset the
        # radio side and give every UE a fresh NAS/registration pass.
        echo "partial attach persisting $partial_streak censuses -> nuclear recovery"
        partial_streak=0
        kubectl rollout restart deployment/lab-amf 2>/dev/null || true
        kubectl delete pod lab-gnb-0 --grace-period=0 --force 2>/dev/null || true
        kubectl get pods -l app.kubernetes.io/name=ue -o name 2>/dev/null \
          | xargs -r kubectl delete pod --grace-period=0 --force 2>/dev/null || true
      else
        # Partial attach: a stuck UE sits in a PDU-establishment reject loop and
        # never recovers on its own; a pod recycle gives it a fresh NAS start.
        echo "stuck UEs:$stuck -> force-delete for fresh attach"
        for p in $stuck; do
          kubectl delete pod "$p" --grace-period=0 --force 2>/dev/null || true
        done
      fi
    else
      partial_streak=0
    fi
  fi

  # reap finished/failed helm-test jobs so the readiness count stays clean
  if kubectl get pods -l job-name=lab-verify --no-headers 2>/dev/null        | grep -qE "Error|Completed|Evicted"; then
    kubectl delete job lab-verify --ignore-not-found 2>/dev/null || true
  fi

  if [ "$running" -eq "$total" ] && [ "$total" -ge 15 ]; then
    if helm test lab 2>&1 | grep -qi "phase: Succeeded\|SUCC"; then
      ok=1; echo "helm test PASSED"; break
    fi
    # The verify gate probes the DATA plane (ICMP to the core over oaitun).
    # Known wedge: SMF caches the UPF pod IP, so a recycled UPF leaves stale
    # PDU sessions -- a UE keeps its oaitun ROUTE (census looks 4/4) while
    # the tunnel is dead and only the gate's ICMP catches it. When the gate
    # keeps failing while the census is nominally healthy, run the proven
    # sequenced PFCP recovery instead of trusting the route census.
    gate_streak=$((gate_streak+1))
    if [ "$gate_streak" -ge 2 ] && [ "$ue_total" -gt 0 ] && [ "$tuns" = "$ue_total" ]; then
      echo "gate failed $gate_streak with healthy census -> sequenced PFCP recovery"
      gate_streak=0
      # SMF-ONLY restart (proven manual recipe). Do NOT restart the UPF here:
      # it is healthy, and recycling it churns its pod IP, invalidates every
      # PDU session again and keeps the wedge alive in a loop.
      kubectl rollout restart deployment/lab-smf 2>/dev/null || true
      kubectl rollout status deployment/lab-smf --timeout=180s 2>/dev/null || true
      sleep 90
      kubectl get pods -l app.kubernetes.io/name=ue -o name 2>/dev/null \
        | xargs -r kubectl delete pod --grace-period=0 --force 2>/dev/null || true
    fi
  fi
done

if [ "$ok" = 1 ]; then
  mkdir -p /var/lib && touch /var/lib/lab-green
  echo "=== lab GREEN $(date -Is) ==="
else
  echo "=== lab NOT GREEN after retries $(date -Is) ==="
  # Non-zero exit + Restart=on-failure in the unit makes systemd retry the
  # whole convergence instead of giving up silently.
  exit 1
fi
