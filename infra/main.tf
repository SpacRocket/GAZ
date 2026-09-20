# The resources themselves.
#
# How the instance acquires the hostname process.csv is expecting — EC2 will give it
# something like ip-10-0-1-23.<region>.compute.internal otherwise.

provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "rocky" {
  most_recent = true
  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-9*.x86_64*"]
  }
  owners = ["aws-marketplace"]
}

resource "aws_instance" "kdb_box" {
  ami           = data.aws_ami.rocky.id
  instance_type = "t3.medium"

  vpc_security_group_ids = [aws_security_group.kdb_box.id]
  subnet_id              = module.vpc.public_subnets[0]

  # Provisioning lives in user_data.sh, not inline: it now writes a systemd
  # unit and two heredocs, which a nested Terraform heredoc renders unreadable.
  # Referencing the bucket and the parameter here also gives Terraform the
  # implicit dependency edges -- the instance cannot boot before either exists.
  user_data = templatefile("${path.module}/user_data.sh", {
    region       = data.aws_region.current.name
    fsx_dns      = aws_fsx_openzfs_file_system.fsx_kdb.dns_name
    bucket       = aws_s3_bucket.kdb_code.bucket
    lic_param    = aws_ssm_parameter.kx_lic.name
    entsoe_param = aws_ssm_parameter.entsoe_key.name
  })

  user_data_replace_on_change = true
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.kdb_ec2.name
  depends_on                  = [aws_iam_role_policy_attachment.ssm]

  tags = {
    Name = "KDB"
  }
}

resource "aws_security_group" "kdb_box" {
  name        = "kdb-box"
  description = "SSH from the operator only"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "All outbound - dnf mirrors and NFS to FSx"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "kdb_ec2" {
  name = "kdb-box-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.kdb_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "kdb_ec2" {
  name = "kdb-box-ec2"
  role = aws_iam_role.kdb_ec2.name
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "main-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1a", "us-east-1a"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  enable_dns_hostnames    = true
  map_public_ip_on_launch = true
}

resource "aws_security_group" "fsx" {
  name        = "kdb-fsx"
  description = "NFS access to the OpenZFS file system from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  dynamic "ingress" {
    for_each = var.fsx_required_ports
    iterator = port
    content {
      description = "NFS ancillary TCP ${port.value}"
      from_port   = port.value
      to_port     = port.value
      protocol    = "tcp"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  dynamic "ingress" {
    for_each = var.fsx_required_ports
    iterator = port
    content {
      description = "NFS ancillary UDP ${port.value}"
      from_port   = port.value
      to_port     = port.value
      protocol    = "udp"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  tags = { Name = "kdb-fsx-sg" }
}

resource "aws_fsx_openzfs_file_system" "fsx_kdb" {
  deployment_type     = "SINGLE_AZ_1"
  storage_capacity    = 64
  throughput_capacity = 64
  subnet_ids          = [module.vpc.private_subnets[0]]
  security_group_ids  = [aws_security_group.fsx.id]

  # skip_final_backup is read from STATE at destroy time, so it must be here
  # from the first apply or destroy leaves a backup quietly billing.
  automatic_backup_retention_days = 0
  skip_final_backup               = true

  # FSx for OpenZFS squashes root by default: a directory the instance creates
  # as root lands owned by 65534:65534 and chown fails EPERM, so the containers
  # (uid 6000, see docker/Dockerfile) could never write the HDB. Lifting it lets
  # gaz-bootstrap set ownership once. Scoped by aws_security_group.fsx, which
  # admits NFS only from inside the VPC.
  root_volume_configuration {
    nfs_exports {
      client_configurations {
        clients = "*"
        options = ["rw", "crossmnt", "no_root_squash"]
      }
    }
  }
  tags = {
    name = "kdb-fsx"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_s3_bucket" "kdb_code" {
  bucket = "gaz-kdb-code-${data.aws_caller_identity.current.account_id}"

  force_destroy = false

  tags = {
    Name = "gaz-kdb-code"
  }
}

resource "aws_iam_role_policy" "s3_code" {
  name = "kdb-box-s3-code"
  role = aws_iam_role.kdb_ec2.id # same role the instance profile already wraps

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.kdb_code.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.kdb_code.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.kdb_code.arn}/artifacts/*"
      }
    ]
  })
}

# kdb+ licence. Needed as KX_B64_LIC at image build and mounted at /etc/kdb at
# runtime; gaz-bootstrap fetches it at boot. Written out of band, once:
#
#   aws ssm put-parameter --name /gaz/kx/kc_lic_b64 --type SecureString \
#     --overwrite --value "$(base64 < ~/Applications/q/kc.lic | tr -d '\n')"
#
# Keeping the value out of the config keeps it out of GIT, not out of STATE:
# .value is `computed`, so refresh reads it back decrypted into tfstate. Fine
# here (state is local and gitignored) but it is the reason this is not a
# general-purpose secret store. ignore_changes takes attribute NAMES, not a
# bool, and stops the next apply reverting the real licence to the placeholder.
#
# No IAM policy needed: aws/ssm is an AWS-managed key whose key policy already
# allows Decrypt to the account via kms:ViaService=ssm, and a resource-policy
# allow suffices same-account. A customer-managed key would need one.
resource "aws_ssm_parameter" "kx_lic" {
  name        = "/gaz/kx/kc_lic_b64"
  description = "base64 of kc.lic. Real value written out of band - see main.tf."
  type        = "SecureString" # encrypted under the account's aws/ssm key
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}

# ENTSO-E API key. Same shape and same trade-off as the licence above.
#
#   aws ssm put-parameter --name /gaz/entsoe/api_key --type SecureString \
#     --overwrite --value "$ENTSOE_API_KEY"
#
# Unlike the licence this one is OPTIONAL at boot -- the stack comes up without
# it and only the feed is dead, so gaz-bootstrap tolerates a placeholder here
# rather than refusing to start.
resource "aws_ssm_parameter" "entsoe_key" {
  name        = "/gaz/entsoe/api_key"
  description = "ENTSO-E API key. Real value written out of band - see main.tf."
  type        = "SecureString"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}
