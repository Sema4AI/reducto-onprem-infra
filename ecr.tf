resource "aws_ecr_repository" "reducto_api" {
  name                 = "reducto-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "reducto_api" {
  repository = aws_ecr_repository.reducto_api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 200 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["1"]
          countType     = "imageCountMoreThan"
          countNumber   = 200
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
