provider "aws" {
  region = "ap-south-1"
}

variable "cluster_name" {
  default = "eks-cluster"
}

resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "eks-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = { Name = "eks-gw" }
}

resource "aws_subnet" "eks_subnets" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["ap-south-1a", "ap-south-1b"], count.index)
  map_public_ip_on_launch = true
  tags = {
    Name                                       = "eks-subnet-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = { Name = "eks-rt" }
}

resource "aws_route_table_association" "rta" {
  count          = length(aws_subnet.eks_subnets)
  subnet_id      = element(aws_subnet.eks_subnets.*.id, count.index)
  route_table_id = aws_route_table.rt.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json
}

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json
}

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ec2_container_registry_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.29"

  vpc_config {
    subnet_ids = aws_subnet.eks_subnets[*].id
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

resource "aws_eks_node_group" "managed_nodes" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "managed-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.eks_subnets[*].id
  ami_type        = "AL2_x86_64"
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ec2_container_registry_policy,
  ]
}

resource "aws_key_pair" "deployer" {
  key_name   = "eks-deployer-key"
  public_key = file("/home/ec2-user/.ssh/id_rsa.pub") # Update this path with absolute path where file exists
}

resource "aws_instance" "bastion" {
  ami                         = "ami-0d176f79571d18a8f"
  instance_type               = "t3.micro"
  subnet_id                   = element(aws_subnet.eks_subnets.*.id, 0)
  key_name                    = "terraform-key_2025_2"
  associate_public_ip_address = true

  tags = {
    Name = "bastion-host"
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file("/home/ec2-user/.ssh/id_rsa") # Update this path with absolute path
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "curl -o kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.29.0/2023-10-20/bin/linux/amd64/kubectl",
      "chmod +x ./kubectl",
      "sudo mv ./kubectl /usr/local/bin/kubectl",
      "aws eks update-kubeconfig --region ap-south-1 --name ${var.cluster_name}"
    ]
  }

  depends_on = [aws_eks_node_group.managed_nodes]
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks_cluster.endpoint
}

output "cluster_certificate_authority" {
  value = aws_eks_cluster.eks_cluster.certificate_authority[0].data
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

