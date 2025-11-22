output "alb_dns_name" {
  description = "DNS-ім'я Application Load Balancer (БЕКЕНД). Використовуйте його як VITE_API_BASE_URL."
  value       = aws_lb.main.dns_name
}
