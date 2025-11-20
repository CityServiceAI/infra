variable "project_name" {
  description = "Назва проекту, використовується як префікс для ресурсів."
  type        = string
  default     = "assistant-orchestrator"
}

variable "container_port" {
  description = "Порт, який слухає ваш додаток всередині контейнера."
  type        = number
  default     = 8000 
}

variable "vpc_id" {
  description = "ID існуючого VPC, де буде розміщено Fargate."
  type        = string
}

variable "public_subnets" {
  description = "Список ID публічних підмереж для ELB та Fargate."
  type        = list(string)
}

variable "ecr_repository_name" {
  description = "Назва репозиторію ECR, де знаходиться образ Docker."
  type        = string
  default     = "assistant-orchestrator"
}