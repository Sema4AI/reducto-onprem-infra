init-dev:
	terraform init -upgrade -reconfigure -backend-config backend-config-dev

plan-dev:
	terraform plan -var-file=dev.tfvars

apply-dev:
	terraform apply -var-file=dev.tfvars

init-prod:
	terraform init -upgrade -reconfigure -backend-config backend-config-prod

plan-prod:
	terraform plan -var-file=prod.tfvars

apply-prod:
	terraform apply -var-file=prod.tfvars

sync-image-dev:
	@test -n "$(VERSION)" || (echo "Usage: make sync-image-dev VERSION=1.10.34" && exit 1)
	aws ecr get-login-password | crane auth login 247681840182.dkr.ecr.us-east-1.amazonaws.com -u AWS --password-stdin
	crane copy proxy.reducto.ai/proxy/reducto-api/731106932034.dkr.ecr.us-west-2.amazonaws.com/reducto-api:v$(VERSION) 247681840182.dkr.ecr.us-east-1.amazonaws.com/reducto-api:v$(VERSION)

sync-image-prod:
	@test -n "$(VERSION)" || (echo "Usage: make sync-image-prod VERSION=1.10.34" && exit 1)
	aws ecr get-login-password | crane auth login 004078808828.dkr.ecr.us-east-1.amazonaws.com -u AWS --password-stdin
	crane copy proxy.reducto.ai/proxy/reducto-api/731106932034.dkr.ecr.us-west-2.amazonaws.com/reducto-api:v$(VERSION) 004078808828.dkr.ecr.us-east-1.amazonaws.com/reducto-api:v$(VERSION)
