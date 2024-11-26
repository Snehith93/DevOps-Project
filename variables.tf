variable "region" {
  default = "us-west-2"
}

variable "cluster_name" {
  default = "my-eks-cluster"
}

variable "desired_capacity" {
  default = 2
}

variable "min_size" {
  default = 1
}

variable "max_size" {
  default = 4
}

variable "instance_type" {
  default = "t3.medium"
}
