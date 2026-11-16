"""DroneVision na AWS.

Aplicação Web (Flask) hospedada no AWS Elastic Beanstalk que recebe fotos de
drone e as analisa com:

* Amazon Rekognition (DetectLabels): etiquetas e objetos localizados (caixas);
* Amazon Bedrock (Amazon Nova 2 Lite): descrição da imagem em português.

Se o Bedrock estiver desligado (USAR_BEDROCK=nao) ou não responder, a
descrição é montada a partir das etiquetas do Rekognition, para que a página
sempre mostre uma descrição.

Free Tier: cada análise consome créditos (Rekognition + Bedrock). Por isso a
aplicação tem um limite diário de análises (LIMITE_ANALISES_DIA) e envia ao
Bedrock uma cópia reduzida da foto, que gasta menos tokens.

As credenciais vêm da role IAM da instância EC2 (perfil de instância criado
pelo script implantar-rm93332.sh). Nenhuma chave fica no código.
"""

from __future__ import annotations

import base64
import fcntl
import io
import json
import logging
import os
from collections import Counter
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
from flask import Flask, render_template, request
from PIL import Image, ImageOps, UnidentifiedImageError

# --------------------------------------------------------------------------
# Configuração (vem das propriedades de ambiente do Elastic Beanstalk)
# --------------------------------------------------------------------------
REGIAO = os.environ.get("AWS_REGION", "us-east-1")
MODELO_BEDROCK = os.environ.get("BEDROCK_MODEL_ID", "us.amazon.nova-2-lite-v1:0")
NOME_AMBIENTE = os.environ.get("APP_NOME", "dronevision (local)")
USAR_BEDROCK = os.environ.get("USAR_BEDROCK", "sim").strip().lower() in {"sim", "s", "true", "1", "yes"}
LIMITE_DIARIO = int(os.environ.get("LIMITE_ANALISES_DIA", "300"))   # protege os créditos do Free Tier
ARQUIVO_USO = os.environ.get("ARQUIVO_USO", "/tmp/dronevision-uso.json")

MAX_UPLOAD_MB = 10          # limite do formulário (o nginx aceita até 12 MB)
MAX_LADO_PX = 1920          # reduz a foto antes de enviar à IA (limites: 5 MB no Rekognition)
MAX_LADO_BEDROCK_PX = 1024  # cópia menor para o Bedrock: menos tokens, menos créditos
MIN_LADO_PX = 80            # mínimo exigido pelo DetectLabels
CONFIANCA_MINIMA = 70       # % mínima para exibir uma etiqueta
EXTENSOES_ACEITAS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}

PROMPT_DESCRICAO = (
    "Você apoia um operador que analisa fotos aéreas capturadas por um drone. "
    "Descreva esta imagem em português do Brasil, em 2 ou 3 frases objetivas: "
    "o tipo de ambiente, os objetos, veículos e pessoas visíveis e qualquer sinal "
    "relevante para monitoramento ou resgate (alagamento, fumaça, fogo, estruturas "
    "danificadas, vias bloqueadas). Não invente nada que não esteja visível."
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dronevision")

application = Flask(__name__)  # o Elastic Beanstalk procura o objeto "application"
application.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024

_config_aws = Config(
    region_name=REGIAO,
    connect_timeout=5,
    read_timeout=40,
    retries={"max_attempts": 3, "mode": "standard"},
)
rekognition = boto3.client("rekognition", config=_config_aws)
bedrock = boto3.client("bedrock-runtime", config=_config_aws)


# --------------------------------------------------------------------------
# Erros com mensagem pronta para o operador
# --------------------------------------------------------------------------
class ErroDroneVision(Exception):
    """Erro com mensagem amigável, tipo (para a cor do aviso) e status HTTP."""

    def __init__(self, mensagem: str, tipo: str, status: int):
        super().__init__(mensagem)
        self.mensagem = mensagem
        self.tipo = tipo      # "imagem" | "analise" | "servico" | "limite"
        self.status = status


def imagem_invalida(msg: str) -> ErroDroneVision:
    return ErroDroneVision(msg, "imagem", 400)


# Códigos de erro do Rekognition / Bedrock -> mensagem para o operador
_ERROS_IMAGEM = {"InvalidImageFormatException", "ImageTooLargeException", "InvalidParameterException"}
_ERROS_INDISPONIVEL = {
    "ThrottlingException", "ProvisionedThroughputExceededException", "InternalServerError",
    "InternalServerException", "ServiceUnavailableException", "ServiceQuotaExceededException",
}
_ERROS_PERMISSAO = {
    "AccessDeniedException", "UnrecognizedClientException", "ExpiredTokenException",
    "InvalidSignatureException", "AccessDenied",
}


def traduzir_erro_aws(erro: Exception) -> ErroDroneVision:
    if isinstance(erro, ClientError):
        codigo = erro.response.get("Error", {}).get("Code", "")
        log.warning("Erro do Rekognition: %s", codigo)
        if codigo in _ERROS_IMAGEM:
            return ErroDroneVision(
                "O serviço de visão computacional recusou esta imagem (formato, tamanho ou "
                "resolução fora do suportado). Tente outra foto em JPG ou PNG.", "imagem", 422)
        if codigo in _ERROS_PERMISSAO:
            return ErroDroneVision(
                "A aplicação não tem permissão para usar o Amazon Rekognition. "
                "Verifique a role IAM da instância.", "servico", 503)
        if codigo in _ERROS_INDISPONIVEL:
            return ErroDroneVision(
                "O serviço de visão computacional está temporariamente indisponível. "
                "Aguarde alguns segundos e tente de novo.", "servico", 503)
        return ErroDroneVision(f"Falha na análise da imagem ({codigo or 'erro desconhecido'}).",
                               "analise", 502)
    if isinstance(erro, (NoCredentialsError, BotoCoreError)):
        log.warning("Falha de conexão/credenciais com a AWS: %s", erro)
        return ErroDroneVision(
            "Não foi possível conectar ao serviço de visão computacional da AWS. "
            "Tente novamente em instantes.", "servico", 503)
    log.exception("Erro inesperado na análise")
    return ErroDroneVision("Falha inesperada na análise da imagem.", "analise", 500)


# --------------------------------------------------------------------------
# Limite diário de análises (protege os créditos do Free Tier)
# O contador fica num arquivo com trava, compartilhado pelos workers do gunicorn.
# --------------------------------------------------------------------------
def _hoje() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def _ler_contador(arquivo) -> dict:
    arquivo.seek(0)
    try:
        dados = json.loads(arquivo.read() or "{}")
    except ValueError:
        dados = {}
    if dados.get("dia") != _hoje():
        dados = {"dia": _hoje(), "analises": 0}
    return dados


def reservar_analise() -> bool:
    """Conta uma análise; devolve False se o limite do dia já foi atingido."""
    try:
        with open(ARQUIVO_USO, "a+", encoding="utf-8") as arquivo:
            fcntl.flock(arquivo, fcntl.LOCK_EX)
            dados = _ler_contador(arquivo)
            if dados["analises"] >= LIMITE_DIARIO:
                return False
            dados["analises"] += 1
            arquivo.seek(0)
            arquivo.truncate()
            arquivo.write(json.dumps(dados))
        return True
    except OSError as erro:  # sem contador não bloqueia a aplicação
        log.warning("Contador de uso indisponível: %s", erro)
        return True


def analises_hoje() -> int:
    try:
        with open(ARQUIVO_USO, "a+", encoding="utf-8") as arquivo:
            fcntl.flock(arquivo, fcntl.LOCK_SH)
            return _ler_contador(arquivo)["analises"]
    except OSError:
        return 0


# --------------------------------------------------------------------------
# Etapas da análise
# --------------------------------------------------------------------------
def preparar_imagem(dados: bytes) -> bytes:
    """Valida a imagem, corrige a orientação e converte para JPEG <= 1920 px."""
    try:
        with Image.open(io.BytesIO(dados)) as teste:
            teste.verify()                      # detecta arquivo corrompido
        img = Image.open(io.BytesIO(dados))
        img = ImageOps.exif_transpose(img)      # fotos de celular/drone giradas
        img.load()
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError, Image.DecompressionBombError):
        raise imagem_invalida("O arquivo enviado não é uma imagem válida. Use JPG ou PNG.")

    if min(img.size) < MIN_LADO_PX:
        raise imagem_invalida(f"Imagem muito pequena: cada lado precisa ter pelo menos {MIN_LADO_PX} px.")

    img = img.convert("RGB")
    img.thumbnail((MAX_LADO_PX, MAX_LADO_PX))
    saida = io.BytesIO()
    img.save(saida, format="JPEG", quality=85)
    return saida.getvalue()


def reduzir(jpeg: bytes, lado: int) -> bytes:
    """Cópia menor da imagem (para o Bedrock, que cobra por token)."""
    with Image.open(io.BytesIO(jpeg)) as img:
        if max(img.size) <= lado:
            return jpeg
        img.thumbnail((lado, lado))
        saida = io.BytesIO()
        img.save(saida, format="JPEG", quality=80)
        return saida.getvalue()


def detectar_etiquetas(jpeg: bytes) -> tuple[list[dict], list[dict]]:
    """Chama o Amazon Rekognition DetectLabels e separa etiquetas e objetos."""
    resposta = rekognition.detect_labels(
        Image={"Bytes": jpeg}, MaxLabels=25, MinConfidence=CONFIANCA_MINIMA)

    etiquetas, objetos = [], []
    for rotulo in resposta.get("Labels", []):
        etiquetas.append({"nome": rotulo["Name"], "confianca": round(rotulo["Confidence"], 1)})
        for inst in rotulo.get("Instances", []):
            caixa = inst.get("BoundingBox") or {}
            objetos.append({
                "nome": rotulo["Name"],
                "confianca": round(inst.get("Confidence", rotulo["Confidence"]), 1),
                "esq": round(caixa.get("Left", 0) * 100, 2),
                "topo": round(caixa.get("Top", 0) * 100, 2),
                "larg": round(caixa.get("Width", 0) * 100, 2),
                "alt": round(caixa.get("Height", 0) * 100, 2),
            })
    return etiquetas, objetos


def descrever_com_bedrock(jpeg: bytes) -> str:
    """Pede ao Amazon Nova 2 Lite (Bedrock Converse API) uma descrição em português."""
    resposta = bedrock.converse(
        modelId=MODELO_BEDROCK,
        messages=[{
            "role": "user",
            "content": [
                {"image": {"format": "jpeg", "source": {"bytes": jpeg}}},
                {"text": PROMPT_DESCRICAO},
            ],
        }],
        inferenceConfig={"maxTokens": 300, "temperature": 0.2},
    )
    blocos = resposta["output"]["message"]["content"]
    return " ".join(b["text"].strip() for b in blocos if "text" in b).strip()


def descrever_por_etiquetas(etiquetas: list[dict], objetos: list[dict]) -> str:
    """Descrição de reserva, montada só com o resultado do Rekognition."""
    if not etiquetas:
        return "Nenhum elemento foi reconhecido com confiança suficiente nesta imagem."
    principais = ", ".join(e["nome"] for e in etiquetas[:6])
    texto = f"A imagem provavelmente mostra: {principais}."
    if objetos:
        contagem = Counter(o["nome"] for o in objetos)
        itens = ", ".join(f"{qtd} × {nome}" for nome, qtd in contagem.most_common())
        texto += f" Objetos localizados: {itens}."
    return texto


def analisar(dados: bytes) -> dict:
    jpeg = preparar_imagem(dados)   # imagem inválida não gasta cota nem créditos

    if not reservar_analise():
        raise ErroDroneVision(
            f"Limite de {LIMITE_DIARIO} análises por dia atingido. O limite protege os "
            "créditos do Free Tier da AWS; tente novamente amanhã.", "limite", 429)

    try:
        etiquetas, objetos = detectar_etiquetas(jpeg)
    except Exception as erro:  # noqa: BLE001 - convertido em mensagem amigável
        raise traduzir_erro_aws(erro) from erro

    aviso = None
    if USAR_BEDROCK:
        try:
            descricao = descrever_com_bedrock(reduzir(jpeg, MAX_LADO_BEDROCK_PX))
            origem = f"Amazon Bedrock ({MODELO_BEDROCK})"
            if not descricao:
                raise ValueError("resposta vazia")
        except Exception as erro:  # noqa: BLE001 - a descrição de reserva assume
            log.warning("Bedrock indisponível, usando etiquetas: %s", erro)
            descricao = descrever_por_etiquetas(etiquetas, objetos)
            origem = "etiquetas do Amazon Rekognition"
            aviso = ("O modelo de descrição (Amazon Bedrock) não respondeu; a descrição abaixo "
                     "foi montada a partir das etiquetas do Rekognition.")
    else:
        descricao = descrever_por_etiquetas(etiquetas, objetos)
        origem = "etiquetas do Amazon Rekognition (Bedrock desligado para economizar créditos)"

    return {
        "descricao": descricao,
        "origem_descricao": origem,
        "aviso": aviso,
        "etiquetas": etiquetas,
        "objetos": objetos,
        "imagem_b64": base64.b64encode(jpeg).decode("ascii"),
    }


# --------------------------------------------------------------------------
# Rotas
# --------------------------------------------------------------------------
def pagina(status: int = 200, **contexto):
    return render_template(
        "index.html", ambiente=NOME_AMBIENTE, regiao=REGIAO, max_mb=MAX_UPLOAD_MB,
        host=request.host, uso_hoje=analises_hoje(), limite_dia=LIMITE_DIARIO,
        **contexto), status


@application.get("/")
def inicio():
    return pagina()


@application.post("/analisar")
def analisar_imagem():
    arquivo = request.files.get("imagem")
    try:
        if arquivo is None or not arquivo.filename:
            raise imagem_invalida("Selecione uma imagem antes de clicar em Analisar.")
        extensao = os.path.splitext(arquivo.filename)[1].lower()
        if extensao not in EXTENSOES_ACEITAS:
            raise imagem_invalida(
                f"Formato “{extensao or 'sem extensão'}” não suportado. Envie uma foto JPG ou PNG.")
        dados = arquivo.read()
        if not dados:
            raise imagem_invalida("O arquivo enviado está vazio.")
        resultado = analisar(dados)
    except ErroDroneVision as erro:
        return pagina(erro.status, erro=erro.mensagem, tipo_erro=erro.tipo,
                      nome_arquivo=getattr(arquivo, "filename", None))

    log.info("Imagem %s analisada: %d etiquetas, %d objetos",
             arquivo.filename, len(resultado["etiquetas"]), len(resultado["objetos"]))
    return pagina(resultado=resultado, nome_arquivo=arquivo.filename)


@application.errorhandler(413)
def arquivo_grande(_erro):
    return pagina(413, erro=f"Imagem maior que {MAX_UPLOAD_MB} MB. Envie uma foto menor.",
                  tipo_erro="imagem")


@application.get("/saude")
def saude():
    return {"status": "ok", "ambiente": NOME_AMBIENTE, "bedrock": USAR_BEDROCK,
            "analises_hoje": analises_hoje(), "limite_dia": LIMITE_DIARIO}


if __name__ == "__main__":
    # Apenas para teste rápido; a entrega roda no Elastic Beanstalk (gunicorn).
    application.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), debug=False)
