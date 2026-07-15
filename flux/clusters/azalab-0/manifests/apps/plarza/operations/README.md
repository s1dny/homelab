# Plarza database cutover

These Jobs are deliberately excluded from the Flux Kustomization. They are one-shot cutover operations and must never reconcile automatically.

The controlled sequence is:

1. Keep both new Plarza Deployments at zero replicas.
2. Quiesce the old `libsql/libsql` Deployment and record final `url` and `scrape` counts.
3. Apply `clone-old-database-job.yaml`. It mounts Old read-only and refuses an existing target.
4. Start only `plarza/plarza-libsql` and verify it is ready.
5. Apply `merge-databases-job.yaml`. It imports the immutable New snapshot, verifies every New table by digest, retains Old `url` and `scrape`, rejects legacy tables, and runs database checks.
6. Validate row counts and application readiness before starting the Plarza application.

The original Old volume remains unchanged and scaled down for rollback until the cutover is accepted.
