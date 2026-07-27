# Optional: Model-as-a-Service (MaaS) Add-on

Deploys a sample inference endpoint using RHOAI KServe, demonstrating how platform teams
can expose GPU-backed models as self-service APIs — on top of the Kueue-governed GPU pool.

## When to use

After the single-cluster setup (`setup.sh`) is complete. Requires:
- RHOAI 3.x with KServe enabled
- An available GPU node with at least one free MIG slice or full GPU
- A model available for serving (example uses a pre-built runtime)

## Setup

```bash
bash optional/maas/deploy-maas.sh
```

## Teardown

```bash
bash optional/maas/teardown-maas.sh
```

## What it deploys

- A dedicated namespace (`maas-project`) with GPU access
- A KServe `ServingRuntime` configured for the GPU tier
- An `InferenceService` exposing the model as a REST endpoint
- User tokens for authenticated API access

> **Note:** This is an optional bonus demo — not required for UC1–UC9.
> It shows how the GPU-as-a-Service platform extends to model serving.
