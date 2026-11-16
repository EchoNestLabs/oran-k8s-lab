# Security Policy

## Reporting a vulnerability

Please do **not** report security vulnerabilities through public GitHub
issues. Instead, use GitHub's private vulnerability reporting
(**Security** tab, then **Report a vulnerability**).

Please include as much of the following as you can:

- The affected component (rApp, xApp, deployment script, etc.)
- A description of the issue and its potential impact
- Steps to reproduce, if applicable

## Scope

This repository contains sample applications intended for research and
lab environments. They are **not** hardened for production deployments.
Samples may deliberately run services without authentication to keep
the lab setup simple.

## Machine image notes

- The NMS web console on port 8888 speaks plain HTTP (no TLS) and its
  backend runs with elevated node access (`privileged`, host PID) so it
  can reach the 5GC metrics endpoints. Do not expose port 8888 to the
  internet. Reach it through an SSH tunnel, or restrict the security
  group rule to your own IP. Anyone who can reach the NMS effectively
  has root on the lab node.
- The NMS admin password is a bootstrap credential. Seed it at launch
  via the `NMS_PASSWORD` user-data marker or read the generated one from
  the backend pod log, then change it after first login. User-data stays
  readable for the instance lifetime.
- The lab ships default test subscriber credentials (the canonical
  open5gs sample values). Do not reuse them anywhere real.
