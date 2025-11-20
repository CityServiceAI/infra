output "alb_dns_name" {
  description = "DNS-ім'я Application Load Balancer"
  value       = aws_lb.main.dns_name
}