provider "aws" {
  region = "us-west-2"
}

# Random string for unique role name
resource "random_string" "unique_suffix" {
  length  = 8
  special = false
}

# Fetch Default VPC
data "aws_vpc" "default" {
  default = true
}

# Fetch All Public Subnets in Default VPC
data "aws_subnets" "public_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Create OIDC Provider for EKS
resource "aws_iam_openid_connect_provider" "eks" {
  url                   = aws_eks_cluster.example.identity[0].oidc[0].issuer
  client_id_list        = ["sts.amazonaws.com"]
  thumbprint_list       = ["9e99a48a9960b14926bb7f3b02e22da0ef648d5e"]

  depends_on = [aws_eks_cluster.example]
}

# Create EKS Cluster
resource "aws_eks_cluster" "example" {
  name     = "dharan-eks-cluster"
  role_arn = "arn:aws:iam::866934333672:role/dharan-eks"

  vpc_config {
    subnet_ids              = data.aws_subnets.public_subnets.ids
    endpoint_public_access  = true
    endpoint_private_access = false
  }
}

# Node Group
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.example.name
  node_group_name = "default-node-group"
  node_role_arn   = "arn:aws:iam::866934333672:role/dharan-node-group"

  subnet_ids = data.aws_subnets.public_subnets.ids

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  instance_types = ["t2.medium"]

  depends_on = [kubernetes_config_map.aws_auth]
}

# Fetch EKS Cluster Auth Token
data "aws_eks_cluster_auth" "example" {
  name = aws_eks_cluster.example.name
}

# Kubernetes Provider
provider "kubernetes" {
  host                   = aws_eks_cluster.example.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.example.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.example.token
}

# Automate aws-auth ConfigMap
resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = <<EOT
    - rolearn: arn:aws:iam::866934333672:role/dharan-node-group
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::866934333672:role/dharan-eks
      username: admin
      groups:
        - system:masters
    EOT
    mapUsers = <<EOT
    - userarn: arn:aws:iam::866934333672:user/Dharan
      username: admin
      groups:
        - system:masters
    EOT
  }

  depends_on = [aws_eks_cluster.example]
}

# Create a Unique Service Role for EBS CSI Add-on
resource "aws_iam_role" "ebs_csi_service_role" {
  name               = "ebs-csi-service-role-${random_string.unique_suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy_attachment" {
  role       = aws_iam_role.ebs_csi_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_EBS_CSI_Driver_Policy"
}

# Add-ons
resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.example.name
  addon_name    = "coredns"
  addon_version = "v1.11.3-eksbuild.1"

  depends_on = [aws_eks_cluster.example]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.example.name
  addon_name    = "kube-proxy"
  addon_version = "v1.31.2-eksbuild.3"

  depends_on = [aws_eks_cluster.example]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.example.name
  addon_name    = "vpc-cni"
  addon_version = "v1.19.0-eksbuild.1"

  depends_on = [aws_eks_cluster.example]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.example.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = "v1.3.4-eksbuild.1"

  depends_on = [aws_eks_cluster.example]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name              = aws_eks_cluster.example.name
  addon_name                = "aws-ebs-csi-driver"
  addon_version             = "v1.37.0-eksbuild.1"
  service_account_role_arn  = aws_iam_role.ebs_csi_service_role.arn

  depends_on = [
    aws_eks_cluster.example,
    aws_iam_openid_connect_provider.eks
  ]
}

# Outputs
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.example.endpoint
}

output "eks_cluster_certificate_authority" {
  value = aws_eks_cluster.example.certificate_authority[0].data
}

output "eks_cluster_arn" {
  value = aws_eks_cluster.example.arn
}

output "node_group_role_arn" {
  value = aws_eks_node_group.default.node_role_arn
}

output "node_group_instance_types" {
  value = aws_eks_node_group.default.instance_types
}
