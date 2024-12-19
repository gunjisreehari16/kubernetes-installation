# Configure the AWS Provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1" # Replace with your AWS region
}

# Create a VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "eks-vpc"
  }
}

# Create Subnets for EKS Nodes
resource "aws_subnet" "private" {
  count = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index * 10}.0/24" # Adjust CIDR block to avoid overlaps
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "eks-private-subnet-${count.index}"
  }
}

# Variable for availability zones
variable "availability_zones" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"] # Adjust as per your region
}

# Create a Security Group for EKS Nodes
resource "aws_security_group" "eks_nodes" {
  name        = "eks-nodes"
  description = "Security Group for EKS Nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["192.168.1.0/24"] # Replace with your trusted CIDR range
  }

  ingress {
    from_port   = 10250
    to_port     = 10259
    protocol    = "tcp"
    cidr_blocks = ["192.168.1.0/24"] # Replace with your trusted CIDR range
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-nodes-sg"
  }
}

# Create an IAM Role for the EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eksClusterRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# Attach an IAM Policy to the IAM Role
resource "aws_iam_policy" "eks_cluster_policy" {
  name = "eksClusterPolicy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "iam:GetRole",
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_cluster_role_attachment" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = aws_iam_policy.eks_cluster_policy.arn
}

# Create an IAM Role for EKS Nodes
resource "aws_iam_role" "eks_nodes_role" {
  name = "eksNodesRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_nodes_role_attachment" {
  role       = aws_iam_role.eks_nodes_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_ecr_attachment" {
  role       = aws_iam_role.eks_nodes_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Create an EKS Cluster
resource "aws_eks_cluster" "my_cluster" {
  name     = "my-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids              = [for subnet in aws_subnet.private : subnet.id]
    security_group_ids      = [aws_security_group.eks_nodes.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  tags = {
    Name = "eks-cluster"
  }
}

# Data block for Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*"]
  }
}

# Create an IAM Instance Profile for EKS Nodes
resource "aws_iam_instance_profile" "eks_nodes" {
  name = "eksNodesInstanceProfile"
  role = aws_iam_role.eks_nodes_role.name
}

# Create a Launch Template for EKS Nodes
resource "aws_launch_template" "eks_nodes" {
  name = "eks-nodes-template"
  image_id = data.aws_ami.amazon_linux_2.id
  instance_type = "t2.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.eks_nodes.name
  }

  network_interfaces {
    security_groups = [aws_security_group.eks_nodes.id]
  }

  user_data = base64encode(<<EOF
#!/bin/bash
exec > >(tee /var/log/user-data.log) 2>&1
yum update -y
yum install -y aws-cli
EOF
  )
}

# Create an Auto Scaling Group for EKS Nodes
resource "aws_autoscaling_group" "eks_nodes" {
  name                    = "eks-nodes"
  min_size                = 1
  max_size                = 2
  desired_capacity        = 1
  vpc_zone_identifier     = [for subnet in aws_subnet.private : subnet.id]
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = "$Latest"
  }
  force_delete            = true
  health_check_type       = "EC2"

  tag {
    key                 = "Name"
    value               = "eks-node"
    propagate_at_launch = true
  }
}

