variable "project_name" {
  description = "Назва проекту, використовується як префікс для ресурсів."
  type        = string
  default     = "assistant-orchestrator"
}

variable "container_port" {
  description = "Порт, який слухає ваш додаток всередині контейнера."
  type        = number
  default     = 8000 # Замініть на порт вашого застосунку (наприклад, 80, 5000, 8000)
}

variable "ecr_repository_name" {
  description = "Назва репозиторію ECR, де знаходиться образ Docker."
  type        = string
  default     = "assistant-orchestrator"
}

variable "desired_container_count" {
  description = "Бажана кількість інстансів контейнера Fargate."
  type        = number
  default     = 1
}

variable "vpc_cidr_block" {
  description = "CIDR блок для нового VPC."
  type        = string
  default     = "10.0.0.0/16"
}