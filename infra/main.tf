# 0. Define variables
locals {
  allow_all_cidr = "0.0.0.0/0"
  tcp            = "tcp"
  private_ip     = "10.0.1.50"
}

# # 1. Create vpc
# resource "aws_vpc" "ghostfolio_vpc" {
#   cidr_block       = "10.0.0.0/16"
#   instance_tenancy = "default"

#   tags = {
#     Name = "ghostfolio_vpc"
#   }
# }

# # 2. Create Internet Gateway
# resource "aws_internet_gateway" "ghostfolio_gw" {
#   vpc_id = aws_vpc.ghostfolio_vpc.id

#   tags = {
#     Name = "ghostfolio_gw"
#   }
# }

# # 3. Create Custom Route Table
# resource "aws_route_table" "ghostfolio_rt" {
#   vpc_id = aws_vpc.ghostfolio_vpc.id

#   route {
#     cidr_block = local.allow_all_cidr
#     gateway_id = aws_internet_gateway.ghostfolio_gw.id
#   }

#   tags = {
#     Name = "ghostfolio_rt"
#   }
# }

# # 4. Create a Subnet
# resource "aws_subnet" "ghostfolio_subnet" {
#   vpc_id            = aws_vpc.ghostfolio_vpc.id
#   cidr_block        = "10.0.1.0/24"
#   availability_zone = "us-east-1a"

#   tags = {
#     Name = "ghostfolio_subnet"
#   }
# }

# # 5. Associate subnet with Route Table
# resource "aws_route_table_association" "ghostfolio_subnet_and_rt_association" {
#   subnet_id      = aws_subnet.ghostfolio_subnet.id
#   route_table_id = aws_route_table.ghostfolio_rt.id
# }

# 1. Create VPC, subnet, Internet Gateway, route table and association
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "ghostfolio-vpc"
  cidr = "10.0.0.0/16"
  azs = ["us-east-1a"]
  public_subnets = ["10.0.1.0/24"]
  enable_dns_support = true
  enable_dns_hostnames = true
  create_igw = true
  map_public_ip_on_launch = true
  create_multiple_public_route_tables = true

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
  depends_on           = [aws_internet_gateway.ghostfolio_gw, aws_network_interface.ghostfolio_nic, module.ghostfolio_web_srv]
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
