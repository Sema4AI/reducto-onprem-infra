data "aws_secretsmanager_secret" "datadog_api_key" {
  name = "datadog/api-key"
}

data "aws_secretsmanager_secret_version" "datadog_api_key" {
  secret_id = data.aws_secretsmanager_secret.datadog_api_key.id
}

resource "helm_release" "datadog_agent" {
  name             = "datadog-agent"
  repository       = "https://helm.datadoghq.com"
  chart            = "datadog"
  namespace        = "datadog"
  create_namespace = true

  values = [
    templatefile("${path.module}/values/datadog-agent.yaml", {
      datadog_api_key = data.aws_secretsmanager_secret_version.datadog_api_key.secret_string
      datadog_site    = var.datadog_site
      cluster_name    = var.cluster_name
      environment     = var.logfire_environment
    })
  ]

  depends_on = [
    module.eks
  ]
}

