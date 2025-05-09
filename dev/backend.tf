terraform {
  backend "s3" {
    bucket = "reducto-terraform-states-account-247681840182"
    key    = "reducto"
    region = "us-east-1"
  }
}
