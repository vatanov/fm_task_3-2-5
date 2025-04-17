variable "hosted_zone_id" {
  description = "The ID of the Route 53 hosted zone"
  type        = string
}

variable "ec2_public_ip" {
  description = "The existing EC2 public IP"
  type        = string
}