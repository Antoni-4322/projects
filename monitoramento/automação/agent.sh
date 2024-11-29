#!/bin/bash

# Função para atualizar ou adicionar uma configuração
update_config() {
    local file=$1
    local key=$2
    local value=$3

    # Verifica se a configuração existe e está comentada
    if grep -q "^# *$key=" "$file"; then
        sed -i "s/^# *$key=.*/$key=$value/" "$file"
    # Verifica se a configuração já está definida com valor diferente
    elif grep -q "^$key=" "$file"; then
        current_value=$(grep "^$key=" "$file" | cut -d'=' -f2)
        if [ "$current_value" != "$value" ]; then
            sed -i "s/^$key=.*/$key=$value/" "$file"
        fi
    else
        # Adiciona a configuração ao final do arquivo
        echo "$key=$value" >> "$file"
    fi
}

# Verifica se o Zabbix Agent já está instalado
if dpkg -l | grep -q "zabbix-agent"; then
    echo "O Zabbix Agent já está instalado. Prosseguindo com a configuração..."
else
    echo "O Zabbix Agent não está instalado. Instalando agora..."

    # Baixa e instala o Zabbix release package
    wget -O zabbix-release.deb "https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest%2Bdebian12_all.deb"
    dpkg -i zabbix-release.deb

    # Atualiza pacotes e instala o Zabbix Agent
    apt update && apt install zabbix-agent -y
fi

# Solicita entradas do usuário
read -p "Digite o IP do servidor Zabbix (Server): " server
read -p "Digite o IP do servidor ativo Zabbix (ServerActive): " serveractive
read -p "Digite o hostname para o agente Zabbix (Hostname): " hostname

# Caminho do arquivo de configuração
config_file="/etc/zabbix/zabbix_agentd.conf"

# Atualiza o arquivo de configuração
update_config "$config_file" "Server" "$server"
update_config "$config_file" "ServerActive" "$serveractive"
update_config "$config_file" "Hostname" "$hostname"
update_config "$config_file" "RefreshActiveChecks" "60"
update_config "$config_file" "HostMetadata" "Linux"

# Reinicia o agente para aplicar as alterações
systemctl restart zabbix-agent

echo "Configuração concluída. O agente Zabbix foi reiniciado com sucesso."
