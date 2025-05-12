init-dev:
	terraform init -upgrade -reconfigure -backend-config backend-config-dev

init-prod:
	terraform init -upgrade -reconfigure -backend-config backend-config-prod
