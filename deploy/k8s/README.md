# Component manifest names (the chart skeleton)

One umbrella chart (`deploy/k8s`), four component charts. Release name prefix
is `$RELEASE` (default `lab`). Names below are what verify scripts, dashboards
and docs should reference.

## core (5GC)

| Resource | Kind | Notes |
|---|---|---|
| `$RELEASE-mongodb` | StatefulSet + Service | Subscriber DB. |
| `$RELEASE-nrf` | Deployment + Service (ClusterIP) | SBI discovery anchor. |
| `$RELEASE-amf` | Deployment + headless Service | NGAP (SCTP 38412) must ride pod IP. |
| `$RELEASE-smf` | Deployment + Service | |
| `$RELEASE-upf` | Deployment + headless Service | `NET_ADMIN` + `/dev/net/tun`; GTP-U 2152 pod-IP-to-pod-IP. |

Each NF's metrics bind to its own pod IP; discovered by Prometheus pod
annotations, no shared netns anywhere.

## ran

| Resource | Kind | Notes |
|---|---|---|
| `$RELEASE-gnb` | StatefulSet (1 replica) + headless Service | rfsim gNB image, rfsim TCP 4043. Init container waits for `$RELEASE-amf` and `$RELEASE-ric`. Pod IP advertised via downward API. |
| `$RELEASE-ue` | StatefulSet (replicas 4) | OAI nr-UE. Ordinal index selects config/IMSI (`ue0..ue3.yaml`). Init container waits for `$RELEASE-gnb`. Needs `NET_ADMIN` + `/dev/net/tun`. |

The gNB is a singleton on purpose; scale `ue` instead. Readiness must not be a
tcpSocket probe on 4043 (it looks like a UE dial-in);
use exec/log gating.

## ric

| Resource | Kind | Notes |
|---|---|---|
| `$RELEASE-ric` | Deployment + headless Service | FlexRIC nearRT-RIC, E2 on pod IP (E2AP_V3/KPM_V3 build). Accepts KPM (ID 2), RC (ID 3) and E2SM-CCC (ID 4) RAN functions. |
| `$RELEASE-xapp-kpm-hello` | Deployment | Image built from the same pinned FlexRIC image (SM libs match). Runs a 30 s loop that subscribes per E2 node, reads the supported RAN function list and exits. That loop is the periodic E2/KPM smoke signal. |
| `$RELEASE-xapp-kpm-exporter` | Deployment + Service (metrics 9800) | Optional, not shipped in `values.yaml` by default: the in-repo exporter sample predates this chart. Same image base; Prometheus scrapes via pod annotations. |

## obs

| Resource | Kind | Notes |
|---|---|---|
| `$RELEASE-prometheus` | Deployment (or kube-prometheus-stack) | Not part of the current bring-up (values toggle pending); NF metrics bind to pod IPs for a later pod-discovery scrape. |
| `$RELEASE-grafana` | Deployment + Service (Ingress optional) | Same status. |

## verification

| Resource | Kind | Notes |
|---|---|---|
| `$RELEASE-verify` | Job (`helm test`) | Real gates, no Prometheus dependency. Gate 1, UE data plane: ICMP echo to 10.45.0.1 over `oaitun_ueN` via a python3 raw-socket checker (ConfigMap `check-data-plane`, exec'd into each UE pod, since the UE image has no ping). Gate 2, E2 path: a free-form grep of the kpm-hello xApp logs for `Connected E2 nodes = N` (N>=1). Gate 3, optional via `ricBuild.cccEnabled`, E2SM-CCC: grep of the RIC logs for the CCC RAN-function acceptance line. Image `bitnamilegacy/kubectl:1.30` (the main bitnami repo archived the 1.30 tag); it must be preloaded and uses `imagePullPolicy: Never`. |

### E2SM-CCC status

The gNB advertises its E2SM-CCC RAN function at E2 Setup and the near-RT RIC accepts it
(gate 3, off by default via `ricBuild.cccEnabled`). CCC **control actuation** (sending
slice-reconfiguration requests from an xApp) is roadmap: no public control sample ships,
and the mechanism is exercised only up to SM registration.

## Bring-up

    k3s install (one node)
    helm upgrade --install lab deploy/k8s --wait
    helm test lab

Unattended convergence (`lab-bringup.service`, baked in the AMI) wraps the
same flow: waits for the node, installs the release from `/opt/lab/chart`,
absorbs the known rfsim attach flakiness (one gNB restart; UE pod recycles;
a UPF→SMF+UE recycle if no UE data plane is up late in the loop), reaps stale
verify jobs, and repeats `helm test` until it reports `phase: Succeeded`.
After that it drops `/var/lib/lab-green`.

Images are pre-loaded into the node's containerd store (the machine
image ships them) and every container uses `imagePullPolicy: Never`, so
the chart never silently falls back to a registry.

## AMI

The whole lab ships as one public AMI (k3s + preloaded containerd images +
chart + bring-up service). See the top-level README for the AMI ID and
launch notes. The gNB binary is built for Sapphire Rapids, so the instance
must be c7i, r8i or m7i class; a t3 instance dies with SIGILL at gNB
startup. Boot is fully hands-off: on first
boot the bring-up unit converges the lab (10 to 20 minutes including
attach) and `/var/lib/lab-green` marks a converged release passing
`helm test`.

Chart values decide what is active. The NMS add-on ships in the chart
(`nms.yaml`) and is enabled by default; it mounts the node's
`/var/lib/lab-nms` for its auth DB and seeds the admin password from a
k8s Secret created at boot (see the machine image notes in the top-level
README for the security caveats around its plain-HTTP console).
