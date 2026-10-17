packer {
  required_plugins {
    amazon = {
      version = "~> 1.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())
}

source "amazon-ebs" "vault" {
  region        = var.region
  instance_type = var.instance_type
  profile       = "packer"
  ami_name      = "${var.project_name}-vault-${local.timestamp}"
  ssh_username  = "ubuntu"
  imds_support  = "v2.0"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd*/ubuntu-resolute-26.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Ubuntu
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name         = "${var.project_name}-vault"
    Component    = "vault"          # vault-cluster module filter
    Project      = var.project_name # vault-cluster module filter
    VaultVersion = var.vault_version == "" ? "latest" : var.vault_version
    BuiltBy      = "packer"
    Role         = "vault-control-plane"
  }
}

build {
  sources = ["source.amazon-ebs.vault"]

  provisioner "file" {
    source      = "./scripts"
    destination = "/tmp/scripts"
  }

  provisioner "shell" {
    environment_vars = ["VAULT_VERSION=${var.vault_version}"]
    inline = [
      "echo '==> Making scripts executable...'",
      "chmod +x /tmp/scripts/*.sh",

      "echo '==> Executing setup script...'",
      "sudo -E /tmp/scripts/install.sh",

      "echo '==> Cleaning up temporary upload directory...'",
      "rm -rf /tmp/scripts"
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}