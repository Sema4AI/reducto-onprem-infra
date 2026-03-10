resource "kubectl_manifest" "gcp_credentials_secret" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "gcp-credentials"
      namespace = "reducto"
    }
    type = "Opaque"
    stringData = {
      "credentials.json" = file("dev-service-account.json")
    }
  })

  depends_on = [module.eks]
}

resource "helm_release" "reducto" {
  namespace        = "reducto"
  name             = "reducto"
  create_namespace = true

  repository_username = var.reducto_helm_repo_username
  repository_password = var.reducto_helm_repo_password

  chart   = var.reducto_helm_chart
  version = var.reducto_helm_chart_version
  wait    = false
  # force_update  = true  # TODO: remove after successful deploy

  # Use a local ECR in the hopes of faster pod startup (11GB uncompressed container image)
  values = [
    "${file("values/reducto.yaml")}",
    <<-EOT
    image:
      repository: ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/reducto-api
      tag: v${var.reducto_helm_chart_version}
      pullPolicy: IfNotPresent
      pullSecretName: ""
    ingress:
      host: ${var.reducto_host}
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${aws_iam_role.reducto.arn}
    env:
      DATABASE_URL: ${local.database_url}
      BUCKET: ${aws_s3_bucket.reducto_storage.bucket}
      OPENAI_API_KEY: ${var.openai_api_key}
      SKIP_AUTH: 1
      LOGFIRE_TOKEN: ${var.logfire_token}
      LOGFIRE_ENVIRONMENT: ${var.logfire_environment}
      GCP_PROJECT_ID: ${var.gcp_project_id}
      GCP_REGION: ${var.gcp_region}
      GCP_API_KEY: ${var.gcp_api_key}
      GCP_OCR_ONLY: "true"
    EOT
  ]

  depends_on = [
    module.eks,
    module.rds,
    aws_s3_bucket.reducto_storage,
    aws_iam_role.reducto,
    helm_release.ingress_nginx,
    helm_release.karpenter,
    helm_release.keda,
    kubectl_manifest.gcp_credentials_secret,
    # helm_release.cert_manager,
    aws_ecr_repository.reducto_api,
  ]
}
