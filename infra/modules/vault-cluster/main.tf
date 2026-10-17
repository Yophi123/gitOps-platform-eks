locals {
  ami_id     = var.ami_id != "" ? var.ami_id : data.aws_ami.vault[0].id
  ssm_prefix = "/${var.name}"

  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

## KMS key for auto-unseal
resource "aws_kms_key" "unseal" {
  description             = "${var.name} auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge({ "Name" = "${var.name}-unseal" }, local.tags)
}

resource "aws_kms_alias" "unseal" {
  name          = "alias/${var.name}-unseal"
  target_key_id = aws_kms_key.unseal.key_id
}

## TLS: private CA + server cert (NLB name, Raft peer name, localhost)
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years

  subject {
    common_name  = "${var.name} CA"
    organization = var.project_name
  }

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

resource "tls_private_key" "server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name  = "vault.internal"
    organization = var.project_name
  }

  dns_names    = [aws_lb.this.dns_name, "vault.internal", "localhost"]
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem      = tls_cert_request.server.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8760 # 1 year

  allowed_uses = ["server_auth", "client_auth", "digital_signature", "key_encipherment"]
}

resource "aws_ssm_parameter" "ca" {
  name  = "${local.ssm_prefix}/tls/ca"
  type  = "String"
  value = tls_self_signed_cert.ca.cert_pem
  tags  = local.tags
}

resource "aws_ssm_parameter" "cert" {
  name  = "${local.ssm_prefix}/tls/cert"
  type  = "String"
  value = tls_locally_signed_cert.server.cert_pem
  tags  = local.tags
}

resource "aws_ssm_parameter" "key" {
  name  = "${local.ssm_prefix}/tls/key"
  type  = "SecureString"
  value = tls_private_key.server.private_key_pem
  tags  = local.tags
}

## Security groups
resource "aws_security_group" "nlb" {
  name        = "${var.name}-nlb"
  description = "Vault NLB: 8200 from clients"
  vpc_id      = var.vpc_id
  tags        = merge({ "Name" = "${var.name}-nlb" }, local.tags)
}

resource "aws_vpc_security_group_ingress_rule" "nlb_clients" {
  for_each = var.client_security_groups

  security_group_id            = aws_security_group.nlb.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 8200
  to_port                      = 8200
  description                  = "Vault API from ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_vault" {
  security_group_id            = aws_security_group.nlb.id
  referenced_security_group_id = aws_security_group.vault.id
  ip_protocol                  = "tcp"
  from_port                    = 8200
  to_port                      = 8200
  description                  = "To Vault nodes"
}

resource "aws_security_group" "vault" {
  name        = "${var.name}-nodes"
  description = "Vault nodes: API from the NLB, API and cluster from peers"
  vpc_id      = var.vpc_id
  tags        = merge({ "Name" = "${var.name}-nodes" }, local.tags)
}

resource "aws_vpc_security_group_ingress_rule" "vault_from_nlb" {
  security_group_id            = aws_security_group.vault.id
  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = 8200
  to_port                      = 8200
  description                  = "API and health checks from the NLB"
}

resource "aws_vpc_security_group_ingress_rule" "vault_peers" {
  for_each = toset(["8200", "8201"])

  security_group_id            = aws_security_group.vault.id
  referenced_security_group_id = aws_security_group.vault.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  description                  = "Raft join (8200) and cluster traffic (8201) between peers"
}

resource "aws_vpc_security_group_egress_rule" "vault_all" {
  security_group_id = aws_security_group.vault.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "KMS, SSM, EC2 API, RDS, EKS OIDC discovery"
}

## Internal NLB
resource "aws_lb" "this" {
  name                             = substr("${var.name}-nlb", 0, 32)
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.nlb.id]
  enable_cross_zone_load_balancing = true

  tags = local.tags
}

resource "aws_lb_target_group" "this" {
  name                 = substr("${var.name}-tg", 0, 32)
  port                 = 8200
  protocol             = "TCP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  preserve_client_ip   = false
  deregistration_delay = 30

  # Standbys report healthy too: they forward requests to the active node
  health_check {
    protocol            = "HTTPS"
    port                = "8200"
    path                = "/v1/sys/health?standbyok=true&perfstandbyok=true"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8200
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

## Instance role
resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "node" {
  name   = "vault"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name}-node"
  role = aws_iam_role.node.name
}

## Launch template + ASG
resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-"
  image_id               = local.ami_id
  instance_type          = var.instance_type
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.vault.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    region     = data.aws_region.current.region
    name       = var.name
    ssm_prefix = local.ssm_prefix
    kms_key_id = aws_kms_key.unseal.key_id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge({
      "Name"          = var.name
      "vault-cluster" = var.name # Raft auto-join discovers peers by this tag
    }, local.tags)
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge({ "Name" = var.name }, local.tags)
  }

  tags = local.tags

  depends_on = [aws_ssm_parameter.ca, aws_ssm_parameter.cert, aws_ssm_parameter.key]
}

resource "aws_autoscaling_group" "this" {
  name                = var.name
  min_size            = var.node_count
  max_size            = var.node_count
  desired_capacity    = var.node_count
  vpc_zone_identifier = var.subnet_ids
  target_group_arns   = [aws_lb_target_group.this.arn]

  # EC2 checks only: before init every node fails the NLB check, and ELB
  # health checks would make the ASG replace them in a loop
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false # instance tags come from the launch template
    }
  }
}