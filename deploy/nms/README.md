# open5gs-nms (optional web NMS with live topology)

A web NMS for the lab: dashboard, **Topology** (4G/5G architecture with
live interface state), **RAN Network** (connected gNBs and their UEs),
subscribers, logs and metrics. Source project:
https://github.com/paulmataruso/open5gs-nms

Requires **open5gs v2.8.0+** (the pinned `OG5GS_REF` in
`../rfsim-compose/docker/open5gs.Dockerfile`) — the NMS consumes the JSON
info endpoints (`AMF /gnb-info`, `/ue-info`, `SMF /pdu-info`) that 2.7.x
does not serve, and the `metrics:` blocks in the lab's
`config/open5gs/{amf,smf}.yaml`.

## Why it has to run on the lab VM

The backend hooks the **AMF container's network and PID namespaces**
(`network_mode`/`pid: container:oran-amf`) to reach the 5GC's
`127.0.0.x` metrics endpoints, and shares the AMF's view of
`/etc/open5gs` (mounted read-only from the lab's config dir) and the
`open5gs` database in the lab's mongodb. It cannot run on an external
monitoring host. nginx and the frontend build use the host network
(nginx listens on 80 and 8888; the frontend serves on 8083 because the
lab's cAdvisor already owns 8081).

## Usage

```bash
cd deploy/nms
./build.sh          # bake the images (done for shipped AMIs; needs internet once)
./start.sh          # start it — requires the lab stack to be up first
```

Login: if the instance was launched with user-data `NMS_PASSWORD=<pw>`, sign
in with `admin` / `<pw>`. Otherwise the backend generates a random admin
password at first start — get it with `kubectl logs deploy/lab-nms-backend -c
backend | grep -A4 "FIRST RUN"`. Change it after first login (user-data stays
readable for the instance lifetime, so treat the seeded value as a bootstrap).

502 on `/api/vowifi` and `/api/mms` is normal — optional upstream modules
are intentionally disabled in the frontend build. The Dashboard's
"Active services" counters rely on systemd inside the AMF container; the
shipped patch below falls back to a `/proc` scan instead.

If you recreate the AMF container, re-run `./start.sh` (the backend
namespace attachment follows the container, not the compose hash).

## Provenance and license (AGPL-3.0)

open5gs-nms is Copyright (C) 2026 Paul Mataruso, licensed under
**AGPL-3.0** (see `LICENSE` in the upstream repo; `THIRD_PARTY_NOTICES.md`
there lists its dependencies).

- Upstream commit pinned in `build.sh`: `54c405d634768c4cb27d3ef52d6e9c6114695aad`
  (main, 2026-11-04).
- One source patch is applied: `patches/0001-proc-service-status-fallback.patch`
  — a `/proc` fallback in the backend's service-status probe, needed
  because no systemd runs in the AMF container. It changes
  `backend/src/application/use-cases/service-monitor.ts` and
  `backend/src/domain/entities/service-status.ts` only; those files
  correspond to the patch and the pinned commit above.
- One more source patch: `patches/0003-hide-metrics-module.patch`
  (`patches/0002-mongodb-uri-host.patch` covers the same backend file as
  0001) — adds a `VITE_ENABLE_METRICS` display toggle (default on) to the
  frontend and hides the Metrics nav page when it is `false`. This lab's
  k8s deployment has no Prometheus/Grafana stack, so `build.sh` passes
  `VITE_ENABLE_METRICS=false` and the frontend shows no dead charts.
  Affects `frontend/src/App.tsx`, `frontend/src/components/common/navItems.ts`
  and `frontend/src/config/features.ts` only.
- Images built by `build.sh` carry `org.opencontainers.image.source`,
  `.revision` and `.licenses` labels. Anyone running the images can get
  the corresponding source by checking out the pinned commit and applying
  the patch in this directory.
