# EKS 1.32 → 1.33 Upgrade

Control-plane upgrades cannot be rolled back. Three applies, in order — do not
collapse them into one.

## What changes

| Where | From | To | Why |
|---|---|---|---|
| `karpenter.tf` | chart `1.2.1` | `1.5.8` | 1.2.x is `maxK8sVersion: 1.32`. Hard stop, not advice |
| `karpenter.tf` | — | new `helm_release.karpenter_crd` `1.5.8` | helm never updates CRDs shipped in a chart's `crds/` |
| `keda.tf` | `2.15.0` | `2.20.2` | 2.15 caps at k8s 1.30. **Not** 2.21 — that supports 1.34-1.36 and dropped 1.33 |
| `ingress-nginx-controller.tf` | `4.11.2` | `4.15.1` | controller 1.11.x caps at k8s 1.30 |
| `eks.tf` | `cluster_version = "1.32"` | `"1.33"` | — |

## What deliberately does not change

- **All five managed addons.** Each installed version is offered by EKS for 1.33
  (`eks-pod-identity-agent v1.3.10-eksbuild.3` is in fact the 1.33 default).
  kube-proxy stays a minor behind the control plane, which EKS allows; a future
  1.34 hop will force it.
- **`ami_type = "AL2023_x86_64_STANDARD"`.** The module derives the AMI's SSM path
  from `cluster_version`, so both managed node groups roll to the 1.33 AMI on their
  own.
- **`amiSelectorTerms: bottlerocket@v1.63.0`.** That OS release ships an
  `aws-k8s-1.33` variant. Karpenter picks the variant from the cluster version, so
  nodes still drift and need rolling (step 3) without touching the alias.
- **`setTrafficDistribution: true`** in `values/reducto.yaml` — the chart emits
  `PreferClose`, which is GA in 1.33. `PreferSameZone` is 1.34+ only; setting it
  here fails with `spec.trafficDistribution: Unsupported value`.
- **AWS Load Balancer Controller `1.11.0`.** The project publishes only a floor
  ("v2.5.0+ requires Kubernetes 1.22+") and no upper bound, so nothing published is
  violated — but v2.11.0 shipped before 1.33 existed and was never tested against
  it. This is the one component to watch after step 2.

## 0. Hand the Karpenter CRDs to helm

Once, out of band, before any apply. The three CRDs were installed by the
`karpenter` chart and carry no helm ownership metadata, so `helm_release.karpenter_crd`
will fail with `invalid ownership metadata; label validation error` without this.

```bash
for c in ec2nodeclasses.karpenter.k8s.aws nodepools.karpenter.sh nodeclaims.karpenter.sh; do
  kubectl label    crd $c app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate crd $c meta.helm.sh/release-name=karpenter-crd --overwrite
  kubectl annotate crd $c meta.helm.sh/release-namespace=kube-system --overwrite
done
```

## 1. Charts, on the 1.32 control plane

Apply the Karpenter, KEDA and ingress-nginx bumps first. All three support 1.32
and 1.33, so landing them here keeps a chart regression separate from the
control-plane change — which is the one thing you cannot undo.

```bash
make apply-<env>          # with eks.tf still on 1.32
```

Verify:

```bash
helm list -A              # karpenter-crd + karpenter 1.5.8, keda 2.20.2, ingress-nginx 4.15.1
kubectl get pods -n keda; kubectl get pods -n ingress-nginx
kubectl get apiservices | grep external.metrics    # KEDA's aggregated API Available
kubectl get scaledobjects -A                       # workers still reconciling
curl -sSfI https://<reducto_host>/ | head -1
```

Then prove Karpenter still provisions before going further — delete one worker pod
and watch a node come up:

```bash
kubectl delete pod -n reducto <a-worker-pod>
kubectl get nodeclaims -o wide -w
```

ingress-nginx is the bump with user-visible risk: controller 1.12+ tightened
annotation validation, so it can reject annotations in
`values/ingress-nginx-controller.yaml` or `values/reducto.yaml` that 1.11 accepted.

## 2. Control plane

Set `cluster_version = "1.33"` and apply. Expect ~20-30 min:

| What | Expect |
|---|---|
| Control plane | `Still modifying...` ~10-15 min, then 1.33 |
| Managed node groups (`system`/`startup`) | Roll automatically to the 1.33 AL2023 AMI |
| Karpenter nodes | Marked drifted (Bottlerocket k8s variant follows the cluster version). They do **not** roll yet |
| `helm_release.reducto` | Updated (`wait = false`; verify pods yourself) |

```bash
kubectl get nodes -o wide
for a in coredns kube-proxy vpc-cni aws-ebs-csi-driver eks-pod-identity-agent; do
  echo "$a: $(aws eks describe-addon --cluster-name reducto-ai --addon-name $a --query addon.status --output text)"
done                                                        # all ACTIVE, versions unchanged
kubectl get pods -n kube-system -l k8s-app=aws-node | grep -v "2/2"   # empty
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 | grep -i error
kubectl get pods -n reducto
```

## 3. Roll the Karpenter nodes

All reducto pods (workers AND http) carry `karpenter.sh/do-not-disrupt`, which
blocks Karpenter's automatic drift replacement indefinitely. Old nodes stay until
every annotated pod is off them; Karpenter then reaps the node itself — never
`kubectl delete node`.

**Cordon all old nodes first** so rescheduled pods can't land back on old capacity
(safe, instant, running pods untouched):

```bash
kubectl get nodes -o name -l karpenter.sh/nodepool=default | xargs kubectl cordon
# new nodes Karpenter creates come up uncordoned
```

Then empty one node at a time. See what pins it:

```bash
kubectl get pods -A --field-selector spec.nodeName=<node> --no-headers | grep -v Completed
```

- **Stateless pods (http, UI)**: `kubectl delete pod -n reducto <pod>` any time the
  sibling replica is Ready. Deployment recreates it on a new node.
- **Workers**: wait for the job to finish (the node is reaped the moment it's
  unpinned), or delete the pod when killing that job is acceptable.
- **Whole node now, jobs included** (prod: maintenance window):

  ```bash
  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --disable-eviction
  ```

Let each replacement go Ready (~3-5 min, `aws-node` 2/2) before taking the next.
Done when:

```bash
kubectl get nodes -o wide          # only aws-k8s-1.33 nodes remain, none cordoned
kubectl get nodeclaims -o wide     # no old IMAGEID rows
```

Gotcha: draining a node does not by itself make Karpenter launch a replacement —
it only provisions when pods are Pending. If a drained node's pods all fit on
existing capacity, the node just disappears.

## Failure modes

**`karpenter-crd` install fails: `invalid ownership metadata; label validation error`.**
Step 0 was skipped. Run it, then re-apply.

**Plan wants to replace/destroy Karpenter IAM attachments.**
Cause: a module-level `depends_on` deferring data sources → `policy_arn` "known
after apply" → forced replacement. This is fixed permanently (`karpenter.tf` passes
`cluster_name = module.eks.cluster_name`, no module `depends_on`). Do not apply;
find what reintroduced the deferral.

**Pods `ImagePullBackOff`, `no basic auth credentials`.**
The node role lost ECR access — this is what the destroyed IAM attachments above
look like from inside the cluster. Re-attach out of band, then bounce the stuck pods:

```bash
for P in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly AmazonEKS_CNI_Policy; do
  aws iam attach-role-policy --role-name <Karpenter-node-role> --policy-arn arn:aws:iam::aws:policy/$P
done
kubectl delete pod -n kube-system -l k8s-app=aws-node --field-selector status.phase!=Running
```

**New Karpenter nodes launch but never join; instance shows "user initiated shutdown".**
Bottlerocket calls `ec2:DescribeInstances` at boot; without it the node powers off.
Confirm `aws_iam_role_policy.karpenter_node_describe_instances` (`karpenter.tf`) is
applied. Diagnose with `aws ec2 get-console-output --instance-id <id> --latest`.

**Karpenter drains a node but no replacement appears.**
Nothing is Pending, so Karpenter has no reason to launch. Cordon the old nodes,
then delete a worker pod to force one.

**Apply fails partway; later applies 409.**
Fix the underlying problem out of band (CLI/kubectl, not terraform), wait for the
resource to settle, then re-run the full apply to reconcile state. `-target` does
not help — everything drags in `module.eks`.
