data "aws_region" "current" {}
data "aws_partition" "current" {}

data "aws_ami" "vault" {
  region      = data.aws_region.current.region
  count       = var.ami_id == "" ? 1 : 0
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "tag:Component"
    values = ["vault"]
  }
  filter {
    name   = "tag:Project"
    values = [var.project_name]
  }
  filter {
    name   = "tag:Role"
    values = ["vault-control-plane"]
  }

  filter {
    name   = "tag:BuiltBy"
    values = ["packer"]
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "node" {
  statement {
    sid       = "AutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.unseal.arn]
  }

  statement {
    sid       = "RaftAutoJoin"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTLS"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:*:parameter${local.ssm_prefix}/*"]
  }
}
