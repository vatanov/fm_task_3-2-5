variable "ami" {
  type    = string
  default = "ami-0e1bed4f06a3b463d"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "key_name" {
  type    = string
  default = "ghostfolio_key"
}

variable "network_interface_index" {
  type    = number
  default = 0
}

variable "network_interface_id" {
  type = string
}

variable "user_data" {
  type    = string
  default = null
}

variable "tags" {
  type = map(string)
  default = {
    Name = "ghostfolio_web_srv"
  }
}
