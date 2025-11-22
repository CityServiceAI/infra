#!/bin/bash

# Скрипт для збірки Docker-образу фронтенду та його відправки в AWS ECR.
# ПЕРЕКОНАЙТЕСЬ, що ви знаходитесь у кореневій директорії проекту, 
# де лежить Dockerfile.frontend.http.

# --- ЗМІННІ КОНФІГУРАЦІЇ AWS ---
export AWS_PROFILE="439525862286_AdministratorAccess"
AWS_ACCOUNT_ID="439525862286"
AWS_REGION="eu-central-1"

# --- ЗМІННІ ДЛЯ ФРОНТЕНДУ ---
ECR_REPO_NAME="assistant-frontend"
IMAGE_TAG="latest"

# 1. Оновлення токена SSO
echo "1. Оновлення токена AWS SSO..."
aws sso login --profile $AWS_PROFILE

# 2. Отримання пароля для DOCKER LOGIN
echo "2. Отримання пароля для Docker login та авторизація..."
aws ecr get-login-password \
  --region $AWS_REGION \
  --profile $AWS_PROFILE | \
  docker login \
  --username AWS \
  --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Перевірка успішності логіну
if [ $? -ne 0 ]; then
  echo "Помилка: Не вдалося авторизуватися в ECR. Перевірте AWS_PROFILE."
  exit 1
fi


docker buildx build \
  --platform linux/amd64 \
  -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:$IMAGE_TAG \
  . \
  --push


# Перевірка успішності збірки та пушу
if [ $? -ne 0 ]; then
  echo "Помилка: Не вдалося зібрати або відправити образ."
  exit 1
fi

# 4. ФІНАЛЬНА ІНСТРУКЦІЯ
echo "--- Образ $ECR_REPO_NAME:$IMAGE_TAG успішно відправлено до ECR. ---"
echo "НЕ ЗАБУДЬТЕ запустити 'terraform apply', щоб оновити ECS Service."