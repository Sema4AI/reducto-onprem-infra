# EKS Upgrade Runbook

One Kubernetes minor per hop (1.31 → 1.32 → 1.33). Control-plane upgrades
cannot be rolled back. Addons must be bumped in the same hop (kube-proxy may
not lag more than one minor).

## 1. Apply

```bash
make apply-<env>
```

Expected, in order (~20–30 min total):

| What | Expect |
|---|---|
| Control plane | `Still modifying...` ~10–15 min, then 1.3x+1 |
| Addons | Updated to the pins; DaemonSets roll |
| Managed node groups (`system`/`startup`) | Roll automatically to new AMI |
| Karpenter EC2NodeClass | Alias updated; existing nodes marked drifted (they do NOT roll yet) |
| helm_release.reducto | Updated (has `wait = false`; verify pods yourself) |

Verify:

```bash
kubectl get nodes -o wide                                   # MNG nodes on target version
for a in coredns kube-proxy vpc-cni aws-ebs-csi-driver eks-pod-identity-agent; do
  echo "$a: $(aws eks describe-addon --cluster-name reducto-ai --addon-name $a --query addon.status --output text)"
done                                                        # all ACTIVE
kubectl get pods -n kube-system -l k8s-app=aws-node | grep -v "2/2"   # empty
kubectl get pods -n reducto                                 # Running/Completed
```

## 4. Roll the Karpenter nodes

All reducto pods (workers AND http) carry `karpenter.sh/do-not-disrupt`, which
blocks Karpenter's automatic drift replacement indefinitely. Old nodes stay
until every annotated pod is off them; Karpenter then reaps the node itself —
never `kubectl delete node`.

**Cordon all old nodes first** so rescheduled pods can't land back on old
capacity (safe, instant, running pods untouched):

```bash
kubectl get nodes -o name -l karpenter.sh/nodepool=default | xargs kubectl cordon
# new nodes Karpenter creates come up uncordoned
```

Then empty one node at a time. See what pins it:

```bash
kubectl get pods -A --field-selector spec.nodeName=<node> --no-headers | grep -v Completed
```

- **Stateless pods (http, UI)**: `kubectl delete pod -n reducto <pod>` any
  time the sibling replica is Ready. Deployment recreates it on a new node.
- **Workers**: wait for the job to finish (node is reaped the moment it's
  unpinned), or delete the pod when killing that job is acceptable.
- **Whole node now, jobs included** (prod: maintenance window):

  ```bash
  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --disable-eviction
  ```

Let each replacement go Ready (~3–5 min, `aws-node` 2/2) before taking the next
node. Done when:

```bash
kubectl get nodes -o wide          # only new-AMI nodes remain, none cordoned
kubectl get nodeclaims -o wide     # no old IMAGEID rows
```

Gotcha: draining a node does not by itself make Karpenter launch a replacement
— it only provisions when pods are Pending. If a drained node's pods all fit on
existing capacity, the node just disappears.

## Failure modes

**Plan wants to replace/destroy Karpenter IAM attachments.**
Cause: module-level `depends_on` deferring data sources → `policy_arn`
"known after apply" → forced replacement. This should be fixed permanently
(`karpenter.tf` passes `cluster_name = module.eks.cluster_name`, no module
`depends_on`). Do not apply; find what reintroduced the deferral.

**Apply fails / is interrupted; addons stuck `UPDATING`; later applies 409.**
Every apply will 409 until the addon converges, and the addon usually can't
converge because pods can't pull. Fix the pull problem out-of-band (CLI/kubectl,
not terraform), wait for `ACTIVE`, then re-run the full apply to reconcile
state. `-target` does not help — everything drags in `module.eks`.

**Pods `ImagePullBackOff`, `no basic auth credentials`.**
The node role lost ECR access (this is what the destroyed IAM attachments look
like from the cluster). Re-attach out-of-band, then bounce the stuck pods:

```bash
for P in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly AmazonEKS_CNI_Policy; do
  aws iam attach-role-policy --role-name <Karpenter-node-role> --policy-arn arn:aws:iam::aws:policy/$P
done
kubectl delete pod -n kube-system -l k8s-app=aws-node --field-selector status.phase!=Running
```

**New Karpenter nodes launch but never join, instance shows "user initiated
shutdown".**
Bottlerocket ≥ ~1.30 calls `ec2:DescribeInstances` at boot; without it the node
powers off. Confirm `aws_iam_role_policy.karpenter_node_describe_instances`
(karpenter.tf) is applied. Diagnose via
`aws ec2 get-console-output --instance-id <id> --latest`.

**Karpenter drains a node but no replacement appears.**
Nothing is Pending, so Karpenter has no reason to launch. Cordon the old
Karpenter nodes, then delete a worker pod to force a launch.

**helm fails: `spec.trafficDistribution: Unsupported value: "PreferSameZone"`.**
The Reducto chart emits `PreferSameZone` on k8s ≥1.31 but it's only valid on
1.34+. Keep `setTrafficDistribution: "PreferClose"` in `values/reducto.yaml`
until the cluster is on 1.34.

