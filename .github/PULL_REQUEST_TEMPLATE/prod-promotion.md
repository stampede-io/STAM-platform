<!--
STAM-62 / AC4: prod promotion is always a human-opened PR, never
automated — unlike staging's bump PRs (STAM-62's CI job), nothing
copies a tag from values-staging.yaml to values-prod.yaml on its own.
Open this PR with: gh pr create --template prod-promotion.md
-->

## What's being promoted

- **Service(s):** <!-- e.g. catalog, or "catalog + booking" if bumping more than one together -->
- **Staging tag being promoted:** <!-- the `image.tag` value currently live in values-staging.yaml for this service -->
- **New prod tag:** <!-- a real released version (CLAUDE.md §10's tagging rule — never a bare commit SHA, never `latest`) -->

## Why now

<!-- what's been verified in staging that makes this ready for prod -->

## Checklist

- [ ] `helm/Chart.yaml`'s `appVersion` on the service repo already matches this tag at publish time (AC8's version-drift gate)
- [ ] This PR changes only `values-prod.yaml`'s `image.tag` key(s) for the service(s) named above — no other prod config
- [ ] ArgoCD's `stampede-prod` Application will show `OutOfSync` after merge and needs a manual `argocd app sync` (or UI Sync click) — this PR merging does **not** deploy anything by itself
