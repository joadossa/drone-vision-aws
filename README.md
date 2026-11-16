# DroneVision na AWS

Aplicação Web que recebe fotos capturadas por drone e devolve uma descrição gerada por IA,
as etiquetas (tags) e os objetos identificados na imagem.

- **Hospedagem:** AWS Elastic Beanstalk (Python 3.13, Amazon Linux 2023, 1 instância do Free Tier, t3.micro)
- **Visão computacional:** Amazon Rekognition `DetectLabels` (etiquetas + objetos com posição)
- **Descrição em texto:** Amazon Bedrock, modelo Amazon Nova 2 Lite (`us.amazon.nova-2-lite-v1:0`)
- **Infraestrutura e deploy:** script Bash com AWS CLI, executado no AWS CloudShell

## Free Tier

O projeto foi feito para rodar só com o AWS Free Tier (contas criadas a partir de 15/07/2025,
com US$ 100 a 200 em créditos):

- antes de criar qualquer recurso, o script lê o plano da conta (`aws freetier get-account-plan-state`)
  e para se o Free Tier não estiver ativo ou restarem menos de US$ 5 em créditos;
- o tipo de instância é o primeiro que a própria AWS marca como elegível ao Free Tier
  (`t3.micro`, depois `t2.micro` ou `t3.small`);
- o ambiente é de instância única, sem load balancer;
- a aplicação limita as análises a 300 por dia (`LIMITE_ANALISES_DIA`) e manda ao Bedrock
  uma cópia de 1024 px da foto, que gasta menos tokens;
- `USAR_BEDROCK=nao bash implantar-rm93332.sh` desliga o Bedrock: a descrição passa a ser
  montada pelas etiquetas do Rekognition.

Ligado, o ambiente consome cerca de US$ 0,40 por dia dos créditos (instância, disco e IP público).
Cada análise custa uma fração de centavo. Rode `destruir-rm93332.sh` depois da avaliação.

## Recursos criados

| Recurso | Nome |
| --- | --- |
| Resource Group (agrupa pela tag `Projeto`) | `rg-dronevision-rm93332` |
| Acesso à IA (role IAM + perfil de instância) | `aiv-dronevision-rm93332` |
| Aplicação Elastic Beanstalk | `plan-dronevision-rm93332` |
| Ambiente Elastic Beanstalk (Web App) | `app-dronevision-rm93332` |

## Como publicar

No AWS CloudShell (Bash), com a AWS CLI:

```bash
git clone https://github.com/joadossa/drone-vision-aws.git
cd drone-vision-aws
bash implantar-rm93332.sh rm93332
```

O script leva de 5 a 10 minutos e termina mostrando a URL
`http://app-dronevision-rm93332.us-east-1.elasticbeanstalk.com`.
Rodar de novo publica uma nova versão do código no mesmo ambiente.

Para remover tudo: `bash destruir-rm93332.sh rm93332`.

## Estrutura

```
implantar-rm93332.sh                  cria a infraestrutura e faz o deploy (AWS CLI)
destruir-rm93332.sh                   remove todos os recursos
application.py                       aplicação Flask (rotas, chamadas ao Rekognition e Bedrock, erros)
templates/index.html                 página DroneVision
requirements.txt                     Flask, boto3, Pillow, gunicorn
Procfile                             comando do gunicorn usado pelo Elastic Beanstalk
.platform/nginx/conf.d/upload.conf   libera uploads de até 12 MB no nginx
```

## Como a aplicação se integra com a visão computacional

1. O operador escolhe a foto na página e o navegador a envia por HTTP POST para `/analisar`.
2. A aplicação valida o arquivo com Pillow (formato, tamanho, resolução mínima de 80 px),
   corrige a orientação e reduz a foto para JPEG de até 1920 px, abaixo do limite de 5 MB do Rekognition.
3. Com o SDK boto3, a aplicação chama `rekognition.detect_labels` enviando os bytes da imagem.
   O serviço devolve um JSON com as etiquetas, a confiança de cada uma e, para objetos comuns,
   a caixa delimitadora (posição na foto).
4. A mesma imagem vai para `bedrock-runtime.converse` (Amazon Nova 2 Lite) com um pedido de
   descrição em português focado em monitoramento e resgate. Se o Bedrock falhar, a descrição
   é montada a partir das etiquetas do Rekognition.
5. A página mostra a descrição, as etiquetas e desenha as caixas dos objetos sobre a foto.

A autenticação não usa chave: a instância EC2 do Elastic Beanstalk recebe o perfil
`aiv-dronevision-rm93332`, cuja role IAM permite apenas `rekognition:DetectLabels` e
`bedrock:InvokeModel` nos modelos Amazon Nova. O boto3 obtém credenciais temporárias da role
automaticamente, então nenhuma chave fica no código nem no GitHub.

Erros tratados com mensagem para o operador: arquivo ausente, vazio, corrompido ou com extensão
não suportada; imagem pequena demais ou maior que 10 MB; imagem recusada pelo serviço (HTTP 422);
limite diário de análises atingido (HTTP 429); falta de permissão, limite de requisições ou serviço
indisponível (HTTP 503); falha inesperada.
