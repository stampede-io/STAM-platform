# ADR-0008: AWS EC2 for the Demo Cluster, Replacing Azure

**Status:** Accepted
**Date:** 2026-11-21
**Author:** Pulith Thewmika

## Context

Sprint 3 wrote the cluster Terraform for Azure: one `Standard_B2ms` VM
running single-node k3s, with state and backups in Azure Storage. It was
never applied. I couldn't get onto the Azure free plan, so every story
that needed the real cluster (STAM-50, the k3s half of STAM-450, the
STAM-71 cluster evidence, the 5,000-VU load test) sat blocked on an
`az login` that was never going to happen.

What I do have is $200 of AWS credits. The cluster has one job: run the
platform for the demo and the viva, for one week at most, then be torn
down. At that lifetime the credits stop being the constraint: every option
I priced, EKS included, fits. What decides it is setup risk on a short
clock and whether the node can take the 5,000-VU load test.

Only Terraform and the backup job knew which cloud they were on. The Helm
charts, ArgoCD, Strimzi, Sealed Secrets, NetworkPolicies, cert-manager and
DuckDNS run on any k3s node with a public IP.

## Decision

Move the cluster to **one EC2 instance running k3s**, provisioned by the
same `platform/terraform/` module rewritten for the `aws` provider:

- **k3s on EC2, not EKS.** For a week EKS would cost about $55 to k3s's
  $70 on the bigger node, so money isn't the reason. It's the setup: EKS
  needs subnets, a node group, IAM roles, the EBS CSI driver, the load
  balancer controller, and it caps pods per node by ENI count. All of that
  would be first-time work done while the week's clock runs. k3s is the
  same distribution the charts were already proven against on kind.
- **`m6i.2xlarge` (8 vCPU / 32 GB) in `ap-south-1`.** About $0.40/hour, so
  about $70 for the week with disk and IP. I first sized a burstable
  `t3.xlarge` (16 GB), but under a sustained load test a t3 either
  throttles to its baseline (`standard` credits) or bills for surplus
  (`unlimited`). The first corrupts the load-test numbers and the second
  makes the bill unpredictable. An m6i runs at full CPU for a flat price,
  and 32 GB keeps the monitoring stack from competing with the app.
  Terraform rejects t-family types so this can't regress quietly. Mumbai
  rather than us-east-1 because the demo audience is in Sri Lanka.
- **Elastic IP**, so the DuckDNS record survives a stop/start between demo
  sessions.
- **Security group** with the same rules the NSG had: 80 and 443 from
  anywhere, 22 from `operator_ip` only, 6443 closed (kubectl goes through
  an SSH tunnel).
- **S3 remote state with the native lockfile** (Terraform >= 1.10), so no
  DynamoDB table.
- **Backups to S3 through the instance role.** The CronJob's AWS CLI gets
  credentials from IMDSv2 (hop limit 2 so a pod can reach it), and the
  role may only read and write the backup bucket. With Azure this needed
  a service principal secret; here no access key exists at all.
- **An AWS Budget alarm** at 50/80/100% of a configured limit (default
  $100, against a ~$70 week), counting gross spend with credits excluded, because "actual cost
  net of credits" reads ~$0 right up until the credits run out.
- The default VPC, not a new one. A demo node gets nothing from a custom
  VPC except more resources to destroy.

I also disabled k3s' bundled Traefik in cloud-init. It wasn't
AWS-specific: Traefik's klipper LoadBalancer binds the node's 80/443, so
the ingress-nginx controller the ingress README installs could never have
got an address. The Azure version had the same bug.

## Consequences

- Nothing above the node changes. The charts, GitOps repo and ingress
  setup are untouched, which is what kept this move to one module and one
  CronJob.
- It costs real money from the first `apply`. Stopping the instance
  between sessions saves the compute charge but not the disk or the
  Elastic IP; `terraform destroy` after the defence is the only way to
  zero it. The state bucket outlives `destroy` by design and is deleted
  last by hand.
- Any pod in a namespace without a default-deny egress policy can reach
  IMDS and read the backup bucket's credentials. On a single-tenant demo
  node that's acceptable, and the role can do nothing outside that bucket.
  A multi-tenant cluster would want IRSA-style per-ServiceAccount roles or
  an egress policy blocking 169.254.169.254.
- x86 stays. Oracle's free Arm instance was the other option, but it
  would have meant multi-arch image builds in CI and capacity that is
  often unavailable. A credit-funded x86 node needs no change to the
  images.
- ADR-0006's cost argument still holds on AWS. Five RDS instances would
  cost about what five Azure Database instances would have.
- The release notes for v0.1.0 to v0.3.0 still say Azure. They record
  what was true then, so they stay as written.
