#!/bin/bash
# =====================================================================
#  gs-dns-web.sh
#  Global Solution - Linux Services Applications (FIAP)
#  Aluno: Vinicius Degan Silva - RM 569279
#
#  OBJETIVO
#    Automatizar, sem tarefas manuais, a implantacao de:
#      1. Servidor DNS (BIND / named) com zona direta e reversa;
#      2. Servidor Web (Apache / httpd);
#      3. Template HTML baixado da Internet, publicado como pagina
#         padrao do servidor Web.
#
#  METODO (aulas do Prof. Guilherme)
#    instalar -> backup -> configurar -> validar -> systemctl
#    -> testar -> logs
#
#  REQUISITOS
#    - AlmaLinux / Red Hat 8 ou 9, executado como root;
#    - Acesso a Internet (instalacao dos pacotes e download do
#      template). Ex.: adaptador em NAT no VirtualBox.
#
#  USO
#    chmod +x gs-dns-web.sh
#    ./gs-dns-web.sh
#
#  LOG DA EXECUCAO
#    /var/log/gs-dns-web.log
# =====================================================================

LOG=/var/log/gs-dns-web.log
TEMPLATE_PADRAO="https://github.com/StartBootstrap/startbootstrap-landing-page/archive/refs/heads/master.zip"

# ---------------------------------------------------------------------
# Funcoes de mensagens (informacoes/avisos enviados para a tela e log)
# ---------------------------------------------------------------------
VERDE='\e[32m'; VERM='\e[31m'; AMAR='\e[33m'; AZUL='\e[36m'; FIM='\e[0m'

registrar() { echo "$(date '+%F %T') $*" >> "$LOG"; }
info()  { echo -e "${AZUL}[INFO]${FIM}  $*";  registrar "[INFO] $*"; }
ok()    { echo -e "${VERDE}[OK]${FIM}    $*"; registrar "[OK] $*"; }
aviso() { echo -e "${AMAR}[AVISO]${FIM} $*";  registrar "[AVISO] $*"; }
erro()  { echo -e "${VERM}[ERRO]${FIM}  $*";  registrar "[ERRO] $*"; }

etapa() {   # cabecalho de cada etapa
    echo
    echo -e "${AZUL}=====================================================${FIM}"
    echo -e "${AZUL} ETAPA $1 - $2${FIM}"
    echo -e "${AZUL}=====================================================${FIM}"
    registrar "===== ETAPA $1 - $2 ====="
}

abortar() {   # encerra o script mostrando onde parou
    erro "$*"
    erro "Execucao interrompida. Consulte o log: $LOG"
    exit 1
}

# ---------------------------------------------------------------------
# Interacao com o usuario: confirmacao para continuar
# ---------------------------------------------------------------------
confirmar() {   # confirmar "pergunta"  -> continua (s) ou encerra (n)
    local resp
    while :; do
        read -rp "$(echo -e "${AMAR}[?]${FIM} $1 (s/n): ")" resp
        case "${resp,,}" in
            s|sim) registrar "[CONFIRMACAO] $1 -> sim"; return 0 ;;
            n|nao) registrar "[CONFIRMACAO] $1 -> nao"
                   aviso "Operacao cancelada pelo usuario."
                   exit 0 ;;
            *)     aviso "Responda apenas s ou n." ;;
        esac
    done
}

perguntar() {   # perguntar VARIAVEL "texto" "valor padrao"
    local resp
    read -rp "$2 [$3]: " resp
    printf -v "$1" '%s' "${resp:-$3}"
}

ip_valido() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o; IFS=. read -ra o <<< "$1"
    for n in "${o[@]}"; do (( n <= 255 )) || return 1; done
}

backup() {   # copia do original (.bkp) + copia datada antes de alterar
    local arq=$1
    [ -f "$arq" ] || return 0
    [ -f "${arq}.bkp" ] || cp -p "$arq" "${arq}.bkp"
    cp -p "$arq" "${arq}.$(date +%Y%m%d-%H%M%S).bkp"
    info "Backup realizado: $arq"
}

liberar_firewall() {   # libera um servico no firewalld (se ativo)
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service="$1" >/dev/null && \
        firewall-cmd --reload >/dev/null && ok "Firewall: servico '$1' liberado"
    else
        aviso "firewalld inativo - liberacao de '$1' nao necessaria"
    fi
}

incrementar_serial() {   # incrementa o serial do SOA de um arquivo de zona
    local atual
    atual=$(grep -m1 '; serial' "$1" | awk '{print $1}')
    sed -i "s/${atual} ; serial/$((atual + 1)) ; serial/" "$1"
}

# =====================================================================
# ETAPA 0 - Verificacoes iniciais
# =====================================================================
etapa 0 "Verificacoes iniciais"
[ "$EUID" -eq 0 ] || { echo "Execute como root."; exit 1; }
touch "$LOG"
info "Script iniciado por $(whoami) em $(hostname)"
grep -qiE 'almalinux|red hat|rocky|centos' /etc/os-release \
    && ok "Sistema: $(grep '^PRETTY_NAME' /etc/os-release | cut -d'"' -f2)" \
    || aviso "Sistema nao identificado como Red Hat/derivado"

info "Testando acesso a Internet (necessario para pacotes e template)..."
if curl -s -o /dev/null --max-time 10 https://github.com; then
    ok "Acesso a Internet disponivel"
else
    abortar "Sem acesso a Internet. Coloque o adaptador da VM em NAT e execute novamente."
fi

echo
info "Este script vai instalar e configurar:"
info "  - Servidor DNS (BIND) com zona direta e reversa"
info "  - Servidor Web (Apache) com um template HTML da Internet"
confirmar "Deseja iniciar a implantacao?"

# =====================================================================
# ETAPA 1 - Coleta de dados (dominio, IP e registros DNS)
# =====================================================================
etapa 1 "Coleta de dados"

IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
IP_DETECTADO=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

while :; do
    perguntar DOMINIO "Nome do dominio a ser criado" "lab-vinicius.local"
    [[ $DOMINIO =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] && break
    erro "Dominio invalido (ex.: empresa.local)"
done
DOMINIO=${DOMINIO,,}

while :; do
    perguntar IP_SRV "IP deste servidor (DNS e Web)" "${IP_DETECTADO:-172.20.0.10}"
    ip_valido "$IP_SRV" && break
    erro "IP invalido"
done

BASE=${IP_SRV%.*}                              # ex.: 172.20.0
IFS=. read -r O1 O2 O3 <<< "$BASE"
REVERSA="${O3}.${O2}.${O1}.in-addr.arpa"      # ex.: 0.20.172.in-addr.arpa
ZD="/var/named/${DOMINIO}.zone"                # zona direta
ZR="/var/named/${BASE}.zone"                   # zona reversa
SERIAL="$(date +%Y%m%d)01"

# Registros obrigatorios: NS (ns1) e A do proprio servidor
REG_DIRETA="ns1     IN      A       ${IP_SRV}"$'\n'
REG_REVERSA="${IP_SRV##*.}      IN      PTR     ns1.${DOMINIO}."$'\n'
TEM_WWW=0
RESUMO="  NS     @ -> ns1.${DOMINIO}"$'\n'"  A      ns1 -> ${IP_SRV}"$'\n'

echo
info "Registros NS (ns1.${DOMINIO}) e A (ns1 -> ${IP_SRV}) serao criados automaticamente."
info "Agora informe os registros adicionais. Tipos aceitos: A, CNAME, MX, TXT."
info "Deixe o tipo em branco e pressione ENTER para finalizar."

while :; do
    echo
    read -rp "Tipo do registro (A/CNAME/MX/TXT ou ENTER para finalizar): " TIPO
    TIPO=${TIPO^^}
    [ -z "$TIPO" ] && break
    case "$TIPO" in
        A)
            read -rp "  Nome do host (ex.: www, ftp, cliente01): " NOME
            read -rp "  Endereco IP de ${NOME}.${DOMINIO}: " IPR
            ip_valido "$IPR" || { erro "IP invalido - registro ignorado"; continue; }
            REG_DIRETA+="${NOME}     IN      A       ${IPR}"$'\n'
            [ "${IPR%.*}" = "$BASE" ] && \
                REG_REVERSA+="${IPR##*.}      IN      PTR     ${NOME}.${DOMINIO}."$'\n'
            [ "$NOME" = "www" ] && TEM_WWW=1
            RESUMO+="  A      ${NOME} -> ${IPR}"$'\n'
            ;;
        CNAME)
            read -rp "  Apelido (ex.: ftp, site): " NOME
            read -rp "  Aponta para qual host do dominio (ex.: www): " ALVO
            REG_DIRETA+="${NOME}     IN      CNAME   ${ALVO}.${DOMINIO}."$'\n'
            [ "$NOME" = "www" ] && TEM_WWW=1
            RESUMO+="  CNAME  ${NOME} -> ${ALVO}.${DOMINIO}"$'\n'
            ;;
        MX)
            read -rp "  Prioridade (ex.: 10): " PRIO
            read -rp "  Nome do servidor de e-mail (ex.: mail): " NOME
            read -rp "  Endereco IP de ${NOME}.${DOMINIO}: " IPR
            ip_valido "$IPR" || { erro "IP invalido - registro ignorado"; continue; }
            REG_DIRETA+="@       IN      MX      ${PRIO:-10}      ${NOME}.${DOMINIO}."$'\n'
            REG_DIRETA+="${NOME}     IN      A       ${IPR}"$'\n'
            [ "${IPR%.*}" = "$BASE" ] && \
                REG_REVERSA+="${IPR##*.}      IN      PTR     ${NOME}.${DOMINIO}."$'\n'
            RESUMO+="  MX     ${PRIO:-10} ${NOME}.${DOMINIO} (A -> ${IPR})"$'\n'
            ;;
        TXT)
            read -rp "  Nome (@ para o proprio dominio): " NOME
            read -rp "  Texto (ex.: v=spf1 mx -all): " TXT
            REG_DIRETA+="${NOME:-@}       IN      TXT     \"${TXT}\""$'\n'
            RESUMO+="  TXT    ${NOME:-@} -> \"${TXT}\""$'\n'
            ;;
        *)
            erro "Tipo nao suportado: $TIPO"
            continue
            ;;
    esac
    ok "Registro $TIPO adicionado a lista"
done

# O template sera acessado por www.<dominio>; garante o registro
if [ "$TEM_WWW" -eq 0 ]; then
    REG_DIRETA+="www     IN      A       ${IP_SRV}"$'\n'
    RESUMO+="  A      www -> ${IP_SRV} (criado automaticamente para o site)"$'\n'
    aviso "Registro 'www' nao informado - criado apontando para ${IP_SRV}"
fi

echo
perguntar TEMPLATE_URL "URL do template HTML (.zip)" "$TEMPLATE_PADRAO"

echo
info "Resumo da implantacao:"
echo "  Dominio .........: ${DOMINIO}"
echo "  IP do servidor ..: ${IP_SRV} (${IFACE:-interface padrao})"
echo "  Zona reversa ....: ${REVERSA}"
echo "  Registros DNS ...:"
echo -n "$RESUMO"
echo "  Template ........: ${TEMPLATE_URL}"
registrar "Dominio=$DOMINIO IP=$IP_SRV Template=$TEMPLATE_URL"
echo
confirmar "Os dados estao corretos? Continuar"

# =====================================================================
# ETAPA 2 - Instalacao dos pacotes
# =====================================================================
etapa 2 "Instalacao dos pacotes (bind, bind-utils, httpd, wget, unzip)"
info "Instalando pacotes com o gerenciador YUM..."
yum install -y bind bind-utils httpd wget unzip >> "$LOG" 2>&1 \
    || abortar "Falha na instalacao dos pacotes"
for p in bind bind-utils httpd wget unzip; do
    ok "Pacote instalado: $(rpm -q "$p")"
done

# =====================================================================
# ETAPA 3 - Servidor DNS (BIND)
# =====================================================================
etapa 3 "Configuracao do Servidor DNS (BIND)"
confirmar "Configurar o Servidor DNS para o dominio ${DOMINIO}?"
NC=/etc/named.conf
backup "$NC"

info "Liberando consultas da rede (listen-on e allow-query = any)"
sed -i -E 's/listen-on port 53 \{[^}]*\};/listen-on port 53 { any; };/' "$NC"
sed -i -E 's/allow-query[[:space:]]*\{[^}]*\};/allow-query     { any; };/' "$NC"

info "Declarando as zonas direta e reversa no $NC"
if grep -q "zone \"${DOMINIO}\"" "$NC"; then
    aviso "Zona ${DOMINIO} ja declarada - mantida"
else
    cat >> "$NC" <<EOF

// Zona direta - ${DOMINIO}
zone "${DOMINIO}" IN {
        type master;
        file "${DOMINIO}.zone";
        allow-update { none; };
};
EOF
fi
if grep -q "zone \"${REVERSA}\"" "$NC"; then
    aviso "Zona ${REVERSA} ja declarada - mantida"
else
    cat >> "$NC" <<EOF

// Zona reversa - ${BASE}.0/24
zone "${REVERSA}" IN {
        type master;
        file "${BASE}.zone";
        allow-update { none; };
};
EOF
fi
ok "Zonas declaradas: ${DOMINIO} e ${REVERSA}"

info "Criando o arquivo de zona direta: $ZD"
backup "$ZD"
cat > "$ZD" <<EOF
\$TTL 300
@       IN      SOA     ns1.${DOMINIO}.     root.${DOMINIO}. (
        ${SERIAL} ; serial
        7200       ; refresh (2 hours)
        3600       ; retry (1 hour)
        86400      ; expire (24 hours)
        300        ; minimum TTL (5 minutes)
        )

@       IN      NS      ns1.${DOMINIO}.

${REG_DIRETA}
EOF

info "Criando o arquivo de zona reversa: $ZR"
backup "$ZR"
cat > "$ZR" <<EOF
\$TTL 300
@       IN      SOA     ns1.${DOMINIO}.     root.${DOMINIO}. (
        ${SERIAL} ; serial
        7200       ; refresh (2 hours)
        3600       ; retry (1 hour)
        86400      ; expire (24 hours)
        300        ; minimum TTL (5 minutes)
        )

@       IN      NS      ns1.${DOMINIO}.

${REG_REVERSA}
EOF

info "Ajustando dono, permissoes e contexto SELinux dos arquivos de zona"
chown root:named "$ZD" "$ZR"
chmod 640 "$ZD" "$ZR"
restorecon -R /var/named 2>/dev/null

info "Validando a sintaxe (named-checkconf / named-checkzone)"
named-checkconf "$NC" || abortar "Erro de sintaxe no $NC"
named-checkzone "$DOMINIO" "$ZD" | tee -a "$LOG" || abortar "Erro na zona direta"
named-checkzone "$REVERSA" "$ZR" | tee -a "$LOG" || abortar "Erro na zona reversa"
ok "Arquivos de configuracao do DNS validados"

info "Firewall: interface como LAN confiavel (RHEL 8+) e servico DNS"
if systemctl is-active --quiet firewalld && [ -n "$IFACE" ]; then
    firewall-cmd --permanent --zone=trusted --add-interface="$IFACE" >/dev/null 2>&1
fi
liberar_firewall dns

info "Iniciando e habilitando o servico named"
systemctl enable named >/dev/null 2>&1
systemctl restart named || { journalctl -u named -n 20 --no-pager; abortar "O servico named nao iniciou"; }
ok "Servico named: $(systemctl is-active named) / $(systemctl is-enabled named)"

# =====================================================================
# ETAPA 4 - Servidor Web (Apache)
# =====================================================================
etapa 4 "Configuracao do Servidor Web (Apache)"
confirmar "Configurar o Servidor Web Apache?"
HC=/etc/httpd/conf/httpd.conf
backup "$HC"

info "Definindo ServerName www.${DOMINIO} e ServerAdmin"
sed -i -E "s|^#?ServerName .*|ServerName www.${DOMINIO}:80|" "$HC"
sed -i -E "s|^ServerAdmin .*|ServerAdmin root@${DOMINIO}|" "$HC"

info "Ocultando a versao do Apache (ServerTokens Prod)"
if ! grep -q '^ServerTokens' "$HC"; then
    printf '\n# Oculta a versao do servidor Web (recomendacao de seguranca)\nServerTokens Prod\n' >> "$HC"
fi

info "Validando a sintaxe do Apache (httpd -t)"
httpd -t 2>&1 | tee -a "$LOG"
httpd -t >/dev/null 2>&1 || abortar "Erro de sintaxe no $HC"
ok "httpd.conf validado"

# =====================================================================
# ETAPA 5 - Template HTML da Internet
# =====================================================================
etapa 5 "Download e publicacao do Template HTML"
confirmar "Baixar o template e publicar como pagina padrao?"
TMP=$(mktemp -d /tmp/template.XXXX)

info "Baixando o template: $TEMPLATE_URL"
wget -q -O "$TMP/template.zip" "$TEMPLATE_URL" || abortar "Falha no download do template"
ok "Download concluido ($(du -h "$TMP/template.zip" | cut -f1))"

info "Descompactando o template"
unzip -q "$TMP/template.zip" -d "$TMP/extraido" || abortar "Arquivo baixado nao e um .zip valido"

# Localiza a pasta do site (a que contem o index.html mais proximo da raiz)
INDEX=$(find "$TMP/extraido" -name index.html -printf '%d %p\n' | sort -n | head -1 | cut -d' ' -f2-)
[ -n "$INDEX" ] || abortar "Nenhum index.html encontrado no template"
SITE_DIR=$(dirname "$INDEX")
ok "Pasta do site encontrada: ${SITE_DIR#"$TMP"/extraido/}"

info "Fazendo backup do conteudo atual de /var/www/html"
if [ -n "$(ls -A /var/www/html 2>/dev/null)" ]; then
    tar -czf "/var/www/html-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C /var/www html
    rm -rf /var/www/html/*
fi

info "Publicando o template em /var/www/html"
cp -r "$SITE_DIR"/. /var/www/html/
chown -R apache:apache /var/www/html
restorecon -R /var/www/html 2>/dev/null
rm -rf "$TMP"
ok "Template publicado ($(find /var/www/html -type f | wc -l) arquivos)"

liberar_firewall http

info "Iniciando e habilitando o servico httpd"
systemctl enable httpd >/dev/null 2>&1
systemctl restart httpd || { journalctl -u httpd -n 20 --no-pager; abortar "O servico httpd nao iniciou"; }
ok "Servico httpd: $(systemctl is-active httpd) / $(systemctl is-enabled httpd)"

# =====================================================================
# ETAPA 6 - TAREFAS EXTRAS DA GLOBAL SOLUTION (incluir em sala)
# ---------------------------------------------------------------------
#  No dia da GS serao solicitadas mais 3 tarefas. Inclua cada uma
#  abaixo, mantendo o padrao: etapa -> confirmar -> info/ok -> abortar.
#
#  etapa 6 "Tarefa extra 1 - <descricao>"
#  confirmar "Executar a tarefa extra 1?"
#  info "..."
#  comandos ... || abortar "..."
#  ok "..."
# =====================================================================

# =====================================================================
# ETAPA 7 - Testes finais
# =====================================================================
etapa 7 "Testes finais"

info "Teste DNS - zona direta (www.${DOMINIO})"
nslookup "www.${DOMINIO}" "$IP_SRV" | tee -a "$LOG"

info "Teste DNS - zona direta (ns1.${DOMINIO})"
nslookup "ns1.${DOMINIO}" "$IP_SRV" | tee -a "$LOG"

info "Teste DNS - zona reversa (${IP_SRV})"
nslookup "$IP_SRV" "$IP_SRV" | tee -a "$LOG"

info "Teste Web - acesso pelo FQDN, resolvido pelo DNS criado"
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' --resolve "www.${DOMINIO}:80:${IP_SRV}" "http://www.${DOMINIO}/")
if [ "$CODIGO" = "200" ]; then
    ok "http://www.${DOMINIO} respondeu HTTP 200"
    curl -s "http://${IP_SRV}/" | grep -m1 -i '<title>' | sed 's/^[[:space:]]*/  Titulo da pagina: /'
else
    aviso "http://www.${DOMINIO} respondeu HTTP ${CODIGO}"
fi

# =====================================================================
# Resumo
# =====================================================================
etapa "FINAL" "Resumo"
printf '  %-8s %s\n' named "$(systemctl is-active named)" httpd "$(systemctl is-active httpd)"
echo
info "Portas em escuta:"
ss -tulpn | grep -E ':(53|80)\b' | awk '{print "  "$1, $5}' | sort -u
echo
ok "Implantacao concluida!"
info "No cliente, use ${IP_SRV} como DNS e acesse: http://www.${DOMINIO}"
info "Arquivos: $NC | $ZD | $ZR | $HC"
info "Log completo da execucao: $LOG"
