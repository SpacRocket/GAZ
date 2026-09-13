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
  instance_type = "t3.small"

  vpc_security_group_ids = [module.vpc.default_security_group_id]
  subnet_id              = module.vpc.private_subnets[0]

  tags = {
    Name = "KDB"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "main-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1a", "us-east-1a"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  enable_dns_hostnames = true
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
  tags = {
    name = "kdb-fsx"
  }
}