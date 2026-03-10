output "vpc_id" {
  value = module.vpc.vpc_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "ecr_repo_url" {
  value = aws_ecr_repository.reducto_api.repository_url
}
