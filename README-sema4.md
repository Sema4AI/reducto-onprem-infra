# One-time setup steps

* We did not use Cloudflare+LetsEncrypt. We manually created a cert in ACM and used that instead. Sampo did this.
* On a fresh AWS account, we had to run `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com` before Karpenter would autoscale.
* The initial `terraform apply` is likely to fail on applying helm/karpenter changes. Just re-run it.

Create the files: `dev.tfvars` and `prod.tfvars`. These should contain the following:

```
reducto_helm_repo_username = "ram@sema4.ai"
reducto_helm_repo_password = "..."
reducto_host = "reducto.sema4ai.dev"
openai_api_key = "..."
reducto_nlb_cert_arn = "..."
logfire_environment = "..."
logfire_token = "..."
datadog_site = "datadoghq.com"
```

`logfire_environment` should be `dev` or `prod` (depending on the file). `logfire_token` comes from the 1password
item named "On Prem Reducto on-prem Pydantic Logfire".

`datadog_site` should be `datadoghq.com` for US1 (default).

## Choosing environments

We use the partial configuration of backend to support multiple environments.

Before running a `terraform plan|apply`, run the corresponding `make init-dev` or `make init-prod` to
reconfigure your local Terraform project for the dev/prod environment.

Then, the corresponding make targets `make plan-dev`/`make plan-prod` or `make apply-dev`/`make apply-prod`.

## Datadog Log Shipping

Logs from all pods in the `reducto` namespace are shipped to Datadog. The Datadog agent is deployed as a DaemonSet
and automatically collects logs using Kubernetes autodiscovery.

### Prerequisites

The Datadog API key must be stored in AWS Secrets Manager with the name `datadog/api-key`. Terraform will automatically
read this secret at deployment time. Make sure the secret exists in your AWS account before running terraform apply.

To create the secret:
```bash
aws secretsmanager create-secret --name datadog/api-key --secret-string "your-datadog-api-key"
```

### Verifying Log Collection

After deployment, verify that logs are being collected:

1. Check that Datadog agent pods are running:
   ```bash
   kubectl get pods -n datadog
   ```

2. Check agent logs for any errors:
   ```bash
   kubectl logs -n datadog -l app=datadog-agent
   ```

3. In Datadog UI, navigate to Logs > Explorer and filter by:
   - `kube_namespace:reducto`
   - `kube_cluster_name:reducto-ai`
   - `env:dev` or `env:prod`

Logs should appear within a few minutes of deployment.
