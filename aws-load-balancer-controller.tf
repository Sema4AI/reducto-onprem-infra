module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.52.2"

  role_name                              = "${var.cluster_name}-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  namespace  = "kube-system"
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.11.0"

  values = [
    <<-EOT
    clusterName: ${var.cluster_name}
    # Karpenter nodes set an IMDS hop limit of 1, so pods cannot discover these themselves
    region: ${var.region}
    vpcId: ${module.vpc.vpc_id}
    serviceAccount:
      create: true
      name: aws-load-balancer-controller
      annotations:
        eks.amazonaws.com/role-arn: ${module.load_balancer_controller_irsa_role.iam_role_arn}
    tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    # Setting affinity disables the chart's configureDefaultAffinity block, so the
    # default podAntiAffinity is repeated here
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: worker-type
              operator: In
              values:
              - system
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                - aws-load-balancer-controller
            topologyKey: kubernetes.io/hostname
    EOT
  ]

  depends_on = [
    module.eks,
    module.load_balancer_controller_irsa_role,
  ]
}