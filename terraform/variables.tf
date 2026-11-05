variable "project_id" {
  type    = string
  default = "tbx-gabriel-simoes"
}

variable "region" {
  type    = string
  default = "southamerica-east1"
}

variable "zone" {
  type    = string
  default = "southamerica-east1-b"
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-2"
  description = "O e2-medium (4 GB) funciona também, mas fica apertado durante análises"
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

variable "sonar_image" {
  type        = string
  default     = "sonarqube:community"
  description = ""
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDRs com acesso a :9000. Sem default de propósito: exige decisão explícita."
}
