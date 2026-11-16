#!/usr/bin/env bash
# =============================================================================
# destruir-rm93332.sh — remove tudo o que o implantar-rm93332.sh criou.
#   Uso:  bash destruir-rm93332.sh [rm93332] [--sim]
# Rode depois de coletar as evidências: ligado, o ambiente consome cerca de
# US$ 0,40 por dia dos créditos do Free Tier (instância, disco e IP público).
# =============================================================================
set -uo pipefail

RM="rm93332"; CONFIRMADO="nao"
for arg in "$@"; do
  case "$arg" in
    --sim) CONFIRMADO="sim" ;;
    rm[0-9]*) RM="$arg" ;;
  esac
done

PROJETO="dronevision"
REGIAO="us-east-1"
RG="rg-${PROJETO}-${RM}"; AIV="aiv-${PROJETO}-${RM}"
PLAN="plan-${PROJETO}-${RM}"; APP="app-${PROJETO}-${RM}"
export AWS_REGION="$REGIAO" AWS_DEFAULT_REGION="$REGIAO" AWS_PAGER=""

etapa() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✔\033[0m %s\n' "$*"; }

echo "Serão removidos: ${APP}, ${PLAN}, ${AIV} e ${RG} (região ${REGIAO})."
if [[ "$CONFIRMADO" != "sim" ]]; then
  read -r -p "Digite o seu RM (${RM}) para confirmar: " resposta
  [[ "$resposta" == "$RM" ]] || { echo "Cancelado."; exit 1; }
fi

etapa "1/4 Encerrando o ambiente ${APP}"
STATUS=$(aws elasticbeanstalk describe-environments --application-name "$PLAN" \
  --environment-names "$APP" --no-include-deleted --query 'Environments[0].Status' --output text 2>/dev/null)
if [[ -n "$STATUS" && "$STATUS" != "None" ]]; then
  [[ "$STATUS" != "Terminating" ]] && aws elasticbeanstalk terminate-environment --environment-name "$APP" >/dev/null
  while true; do
    STATUS=$(aws elasticbeanstalk describe-environments --application-name "$PLAN" \
      --environment-names "$APP" --query 'Environments[0].Status' --output text)
    printf '    %s  status=%s\n' "$(date +%H:%M:%S)" "$STATUS"
    [[ "$STATUS" == "Terminated" || "$STATUS" == "None" ]] && break
    sleep 20
  done
  ok "Ambiente encerrado"
else
  ok "Ambiente não existe"
fi

etapa "2/4 Removendo a aplicação ${PLAN} e os pacotes no S3"
if [[ "$(aws elasticbeanstalk describe-applications --application-names "$PLAN" \
        --query 'length(Applications)' --output text 2>/dev/null)" == "1" ]]; then
  aws elasticbeanstalk delete-application --application-name "$PLAN" --terminate-env-by-force
  ok "Aplicação removida"
else
  ok "Aplicação não existe"
fi
BUCKET=$(aws elasticbeanstalk create-storage-location --query S3Bucket --output text 2>/dev/null)
[[ -n "$BUCKET" ]] && aws s3 rm "s3://${BUCKET}/${PLAN}/" --recursive --only-show-errors && ok "Pacotes apagados de s3://${BUCKET}/${PLAN}/"

etapa "3/4 Removendo o acesso à IA ${AIV}"
if aws iam get-role --role-name "$AIV" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$AIV" --role-name "$AIV" 2>/dev/null
  aws iam delete-instance-profile --instance-profile-name "$AIV" 2>/dev/null
  aws iam delete-role-policy --role-name "$AIV" --policy-name acesso-visao-computacional 2>/dev/null
  aws iam detach-role-policy --role-name "$AIV" \
    --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier 2>/dev/null
  aws iam delete-role --role-name "$AIV" && ok "Role e perfil de instância removidos"
else
  ok "Role não existe (ou Learner Lab: LabRole não é removida)"
fi

etapa "4/4 Removendo o Resource Group ${RG}"
aws resource-groups delete-group --group "$RG" >/dev/null 2>&1 && ok "Resource Group removido" \
  || ok "Resource Group não existe"

echo
echo "Concluído. Sem o ambiente, o projeto para de consumir créditos do Free Tier."
echo "Restam apenas o bucket do Elastic Beanstalk (vazio) e a service-linked role, que não geram custo."
