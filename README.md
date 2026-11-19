# O-RAN Sample Applications

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Example xApps and rApps demonstrating closed-loop RAN intelligence on an
Open RAN stack, maintained by [**EchoNest Labs**](https://echonest.se).

The sample loop has three stages:

- **Telemetry**: an xApp collects RAN key performance measurements from
  the gNB over E2. [`kpm-hello`](xapps/kpm-hello/) is the shipped sample;
  the lab also runs FlexRIC's stock KPM monitor.
- **Decision**: an rApp consumes KPIs and produces a control decision
  (planned).
- **Control**: an xApp applies the decision over E2 towards the gNB
  (planned; the FlexRIC SDK image ships the full xApp toolchain).

All samples run against a reproducible lab: an OAI gNB in rfsim mode with
four OAI nr-UEs, the FlexRIC near-RT RIC, and the open5gs 5G core, all
running as pods on a single-node k3s cluster.

## Contents

| Directory | Status | Description |
|---|---|---|
| [`deploy/k8s/`](deploy/k8s/) | **working** | The lab as a Helm chart for a single-node k3s cluster: the 12 open5gs network functions, the gNB and 4 UEs in rfsim mode, the FlexRIC near-RT RIC with a smoke xApp, a web NMS add-on, and a verify job with real end-to-end gates. Includes the bring-up script that runs at boot on the machine image |
| [`deploy/rfsim-compose/`](deploy/rfsim-compose/) | **working** | An earlier single-host variant of the same lab in docker compose, with bring-up and verify scripts. The k8s chart is the current focus |
| [`deploy/nms/`](deploy/nms/) | optional | The open5gs-nms web NMS with live topology (build scripts, patches, license notes) |
| [`deploy/monitoring/`](deploy/monitoring/) | optional | External monitoring tier (node-exporter, cAdvisor, Prometheus, Grafana) |
| [`xapps/`](xapps/) | partial | xApps: [`kpm-hello`](xapps/kpm-hello/) is a shipped hello-world telemetry sample; the built-in KPM monitor running in the lab is FlexRIC's example binary; other samples are planned (see the folder READMEs) |
| [`rapps/`](rapps/) | planned | rApps (non-RT control loop: KPIs to decision to actuation) |
| [`dashboards/`](dashboards/) | planned | Grafana dashboards for the samples |

## Quick start

The quickest way to run the lab is the prebuilt machine image, below.
Nothing to build; the stack converges by itself on first boot.

You can also bring the chart up yourself on a k3s node with the container
images preloaded. The chart uses `imagePullPolicy: Never`, so it never
falls back to a registry:

```bash
# single-node k3s, images preloaded into containerd
helm upgrade --install lab deploy/k8s --wait
helm test lab
```

A converged release passes all verify gates and writes
`/var/lib/lab-green` on the machine image. See
[`deploy/k8s/README.md`](deploy/k8s/README.md) for the chart layout and
what each gate checks.

## Sample applications

Sample apps live in [`xapps/`](xapps/) and [`rapps/`](rapps/). Start with
[`xapps/kpm-hello`](xapps/kpm-hello/): a ~300-line xApp that subscribes to
E2SM-KPM and prints per-second cell-level and per-UE measurements.

On the machine image the sample runs inside the cluster out of the box.
With the compose variant you build it on demand against the pinned
FlexRIC source that ships in the SDK image:

```bash
cd deploy/rfsim-compose   # with the lab up (core, ran, ric)
docker compose -f docker-compose.yml -f docker-compose.samples.yml \
  --profile samples up --build kpm-hello
docker logs -f oran-kpm-hello
```

Next, [`xapps/kpm-exporter`](xapps/kpm-exporter/): the same subscription
as a Prometheus text endpoint, so the RAN KPIs become scrapeable metrics
instead of scrolling logs.

```bash
docker compose -f docker-compose.yml -f docker-compose.samples.yml \
  --profile samples up --build kpm-exporter
curl -s localhost:8080/metrics
```

## Machine image

The whole lab ships as a public EC2 machine image: a single-node k3s
cluster with all container images preloaded, the chart installed, and a
boot service that converges the lab on first start. No build required.

AMI name: `oran-lab-k8s-v0.4.4-ubuntu22.04-x86_64`

| Region | AMI ID |
|---|---|
| `eu-north-1` (Stockholm)   | `ami-0c70864e73987f483` |
| `us-east-1` (N. Virginia) | `ami-0c1e06ff8e5e38bdf` |

Before you launch, a few things worth knowing:

- Use a c7i-class instance. The recommended size is c7i.2xlarge. The gNB
  binary is built for Sapphire Rapids, so a t3 instance dies with SIGILL
  at gNB startup.
- 40 GB of gp3 storage on the root volume is enough.
- The lab converges on first boot in roughly 10 to 20 minutes. When
  `/var/lib/lab-green` exists on the instance, the verify gates have
  passed (21 pods running: the core network functions, gNB, 4 UEs, RIC,
  xApp and NMS).
- The NMS web console listens on port 8888 and speaks plain HTTP, not
  HTTPS. Keep port 8888 closed in the security group and reach it
  through an SSH tunnel, or open it to your own IP only. The NMS backend
  runs with elevated node access by design, so treat that port as
  root-level exposure. See [SECURITY.md](SECURITY.md).
- NMS login: `admin` plus the password you set in user-data as
  `NMS_PASSWORD=<your-password>` at launch. Without that marker, the
  backend generates a random password and prints it once to the backend
  pod log (`kubectl logs deploy/lab-nms-backend -c backend | grep -A4
  "FIRST RUN"`). Change the password after first login; user-data stays
  readable for the instance lifetime.

Connect to the instance with your own SSH key (add it at launch) or
through EC2 Instance Connect. SSH host keys are regenerated at first
boot. Once on the node:

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods
```

Verify the whole stack after convergence:

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm test lab
```

The verify job checks the real thing end to end: ICMP echo over each
UE's tunnel through the radio link, live E2 connectivity from the xApp
to the RIC, and (optional, off by default) the E2SM-CCC RAN function
acceptance line.

Software versions: open5gs v2.8.0, OAI gNB and nr-UE built from pinned
rfsim sources, FlexRIC v3.0.0 (near-RT RIC + KPM xApp), k3s as the
Kubernetes flavor.

> **Provenance note:** the container images in the machine image are
> prebuilt and preloaded; this repository ships the chart, configs and
> scripts that run them, not the image build recipes. The lab is an
> EchoNest Labs appliance, not an official image of open5gs, OAI,
> FlexRIC or the O-RAN Alliance. All included components are open
> source under their own licenses.

## License

Apache License 2.0, see [LICENSE](LICENSE). Components that differ
under their own terms:

- The sample xApps in [`xapps/`](xapps/) are simplified derivatives of
  the FlexRIC v3.0.0 example code, so they ship under the same
  Collaborative Standards Software License v1.0 (CSSL). The license
  text is vendored at
  [`xapps/LICENSES/LicenseRef-CSSL-1.0.txt`](xapps/LICENSES/LicenseRef-CSSL-1.0.txt).
- [`deploy/nms/`](deploy/nms/) wraps the AGPL-3.0 open5gs-nms web UI.
  That folder's README covers provenance and the source patches.
- open5gs, OAI and FlexRIC keep their own licenses and are pulled at
  pinned versions.
