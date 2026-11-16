#!/usr/bin/env bash
# =============================================================================
# implantar-rm93332.sh — DroneVision na AWS (Free Tier)
#
# Cria e configura toda a infraestrutura com a AWS CLI e publica a aplicação
# no AWS Elastic Beanstalk. Executado no AWS CloudShell (Bash) com a AWS CLI.
#
#   Uso:  bash implantar-rm93332.sh            (usa o RM definido abaixo)
#         bash implantar-rm93332.sh rm123456   (RM passado como argumento)
#         USAR_BEDROCK=nao bash implantar-rm93332.sh   (descrição só pelo Rekognition)
#
# Free Tier: antes de criar qualquer recurso, o script confere se o Free Tier
# da conta está ativo e com créditos e escolhe um tipo de instância elegível.
# Se algo não estiver dentro do Free Tier, ele para sem criar nada.
#
# Rodar de novo é seguro: o que já existe é reaproveitado e o código é
# publicado como uma nova versão no mesmo ambiente.
#
# Recursos (padrão de nomenclatura da GS):
#   rg-dronevision-RM    AWS Resource Group (agrupa tudo pela tag Projeto)
#   aiv-dronevision-RM   Role IAM + perfil de instância com acesso ao
#                        Amazon Rekognition e ao Amazon Bedrock
#   plan-dronevision-RM  Aplicação do Elastic Beanstalk
#   app-dronevision-RM   Ambiente do Elastic Beanstalk (Web App)
# =============================================================================
set -euo pipefail

# ----------------------------- Parâmetros ------------------------------------
RM="${1:-rm93332}"                         # RM do aluno
PROJETO="dronevision"
REGIAO="us-east-1"                        # Rekognition e Nova 2 Lite disponíveis
MODELO_BEDROCK="us.amazon.nova-2-lite-v1:0"
TIPOS_PREFERIDOS=(t3.micro t2.micro t3.small)       # usa o primeiro elegível ao Free Tier
USAR_BEDROCK="${USAR_BEDROCK:-sim}"                 # nao = descrição montada pelas etiquetas
LIMITE_ANALISES_DIA="${LIMITE_ANALISES_DIA:-300}"   # teto de análises por dia (protege créditos)
CREDITO_MINIMO=5                                    # US$; abaixo disso o script não cria nada
IGNORAR_FREE_TIER="${IGNORAR_FREE_TIER:-nao}"       # sim = segue mesmo fora do Free Tier

RG="rg-${PROJETO}-${RM}"
AIV="aiv-${PROJETO}-${RM}"
PLAN="plan-${PROJETO}-${RM}"
APP="app-${PROJETO}-${RM}"
TAG_CHAVE="Projeto"
TAG_VALOR="${PROJETO}-${RM}"
VERSAO="v$(date +%Y%m%d-%H%M%S)"

DIR_APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARQUIVOS_APP=(application.py requirements.txt Procfile templates .platform)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixa a região para todos os comandos (evita depender da região configurada no terminal)
export AWS_REGION="$REGIAO" AWS_DEFAULT_REGION="$REGIAO" AWS_PAGER=""

# ----------------------------- Utilitários -----------------------------------
etapa() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✔\033[0m %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
alerta(){ printf '    \033[33m⚠ %s\033[0m\n' "$*"; }
falha() { printf '\n\033[1;31m✘ ERRO:\033[0m %s\n' "$*" >&2; exit 1; }

# Para o script quando algo sairia do Free Tier (a menos que IGNORAR_FREE_TIER=sim)
bloquear() {
  if [[ "$IGNORAR_FREE_TIER" == "sim" ]]; then
    alerta "$* (seguindo porque IGNORAR_FREE_TIER=sim)"
    return 0
  fi
  falha "$* Nenhum recurso foi criado. Para seguir mesmo assim: IGNORAR_FREE_TIER=sim bash $0 ${RM}"
}

# Lê o plano do Free Tier pela API freetier: tipo (FREE/PAID), status e créditos
verificar_free_tier() {
  local tipo status creditos expira
  if [[ "$LAB" == "sim" ]]; then
    ok "AWS Academy Learner Lab: o uso sai do crédito do laboratório"
    return 0
  fi
  if ! read -r tipo status creditos expira < <(aws freetier get-account-plan-state \
        --query '[accountPlanType,accountPlanStatus,accountPlanRemainingCredits.amount,accountPlanExpirationDate]' \
        --output text 2>/dev/null); then
    alerta "Não foi possível ler o plano do Free Tier (CLI antiga ou sem permissão freetier:GetAccountPlanState)."
    alerta "Confira em Billing and Cost Management > Free Tier. O tipo de instância ainda será verificado."
    return 0
  fi
  [[ "$expira" == "None" || -z "$expira" ]] && expira="(data não informada; veja Billing > Credits)"
  info "Plano ${tipo} · status ${status} · créditos US\$ ${creditos} · válido até ${expira%%T*}"
  if [[ "$status" != "ACTIVE" ]]; then
    bloquear "O Free Tier desta conta não está ativo (status ${status}): os recursos seriam cobrados."
    return 0
  fi
  if [[ "$creditos" != "None" ]] && awk -v c="$creditos" -v m="$CREDITO_MINIMO" 'BEGIN { exit !(c + 0 < m + 0) }'; then
    bloquear "Restam só US\$ ${creditos} em créditos do Free Tier (mínimo US\$ ${CREDITO_MINIMO})."
  fi
  if [[ "$tipo" == "PAID" ]]; then
    alerta "Plano pago: os créditos cobrem o uso, mas o que passar deles vai para o cartão."
  else
    ok "Plano gratuito: nada é cobrado no cartão; o uso é descontado dos créditos"
  fi
}

# Escolhe o primeiro tipo de instância que a própria AWS marca como elegível ao Free Tier
escolher_instancia() {
  local elegiveis t
  TIPO_INSTANCIA=""
  if [[ "$LAB" == "sim" ]]; then
    TIPO_INSTANCIA="${TIPOS_PREFERIDOS[0]}"
    ok "Instância ${TIPO_INSTANCIA}"
    return 0
  fi
  elegiveis=" $(aws ec2 describe-instance-types --instance-types "${TIPOS_PREFERIDOS[@]}" \
      --filters Name=free-tier-eligible,Values=true \
      --query 'InstanceTypes[].InstanceType' --output text 2>/dev/null | tr '\t\n' '  ') "
  for t in "${TIPOS_PREFERIDOS[@]}"; do
    if [[ "$elegiveis" == *" $t "* ]]; then TIPO_INSTANCIA="$t"; break; fi
  done
  if [[ -n "$TIPO_INSTANCIA" ]]; then
    ok "Instância ${TIPO_INSTANCIA} (marcada pela AWS como elegível ao Free Tier)"
  else
    bloquear "Nenhum dos tipos ${TIPOS_PREFERIDOS[*]} é elegível ao Free Tier nesta conta."
    TIPO_INSTANCIA="${TIPOS_PREFERIDOS[0]}"
  fi
}

eventos_recentes() {
  aws elasticbeanstalk describe-events --application-name "$PLAN" \
    --environment-name "$APP" --max-items 12 \
    --query 'Events[].[EventDate,Severity,Message]' --output table || true
}

# Aguarda o ambiente sair de Launching/Updating (até 25 min)
aguardar_ambiente() {
  local inicio status saude
  inicio=$(date +%s)
  while true; do
    read -r status saude < <(aws elasticbeanstalk describe-environments \
      --application-name "$PLAN" --environment-names "$APP" --no-include-deleted \
      --query 'Environments[0].[Status,Health]' --output text)
    info "$(date +%H:%M:%S)  status=${status}  saúde=${saude}"
    [[ "$status" == "Ready" ]] && break
    [[ "$status" == "Terminated" || "$status" == "None" ]] && { eventos_recentes; falha "O ambiente $APP não subiu."; }
    (( $(date +%s) - inicio > 1500 )) && { eventos_recentes; falha "Tempo esgotado aguardando $APP."; }
    sleep 20
  done
  [[ "$saude" == "Green" ]] || { info "Saúde ${saude}. Eventos recentes:"; eventos_recentes; }
}

# ----------------------------- 0. Pré-checagens ------------------------------
etapa "0/6 Verificando conta e Free Tier"
[[ "$RM" =~ ^rm[0-9]+$ ]] || falha "RM inválido: '$RM'. Use o formato rm123456."
[[ "$USAR_BEDROCK" == "sim" || "$USAR_BEDROCK" == "nao" ]] || falha "USAR_BEDROCK deve ser sim ou nao."
command -v aws >/dev/null || falha "AWS CLI não encontrada neste terminal."
for f in "${ARQUIVOS_APP[@]}"; do
  [[ -e "$DIR_APP/$f" ]] || falha "Arquivo da aplicação não encontrado: $DIR_APP/$f"
done
CONTA=$(aws sts get-caller-identity --query Account --output text) \
  || falha "Sem credenciais da AWS configuradas neste terminal."
ok "Conta ${CONTA} · região ${REGIAO} · RM ${RM}"
LAB="nao"
aws iam get-instance-profile --instance-profile-name LabInstanceProfile >/dev/null 2>&1 && LAB="sim"
verificar_free_tier
escolher_instancia

# ----------------------------- 1. Resource Group -----------------------------
etapa "1/6 Resource Group ${RG}"
if aws resource-groups get-group --group-name "$RG" >/dev/null 2>&1; then
  ok "Já existe, reaproveitando"
else
  CONSULTA='{"Type":"TAG_FILTERS_1_0","Query":"{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"'"$TAG_CHAVE"'\",\"Values\":[\"'"$TAG_VALOR"'\"]}]}"}'
  aws resource-groups create-group --name "$RG" \
    --description "DroneVision recursos com a tag ${TAG_CHAVE} ${TAG_VALOR}" \
    --resource-query "$CONSULTA" --tags "${TAG_CHAVE}=${TAG_VALOR}" >/dev/null
  ok "Criado (agrupa os recursos com a tag ${TAG_CHAVE}=${TAG_VALOR})"
fi

# ----------------------------- 2. Acesso à IA (IAM) --------------------------
etapa "2/6 Acesso à visão computacional ${AIV}"
OPCAO_ROLE_SERVICO=""
if [[ "$LAB" == "sim" ]]; then
  # AWS Academy Learner Lab: não é permitido criar roles; usa as pré-criadas
  PERFIL_EC2="LabInstanceProfile"
  OPCAO_ROLE_SERVICO=',{"Namespace":"aws:elasticbeanstalk:environment","OptionName":"ServiceRole","Value":"LabRole"}'
  ok "Learner Lab detectado: usando LabInstanceProfile e LabRole (a role ${AIV} não é criada)"
else
  PERFIL_EC2="$AIV"
  if aws iam get-role --role-name "$AIV" >/dev/null 2>&1; then
    ok "Role já existe"
  else
    aws iam create-role --role-name "$AIV" \
      --description "DroneVision: instancia EC2 do Elastic Beanstalk acessando Rekognition e Bedrock" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=${TAG_CHAVE},Value=${TAG_VALOR}" >/dev/null
    ok "Role criada"
  fi
  aws iam attach-role-policy --role-name "$AIV" \
    --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier
  aws iam put-role-policy --role-name "$AIV" --policy-name acesso-visao-computacional \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {"Sid": "Rekognition", "Effect": "Allow", "Action": "rekognition:DetectLabels", "Resource": "*"},
        {"Sid": "BedrockNova", "Effect": "Allow", "Action": "bedrock:InvokeModel",
         "Resource": ["arn:aws:bedrock:*::foundation-model/amazon.nova-*",
                      "arn:aws:bedrock:*:'"$CONTA"':inference-profile/*amazon.nova-*"]}
      ]}'
  ok "Permissões: rekognition:DetectLabels + bedrock:InvokeModel (Nova) + AWSElasticBeanstalkWebTier"

  if ! aws iam get-instance-profile --instance-profile-name "$AIV" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$AIV" \
      --tags "Key=${TAG_CHAVE},Value=${TAG_VALOR}" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$AIV" --role-name "$AIV"
    aws iam wait instance-profile-exists --instance-profile-name "$AIV"
    info "Aguardando a propagação do IAM (15 s)..."
    sleep 15
  fi
  ok "Perfil de instância ${AIV} pronto"

  # Role de serviço do Elastic Beanstalk, informada explicitamente no ambiente
  # (a service-linked role automática pode não estar pronta logo após criada)
  ROLE_SERVICO="aws-elasticbeanstalk-service-role"
  if aws iam get-role --role-name "$ROLE_SERVICO" >/dev/null 2>&1; then
    ok "Role de serviço ${ROLE_SERVICO} já existe"
  else
    aws iam create-role --role-name "$ROLE_SERVICO" \
      --description "Role de servico do Elastic Beanstalk" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"elasticbeanstalk.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"sts:ExternalId":"elasticbeanstalk"}}}]}' >/dev/null
    info "Aguardando a propagação do IAM (15 s)..."
    sleep 15
    ok "Role de serviço ${ROLE_SERVICO} criada"
  fi
  aws iam attach-role-policy --role-name "$ROLE_SERVICO" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth
  aws iam attach-role-policy --role-name "$ROLE_SERVICO" \
    --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy
  OPCAO_ROLE_SERVICO=',{"Namespace":"aws:elasticbeanstalk:environment","OptionName":"ServiceRole","Value":"'"$ROLE_SERVICO"'"}'
fi

# ----------------------------- 3. Aplicação EB (plan) ------------------------
etapa "3/6 Aplicação Elastic Beanstalk ${PLAN}"
if [[ "$(aws elasticbeanstalk describe-applications --application-names "$PLAN" \
        --query 'length(Applications)' --output text)" != "0" ]]; then
  ok "Já existe, reaproveitando"
else
  aws elasticbeanstalk create-application --application-name "$PLAN" \
    --description "DroneVision - analise de imagens de drone (GS)" \
    --tags "Key=${TAG_CHAVE},Value=${TAG_VALOR}" >/dev/null
  ok "Criada"
fi

# ----------------------------- 4. Pacote do código ---------------------------
etapa "4/6 Empacotando e enviando a versão ${VERSAO}"
PACOTE="$TMP/${APP}-${VERSAO}.zip"
if command -v zip >/dev/null; then
  (cd "$DIR_APP" && zip -qr "$PACOTE" "${ARQUIVOS_APP[@]}" -x '*__pycache__*' '*.pyc')
else
  (cd "$DIR_APP" && python3 -m zipfile -c "$PACOTE" "${ARQUIVOS_APP[@]}")
fi
BUCKET=$(aws elasticbeanstalk create-storage-location --query S3Bucket --output text)
CHAVE_S3="${PLAN}/${VERSAO}.zip"
aws s3 cp "$PACOTE" "s3://${BUCKET}/${CHAVE_S3}" --only-show-errors
aws elasticbeanstalk create-application-version --application-name "$PLAN" \
  --version-label "$VERSAO" --description "Deploy via implantar-${RM}.sh" \
  --source-bundle "S3Bucket=${BUCKET},S3Key=${CHAVE_S3}" >/dev/null
ok "Pacote em s3://${BUCKET}/${CHAVE_S3}"

# ----------------------------- 5. Ambiente EB (app) --------------------------
etapa "5/6 Ambiente Elastic Beanstalk ${APP}"
# SingleInstance = sem load balancer: só a instância, o disco e o IP público
OPCOES="$TMP/opcoes.json"
cat > "$OPCOES" <<JSON
[
  {"Namespace": "aws:elasticbeanstalk:environment", "OptionName": "EnvironmentType", "Value": "SingleInstance"},
  {"Namespace": "aws:autoscaling:launchconfiguration", "OptionName": "IamInstanceProfile", "Value": "${PERFIL_EC2}"},
  {"Namespace": "aws:autoscaling:launchconfiguration", "OptionName": "DisableIMDSv1", "Value": "true"},
  {"Namespace": "aws:ec2:instances", "OptionName": "InstanceTypes", "Value": "${TIPO_INSTANCIA}"},
  {"Namespace": "aws:elasticbeanstalk:application:environment", "OptionName": "AWS_REGION", "Value": "${REGIAO}"},
  {"Namespace": "aws:elasticbeanstalk:application:environment", "OptionName": "BEDROCK_MODEL_ID", "Value": "${MODELO_BEDROCK}"},
  {"Namespace": "aws:elasticbeanstalk:application:environment", "OptionName": "USAR_BEDROCK", "Value": "${USAR_BEDROCK}"},
  {"Namespace": "aws:elasticbeanstalk:application:environment", "OptionName": "LIMITE_ANALISES_DIA", "Value": "${LIMITE_ANALISES_DIA}"},
  {"Namespace": "aws:elasticbeanstalk:application:environment", "OptionName": "APP_NOME", "Value": "${APP}"}
  ${OPCAO_ROLE_SERVICO}
]
JSON

STATUS=$(aws elasticbeanstalk describe-environments --application-name "$PLAN" \
  --environment-names "$APP" --no-include-deleted \
  --query 'Environments[0].Status' --output text)

if [[ "$STATUS" == "None" ]]; then
  [[ "$(aws elasticbeanstalk check-dns-availability --cname-prefix "$APP" \
        --query Available --output text)" == "True" ]] \
    || falha "O endereço ${APP}.${REGIAO}.elasticbeanstalk.com já está em uso por outra conta."
  PLATAFORMA=""
  for py in 3.13 3.12; do
    PLATAFORMA=$(aws elasticbeanstalk list-available-solution-stacks \
      --query "SolutionStacks[?contains(@, 'Amazon Linux 2023') && contains(@, 'running Python ${py}')] | [0]" \
      --output text)
    [[ -n "$PLATAFORMA" && "$PLATAFORMA" != "None" ]] && break
  done
  [[ -n "$PLATAFORMA" && "$PLATAFORMA" != "None" ]] || falha "Plataforma Python (AL2023) não encontrada."
  info "Plataforma: ${PLATAFORMA}"
  aws elasticbeanstalk create-environment --application-name "$PLAN" \
    --environment-name "$APP" --cname-prefix "$APP" \
    --solution-stack-name "$PLATAFORMA" --version-label "$VERSAO" \
    --option-settings "file://${OPCOES}" \
    --tags "Key=${TAG_CHAVE},Value=${TAG_VALOR}" >/dev/null
  ok "Criação iniciada (leva de 4 a 8 minutos)"
else
  info "Ambiente já existe (status ${STATUS}); publicando a nova versão"
  [[ "$STATUS" == "Ready" ]] || aguardar_ambiente
  aws elasticbeanstalk update-environment --application-name "$PLAN" \
    --environment-name "$APP" --version-label "$VERSAO" \
    --option-settings "file://${OPCOES}" >/dev/null
  ok "Deploy da versão ${VERSAO} iniciado"
fi
aguardar_ambiente

# ----------------------------- 6. Verificação --------------------------------
etapa "6/6 Verificando a aplicação publicada"
URL="http://$(aws elasticbeanstalk describe-environments --application-name "$PLAN" \
  --environment-names "$APP" --query 'Environments[0].CNAME' --output text)"
CODIGO="000"
for _ in 1 2 3 4 5 6; do
  CODIGO=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${URL}/saude" || true)
  [[ "$CODIGO" == "200" ]] && break
  sleep 10
done
if [[ "$CODIGO" == "200" ]]; then ok "${URL}/saude respondeu 200"
else info "A verificação devolveu HTTP ${CODIGO}; confira os eventos/logs do ambiente."; fi

aws elasticbeanstalk describe-environments --application-name "$PLAN" --environment-names "$APP" \
  --query 'Environments[0].{Ambiente:EnvironmentName,Aplicacao:ApplicationName,Versao:VersionLabel,Status:Status,Saude:Health,Plataforma:SolutionStackName,URL:CNAME}' \
  --output table

cat <<RESUMO

==============================================================================
 DroneVision publicado
   URL ............ ${URL}
   Resource Group . ${RG}
   Acesso à IA .... ${PERFIL_EC2}  (Rekognition + Bedrock ${MODELO_BEDROCK})
   App Service Plan ${PLAN}  (aplicação Elastic Beanstalk)
   Web App ........ ${APP}  (ambiente Elastic Beanstalk, ${TIPO_INSTANCIA})
 Free Tier
   Instância ${TIPO_INSTANCIA}, sem load balancer · Bedrock: ${USAR_BEDROCK} · até ${LIMITE_ANALISES_DIA} análises/dia
   Ligado, o ambiente consome cerca de US\$ 0,40 por dia dos créditos.
 Para remover tudo depois da avaliação:  bash destruir-${RM}.sh ${RM}
==============================================================================
RESUMO
