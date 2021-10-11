# Backend setup
terraform {
  backend "s3" {
    bucket = "${var.bucket}"
    region = "${var.region}"
    key    = "imgmgr.tfstate"
  }
}
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "cfngin-alsday49vpcterraformtop-us-east-1"
    region = "${var.region}"
    key    = "env:/common/vpc.tfstate"
  }
}

# Variable definitions
variable "region" {}

# Provider and access setup
provider "aws" {
  region = "${var.region}"
}

# Modules
module "asg" {
  source = "terraform-aws-modules/autoscaling/aws"

  name                      = "day49_asg"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = "${data.terraform_remote_state.vpc.outputs.private_subnets}"
  # vpc_zone_identifier       = module.vpc.private_subnets
  load_balancers            = [aws_elb.day49_lb.id]

  # Launch configuration
  lc_name                = "day49-launch-template"
  description            = "Assignment day 49"
  update_default_version = true

  use_lc    = true
  create_lc = true

  image_id                    = "ami-087c17d1fe0178315"
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.day49_key.key_name
  associate_public_ip_address = false
  iam_instance_profile_name   = aws_iam_instance_profile.day49_profile.id
  security_groups             = [aws_security_group.day49_srv_sg.id]
  user_data                   = templatefile("${path.module}/setup.sh", {BUCKET_NAME = aws_s3_bucket.day49_bucket.id})
}
module "cdn" {
  source = "terraform-aws-modules/cloudfront/aws"

  origin = {
    day49-lb-cdn = {
      domain_name          = aws_elb.day49_lb.dns_name
      custom_origin_config = {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.1", "TLSv1.2"]
      }
    }
  }
  viewer_certificate = {
    cloudfront_default_certificate = true
  }
  default_cache_behavior = {
    target_origin_id       = "day49-lb-cdn"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH","DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true
  }
}
# Data and resources
## Permissions
resource "aws_security_group" "day49_lb_sg" {
  name        = "day49_lb_sg"
  vpc_id      = "${data.terraform_remote_state.vpc.outputs.vpc_id}"  #module.vpc.vpc_id

  ingress {
      description      = "Allow all inbound"
      from_port        = 80
      to_port          = 80
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
    }

  egress {
      description      = "Allow all outbound"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
    }
}

resource "aws_security_group" "day49_srv_sg" {
  name        = "day49_srv_sg"
  vpc_id      = "${data.terraform_remote_state.vpc.outputs.vpc_id}"

  ingress {
      description      = "Internet to http"
      security_groups  = [aws_security_group.day49_lb_sg.id]
      from_port        = 80
      to_port          = 80
      protocol         = "tcp"
    }

  egress {
      description      = "Allow all outbound"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
    }
}

# Step1: Create IAM Instance Profile
resource "aws_iam_instance_profile" "day49_profile" {
    name = "day49-profile"
    role = aws_iam_role.day49_role.id
}
# Step2: Create IAM Role
resource "aws_iam_role" "day49_role" {
    name               = "day49-role"
    path               = "/"
    assume_role_policy = data.aws_iam_policy_document.day49_ec2_assume_role_doc.json
}
# Step3: Create IAM Policy Documents
data "aws_iam_policy_document" "day49_ec2_assume_role_doc" {
  statement{
    actions       = ["sts:AssumeRole"]
    effect        = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "day49_s3_doc"{
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
        "${aws_s3_bucket.day49_bucket.arn}/*"
    ]
  }
  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.day49_bucket.arn
    ]
  }
}
data "aws_iam_policy_document" "day49_ec2desctags_doc" {
  statement {
    actions = [
      "ec2:DescribeTags"
    ]
    resources = [
      "*"
    ]
  }
}
# Step4: Create IAM Policy
resource "aws_iam_policy" "day49_s3_rw" {
    name   = "day49-s3-all"
    policy = data.aws_iam_policy_document.day49_s3_doc.json
}
resource "aws_iam_policy" "day49_ec2desctags_all" {
    name   = "day49-ec2desctags-all"
    policy = data.aws_iam_policy_document.day49_ec2desctags_doc.json
}
# Step5: Attach IAM Policies to Role
resource "aws_iam_role_policy_attachment" "day49_ssm" {
  role       = aws_iam_role.day49_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}
resource "aws_iam_role_policy_attachment" "day49_s3_rw" {
    role       = aws_iam_role.day49_role.name
    policy_arn = aws_iam_policy.day49_s3_rw.arn
}
resource "aws_iam_role_policy_attachment" "day49_ec2desctags" {
    role       = aws_iam_role.day49_role.name
    policy_arn = aws_iam_policy.day49_ec2desctags_all.arn
}

## Devices
resource "aws_elb" "day49_lb" {
    name            = "day-49-lb"
    subnets         = "${data.terraform_remote_state.vpc.outputs.public_subnets}"   #module.vpc.public_subnets
    security_groups = [aws_security_group.day49_lb_sg.id]
    listener {
      instance_port     = 80
      instance_protocol = "http"
      lb_port           = 80
      lb_protocol       = "http"
    }
    health_check {
      healthy_threshold   = 2
      unhealthy_threshold = 2
      timeout             = 5
      target              = "HTTP:80/"
      interval            = 10
    }
}

resource "aws_s3_bucket" "day49_bucket" {
  bucket = "day49-top-bucket"
  acl    = "private"
}

resource "aws_key_pair" "day49_key" {
    key_name   = "day49key"
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC61X0A1dzci/UHW6uzkLSsdEPdpK1l7UnD3589mJq5uOuHfNtI6wUGSqj/Vgj7aXAImzNvmr7p+dsLstzkqT9zmY7bQh5vLxSr71Swq6MnOqvo7LbZHj/ynekgACRXbEmKx0JV2oZGowxon91/ESds9BGELGxOLsiSGXFk5QMij2xIln4FrpISEZjeSOeO+Q4cPR21s7/LP384V6+3/OTfrfDLI/fS91UWUuyvbD+YXvKVKayjqMRZYbabBmgCeLf3Le+TsPf7RX1IFyK6se0P3zLov52GQFSuVrUnY57nREuG7Qulv3Wn+hIQWvadKzFqT9S8wj/G7Qju6QlaWOLx"
}
