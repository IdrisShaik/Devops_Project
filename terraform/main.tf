# ============================================================
# Terraform - AWS Infrastructure for DevSecOps Pipeline
# Creates: VPC, EKS Cluster, ECR repositories, EC2 for CI tools
# ============================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # WHY: Remote state backend prevents conflicts when multiple
  # engineers run Terraform simultaneously.
  backend "s3" {
    bucket         = "devsecops-tf-state-idris"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "devsecops-tf-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "DevSecOps-Pipeline"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

# ── Data Sources ──────────────────────────────────────────────
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────
# WHY: Isolate all infra in a private VPC for security
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  # Use 3 AZs for high availability
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false  # One per AZ for HA
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # WHY: Required tags for AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

# ── EC2 Instance for CI Tools (Jenkins + SonarQube + Nexus) ──
# WHY: A dedicated EC2 instance runs all CI tools via Docker Compose
resource "aws_instance" "ci_server" {
  ami           = var.ubuntu_ami_id  # Ubuntu 22.04 LTS
  instance_type = "t3.xlarge"        # 4 vCPU, 16GB RAM - needed for all 3 tools

  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.ci_server_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.devops_key.key_name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    encrypted   = true
  }

  # WHY: User data script bootstraps the server on first boot
  user_data = base64encode(file("${path.module}/../scripts/install-tools.sh"))

  tags = {
    Name = "${var.project_name}-ci-server"
    Role = "ci"
  }
}

# ── SSH Key Pair ──────────────────────────────────────────────
resource "aws_key_pair" "devops_key" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# ── Elastic IP for CI Server ──────────────────────────────────
resource "aws_eip" "ci_server_eip" {
  instance = aws_instance.ci_server.id
  domain   = "vpc"
  tags = {
    Name = "${var.project_name}-ci-eip"
  }
}
