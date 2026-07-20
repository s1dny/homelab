# Plarza delivery and operations

Plarza uses two independent declarative loops:

1. `deploy-rs` activates the pinned NixOS closure on `azalab-0`.
2. Flux reconciles the pinned Kubernetes resources from this repository.

Application repositories build images. They never SSH to production or mutate the
cluster. Each successful `main` build publishes a unique image to GHCR and records
build provenance. Flux scans those tags, resolves their digest, and commits only the
image reference change back to this repository.

The app, worker, website, and dashboard CI runs on Blacksmith Ubuntu 24.04 runners.
This personal infrastructure repository uses GitHub-hosted Ubuntu because Blacksmith
supports organization repositories. Repositories without a build or deployment
artifact intentionally have no CI. Container repositories use Blacksmith's persistent
BuildKit cache with a bounded 20 GiB cache and publish only from `main`; pull requests
run the same checks and image build without registry writes.

## Private registry access

The `plarza/app` and `plarza/worker` GHCR packages stay private. A dedicated classic
GitHub PAT with only `read:packages` access is stored as a SOPS-encrypted
`kubernetes.io/dockerconfigjson` secret named `plarza-ghcr`. The secret exists in
both `flux-system`, for image reflection, and `plarza`, for workload pulls. Do not
reuse a developer token with repository or package-write access.

Rotate the credential by replacing both encrypted Secret documents, waiting for the
apps Kustomization to reconcile, and then revoking the previous PAT.

Set the `PUBLIC_POSTHOG_KEY` Actions repository variable in `plarza/app`. It is a
public build-time value, not a secret. GitHub's automatically issued `GITHUB_TOKEN`
publishes the package, and the Blacksmith BuildKit build records registry-native
provenance metadata.

The `flux-system-write` secret must contain GitHub credentials with permission to
push only to this repository. Branch protection should require the infrastructure
validation workflow while allowing that bot identity to update image markers.
It is currently a bootstrap-managed live secret. Import it into a SOPS-encrypted
manifest before deleting or rotating the live copy; do not place its plaintext in Git.

## Safe migration order

1. Merge the app and worker workflows and run each once on `main`.
2. Confirm Flux and a disposable pod can pull both private GHCR packages using the
   SOPS-managed credential.
3. Merge this repository. Existing `localhost:5000` image references remain active
   until Flux sees a valid GHCR tag, so installing the controllers cannot cause an
   empty-image rollout.
4. Confirm the image policies have selected tags and the automation commits digest
   references.
5. Deploy the NixOS closure with deploy-rs. This removes the old host-side app and
   worker build timers only after the replacement delivery path is working.

## Deploy and verify

```bash
nix flake check
nix run github:serokell/deploy-rs -- .#azalab-0

kubectl -n flux-system get kustomization infrastructure platform apps
kubectl -n flux-system get imagerepository,imagepolicy,imageupdateautomation
kubectl -n plarza rollout status deployment/plarza --timeout=10m
kubectl -n plarza rollout status deployment/plarza-worker --timeout=10m
```

An in-progress worker task is allowed to finish during a rollout. SIGTERM first
makes the old pod unready and rejects new tasks; Kubernetes then gives it up to 24
hours to drain. A host loss still interrupts process-local work, so callers must be
able to resubmit work that does not complete.

## Rollback

Revert the Flux image-automation commit to restore the prior image digest. Revert a
host configuration commit and deploy it with deploy-rs to restore the prior NixOS
closure. `magicRollback` and `autoRollback` protect against an activation that loses
SSH connectivity.

## Flux operator UI

The operator is installed for its status UI, while NixOS continues to own the pinned
Flux 2.9.2 controllers. Operator lifecycle takeover is intentionally deferred until its
published distribution validates against the 2.9 series. The UI is cluster-internal; use
a temporary local tunnel:

```bash
kubectl -n flux-system port-forward service/flux-operator 9080:9080
```

Open `http://127.0.0.1:9080`. Do not expose it through the public tunnel unless it is
first protected by Cloudflare Access or another authenticated identity-aware proxy.

## Backups

`rustic-host-backup.timer` writes a local encrypted snapshot, applies retention,
mirrors it to Proton Drive, and requires `rclone check` to succeed. The weekly
`rustic-restore-smoke-test.timer` reads a sample of the remote repository, restores
`/etc/nixos` into a temporary directory, and verifies the expected flake exists.

```bash
sudo systemctl start rustic-host-backup.service
sudo systemctl start rustic-restore-smoke-test.service
sudo journalctl -u rustic-host-backup.service -u rustic-restore-smoke-test.service
```

The host SOPS identity and Flux SOPS identity are deliberately different. NixOS
decrypts `flux_age_key` from `host-secrets.sops.yaml` and reconciles only that key into
`flux-system/sops-age`; cluster controllers never receive the host identity.
