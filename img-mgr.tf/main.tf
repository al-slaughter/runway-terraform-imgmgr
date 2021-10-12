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

  name                      = "${terraform.workspace}_${var.project_day}_asg"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = "${data.terraform_remote_state.vpc.outputs.private_subnets}"
  # vpc_zone_identifier       = module.vpc.private_subnets
  load_balancers            = [aws_elb.lb.id]

  # Launch configuration
  lc_name                = "${terraform.workspace}-${var.project_day}-launch-template"
  description            = "Assignment ${var.project_day}"
  update_default_version = true

  use_lc    = true
  create_lc = true

  image_id                    = "ami-087c17d1fe0178315"
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.key.key_name
  associate_public_ip_address = false
  iam_instance_profile_name   = aws_iam_instance_profile.profile.id
  security_groups             = [aws_security_group.srv_sg.id]
  user_data                   = templatefile("${path.module}/setup.sh", {BUCKET_NAME = "aws_s3_bucket.bucket.id"})
}
module "cdn" {
  source = "terraform-aws-modules/cloudfront/aws"

  origin = {
    "${terraform.workspace}-${var.project_day}-lb-cdn" = {
      domain_name          = aws_elb.lb.dns_name
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
    target_origin_id       = "${terraform.workspace}-${var.project_day}-lb-cdn"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH","DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true
  }
}
# Data and resources
## Permissions
resource "aws_security_group" "lb_sg" {
  name        = "${terraform.workspace}_${var.project_day}_lb_sg"
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

resource "aws_security_group" "srv_sg" {
  name        = "${terraform.workspace}_${var.project_day}_srv_sg"
  vpc_id      = "${data.terraform_remote_state.vpc.outputs.vpc_id}"

  ingress {
      description      = "Internet to http"
      security_groups  = [aws_security_group.lb_sg.id]
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
resource "aws_iam_instance_profile" "profile" {
    name = "${terraform.workspace}-${var.project_day}-profile"
    role = aws_iam_role.role.id
}
# Step2: Create IAM Role
resource "aws_iam_role" "role" {
    name               = "${terraform.workspace}-${var.project_day}-role"
    path               = "/"
    assume_role_policy = data.aws_iam_policy_document.ec2_assume_role_doc.json
}
# Step3: Create IAM Policy Documents
data "aws_iam_policy_document" "ec2_assume_role_doc" {
  statement{
    actions       = ["sts:AssumeRole"]
    effect        = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "s3_doc"{
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
        "${aws_s3_bucket.bucket.arn}/*"
    ]
  }
  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      "${aws_s3_bucket.bucket.arn}"
    ]
  }
}
data "aws_iam_policy_document" "ec2desctags_doc" {
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
resource "aws_iam_policy" "s3_rw" {
    name   = "${terraform.workspace}-${var.project_day}-s3-all"
    policy = data.aws_iam_policy_document.s3_doc.json
}
resource "aws_iam_policy" "ec2desctags_all" {
    name   = "${terraform.workspace}-${var.project_day}-ec2desctags-all"
    policy = data.aws_iam_policy_document.ec2desctags_doc.json
}
# Step5: Attach IAM Policies to Role
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}
resource "aws_iam_role_policy_attachment" "s3_rw" {
    role       = aws_iam_role.role.name
    policy_arn = aws_iam_policy.s3_rw.arn
}
resource "aws_iam_role_policy_attachment" "ec2desctags" {
    role       = aws_iam_role.role.name
    policy_arn = aws_iam_policy.ec2desctags_all.arn
}

## Devices
resource "aws_elb" "lb" {
    name            = "${terraform.workspace}-${var.project_day}-lb"
    subnets         = "${data.terraform_remote_state.vpc.outputs.public_subnets}"   #module.vpc.public_subnets
    security_groups = [aws_security_group.lb_sg.id]
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

resource "aws_s3_bucket" "bucket" {
  bucket_prefix = "${terraform.workspace}-${var.project_day}-"
  acl    = "private"
}

resource "aws_key_pair" "key" {
    key_name   = "${terraform.workspace}-${var.project_day}key"
    public_key = "${file("~/.ssh/test.id_rsa.pub")}"
}
