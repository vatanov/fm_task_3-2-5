# 0. Define variables
locals {
  allow_all_cidr = "0.0.0.0/0"
  tcp            = "tcp"
  private_ip     = "10.0.1.50"
}

# 1-5. Create VPC, subnet, Internet Gateway, route table and association
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                    = "ghostfolio-vpc" # A name prefix used for tagging and naming resources created by the module
  cidr                    = "10.0.0.0/16"    # The CIDR block for the VPC
  azs                     = ["us-east-1a"]   # List of Availability Zones to use — we use only one here for simplicity
  public_subnets          = ["10.0.1.0/24"]  # List of public subnet CIDR blocks — one per AZ above
  enable_dns_support      = true             # Enables DNS support in the VPC (required for DNS resolution)
  enable_dns_hostnames    = true             # Enables assigning hostnames to instances launched in the VPC
  create_igw              = true             # Internet Gateway (IGW) is created
  map_public_ip_on_launch = true             # Automatically assign public IPs to instances launched in public subnets

  tags = {
    Name = "ghostfolio-vpc"
  }
}

# 6. Create Security Group to allow ports 22,80,443 only
resource "aws_security_group" "allow_web" {
  name        = "allow_web"
  description = "Allow web inbound traffic"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "allow_web_traffic"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_https" {
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = local.allow_all_cidr
  from_port         = 443
  ip_protocol       = local.tcp
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "allow_http" {
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = local.allow_all_cidr
  from_port         = 80
  ip_protocol       = local.tcp
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "allow_ssh" {
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = local.allow_all_cidr
  from_port         = 22
  ip_protocol       = local.tcp
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic" {
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = local.allow_all_cidr
  ip_protocol       = "-1" # semantically equivalent to all ports
}

# 7. Create a network interface with an ip
resource "aws_network_interface" "ghostfolio_nic" {
  subnet_id       = module.vpc.public_subnets[0]
  private_ips     = [local.private_ip]
  security_groups = [aws_security_group.allow_web.id]
}

# 8. Assign an existing elastic IP to the network interface created in step 7
resource "aws_eip_association" "ghostfolio" {
  allocation_id        = "eipalloc-08db0f6e2886a95f5" # Replace with your existing EIP's allocation ID
  network_interface_id = aws_network_interface.ghostfolio_nic.id
  depends_on           = [aws_network_interface.ghostfolio_nic, module.ghostfolio_web_srv]
}

# 9. Create Linux server, install components and run ghostfolio webapp
module "ghostfolio_web_srv" {
  source               = "./modules/ec2"
  network_interface_id = aws_network_interface.ghostfolio_nic.id
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
}

# 10. Create DNS Record for EC2 Instance in Route53
resource "aws_route53_record" "ghostfolio_record" {
  zone_id = var.hosted_zone_id
  name    = "ghostfolio.atanov.pp.ua"
  type    = "A"
  ttl     = "300"
  records = [var.ec2_public_ip]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [records]
  }
}

##########################################
### Task 3.2.6: Connecting EC2 with S3 ###
##########################################
# 11. Create S3 Bucket
resource "aws_s3_bucket" "postgres_backup" {
  bucket        = "ghostfolio-db-backup"
  force_destroy = true

  tags = {
    Name = "Postgres Backup"
  }
}

# 11.1 Create policy for S3 bucket to transition backups to Glacier after one week and delete them after one month.
resource "aws_s3_bucket_lifecycle_configuration" "postgres_backup_lifecycle" {
  bucket = aws_s3_bucket.postgres_backup.id

  rule {
    id     = "transition-and-delete"
    status = "Enabled"

    filter {
      prefix = "" # Applies to all objects
    }

    transition {
      days          = 7
      storage_class = "GLACIER"
    }

    expiration {
      days = 30
    }
  }
}

# 12. Add IAM Role for EC2 with Access to S3 Bucket
resource "aws_iam_role" "backup_role" {
  name = "ec2-postgres-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "s3_backup_policy" {
  name = "s3-backup-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Effect = "Allow",
        Resource = [
          aws_s3_bucket.postgres_backup.arn,
          "${aws_s3_bucket.postgres_backup.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "backup_policy_attach" {
  role       = aws_iam_role.backup_role.name
  policy_arn = aws_iam_policy.s3_backup_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "backup-profile"
  role = aws_iam_role.backup_role.name
}

############################################
### Task 3.2.7: Getting cache out of EC2 ###
############################################

# 1. ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "ghostfolio_redis_subnet_group" {
  name       = "ghostfolio-redis-subnet-group"
  subnet_ids = module.vpc.public_subnets
}

# 2. Redis Security Group
resource "aws_security_group" "redis_sg" {
  name        = "ghostfolio-redis-sg"
  description = "Allow Redis traffic from Ghostfolio EC2"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.allow_web.id] # allow from EC2 SG
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ghostfolio-redis-sg"
  }
}

# 3. Create an ElastiCache Parameter Group
resource "aws_elasticache_parameter_group" "ghostfolio_redis_params" {
  name   = "ghostfolio-redis-params"
  family = "redis7" # Ensure this matches your desired Redis engine version

  parameter {
    name  = "requirepass"
    value = "" # Replace with your desired password, or "" for no password
  }

  tags = {
    Name = "Ghostfolio Redis Parameters"
  }
}

# 4. ElastiCache Redis Cluster
resource "aws_elasticache_cluster" "ghostfolio_redis" {
  cluster_id           = "ghostfolio-redis"
  engine               = "redis"
  node_type            = "cache.t4g.micro" # free-tier
  num_cache_nodes      = 1
  port                 = 6379
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.ghostfolio_redis_subnet_group.name
  security_group_ids   = [aws_security_group.redis_sg.id]

  tags = {
    Name = "Ghostfolio Redis"
  }
}
