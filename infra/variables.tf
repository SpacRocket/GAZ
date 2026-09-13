variable "instance_type" {
  description = "The EC2 instance's type."
  type        = string
  default     = "t2.small"
}

variable "fsx_kdb_name" {
  description = "The name of the FSx filesystem used by KDB"
  type        = string
  default     = "kdb_fsx"
}

variable "fsx_required_ports" {
  description = "Ports required by FSx"
  type        = list(any)
  default     = [111, 2049, 20001, 20002, 20003]
}
