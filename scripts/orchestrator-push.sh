# Встановлюємо змінні для зручності
export AWS_PROFILE="439525862286_AdministratorAccess"
AWS_ACCOUNT_ID="439525862286"
AWS_REGION="eu-central-1"
ECR_REPO_NAME="assistant-orchestrator"
IMAGE_TAG="latest"

# 1. Оновлення токена SSO (якщо термін дії токена закінчився)
# Якщо ви щойно логінились, цей крок можна пропустити, але це безпечно.
aws sso login --profile $AWS_PROFILE

# 2. Отримання ТИМЧАСОВОГО ПАРОЛЯ ДЛЯ DOCKER LOGIN
# Ця команда використовує АКТУАЛЬНІ SSO-креденти для створення пароля.
aws ecr get-login-password \
  --region $AWS_REGION \
  --profile $AWS_PROFILE | \
  docker login \
  --username AWS \
  --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# 3. ЗБІРКА (для правильної архітектури AMD64) ТА PUSH
# Ми використовуємо повний ARN для тегування, щоб Buildx знав, куди пушити.
docker buildx build \
  --platform linux/amd64 \
  -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:$IMAGE_TAG \
  . \
  --push