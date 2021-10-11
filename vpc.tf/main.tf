# Backend setup
terraform {
  backend "s3" {
    bucket = "${var.bucket}"
    region = "${var.region}"
    key    = "vpc.tfstate"
  }
}

# Variable definitions
variable "region" {}

# Provider and access setup
provider "aws" {
  region = "${var.region}"
}

# Modules
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name   = "day49-vpc"
  cidr   = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  reuse_nat_ips          = false
}
output "vpc_id" {
  value = module.vpc.vpc_id
}
output "private_subnets" {
  value = module.vpc.private_subnets
}
output "public_subnets" {
  value = module.vpc.public_subnets
}
