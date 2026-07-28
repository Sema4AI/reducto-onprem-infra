module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.33.1"

  # Dependency on module.eks is plumbed through the output on purpose. A
  # module-level depends_on defers every data source in this module to apply
  # time whenever module.eks has pending changes, which turns the node role's
  # policy attachments into forced replacements (policy_arn becomes unknown).
  # The detach then runs early in the apply and the re-attach is skipped if
  # anything in module.eks fails, leaving nodes unable to pull from ECR.
  cluster_name = module.eks.cluster_name

  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

# Bottlerocket's pluto calls ec2:DescribeInstances at boot to resolve the node's
# private DNS name; without it the node fails to bootstrap and powers off.
resource "aws_iam_role_policy" "karpenter_node_describe_instances" {
  name = "bottlerocket-describe-instances"
  role = module.karpenter.node_iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = "*"
    }]
  })
}

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.2.1"
  wait       = false

  values = [
    <<-EOT
    controller:
      resources:
        requests:
          cpu: 500m
          memory: 2Gi
        limits:
          memory: 2Gi
    serviceAccount:
      name: ${module.karpenter.service_account}
    settings:
      clusterName: ${var.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]
  depends_on = [
    helm_release.aws_load_balancer_controller,
    module.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
      - alias: bottlerocket@v1.63.0
      userData: |
        [settings.kubernetes]
        image-gc-low-threshold-percent = "50"
        image-gc-high-threshold-percent = "70"
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 4Gi
            volumeType: gp3
            throughput: 250
        - deviceName: /dev/xvdb
          ebs:
            volumeSize: 200Gi
            volumeType: gp3
            throughput: 250
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags:
        karpenter.sh/discovery: ${var.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            name: default
            group: karpenter.k8s.aws
            kind: EC2NodeClass
          requirements:
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: Gt
              values: ["4"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["8", "16"]
            - key: "karpenter.k8s.aws/instance-family"
              operator: In
              values: [ "c5d", "c5n", "c6a", "c6i", "c6in" ]
      disruption:
        budgets:
        - nodes: 100%
        consolidateAfter: 5s
        consolidationPolicy: WhenEmptyOrUnderutilized
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}