resource "aws_instance" "this" {
  ami               = var.ami
  instance_type     = var.instance_type
  availability_zone = var.availability_zone
  key_name          = var.key_name

  network_interface {
    device_index         = var.network_interface_index
    network_interface_id = var.network_interface_id
  }

  user_data = var.user_data

  tags = var.tags

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
}