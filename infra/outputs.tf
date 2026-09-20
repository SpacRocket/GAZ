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

output "instance_id" {
  description = "Instance ID for KDB, used for SSM"
  value       = aws_instance.kdb_box.id
}
output "region" {
  description = "Region everything lives in — scripts should read this rather than hardcode."
  value       = data.aws_region.current.name
}

output "code_bucket" {
  description = "Bucket the instance pulls code from."
  value       = aws_s3_bucket.kdb_code.bucket
}

output "code_bucket_uri" {
  description = "Paste-ready target: aws s3 sync . $(terraform output -raw code_bucket_uri)"
  value       = "s3://${aws_s3_bucket.kdb_code.bucket}"
}

output "code_bucket_artifacts_uri" {
  description = "The ONLY prefix the instance role may write to — s3:PutObject is scoped to artifacts/*."
  value       = "s3://${aws_s3_bucket.kdb_code.bucket}/artifacts"
}

output "kx_lic_param" {
  description = "SSM SecureString holding base64(kc.lic). The box fetches it; Terraform never holds its value."
  value       = aws_ssm_parameter.kx_lic.name
}
