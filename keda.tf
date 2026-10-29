# KEDA 2.21 supports Kubernetes 1.34-1.36 and drops 1.33
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.20.2"
  namespace        = "keda"
  create_namespace = true

  values = [
    "${file("values/keda.yaml")}"
  ]

  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller,
  ]
}
