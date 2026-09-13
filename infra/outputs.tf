# What you need after `apply`, surfaced by `terraform output`.
#
# For this config: the file system's DNS name and its mount path (you need
# both to mount it), and the instance address to connect to.
#
# Mark anything secret with `sensitive = true` so it is not echoed to the
# terminal or into CI logs.

output "instance_hostname" {
  description = "Private DNS name of the EC2 instance."
  value       = aws_instance.kdb_box.private_dns
}
