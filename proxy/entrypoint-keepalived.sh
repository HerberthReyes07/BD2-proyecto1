#!/bin/bash
set -e

# Asignar prioridad y estado por defecto según el nodo si no vienen configurados
if [ -z "$KEEPALIVED_PRIORITY" ]; then
    case "$NODE_NAME" in
        "nodo1")
            KEEPALIVED_PRIORITY=150
            KEEPALIVED_STATE="MASTER"
            ;;
        "nodo2")
            KEEPALIVED_PRIORITY=100
            KEEPALIVED_STATE="BACKUP"
            ;;
        "nodo3")
            KEEPALIVED_PRIORITY=50
            KEEPALIVED_STATE="BACKUP"
            ;;
        *)
            KEEPALIVED_PRIORITY=100
            KEEPALIVED_STATE="BACKUP"
            ;;
    esac
fi

if [ -z "$KEEPALIVED_STATE" ]; then
    if [ "$KEEPALIVED_PRIORITY" -ge 150 ]; then
        KEEPALIVED_STATE="MASTER"
    else
        KEEPALIVED_STATE="BACKUP"
    fi
fi

# Determinar los peers unicast de Tailscale dinámicamente según el nodo actual
case "$NODE_NAME" in
    "nodo1")
        PEER_IP_1="${IP_NODO2}"
        PEER_IP_2="${IP_NODO3}"
        ;;
    "nodo2")
        PEER_IP_1="${IP_NODO1}"
        PEER_IP_2="${IP_NODO3}"
        ;;
    "nodo3")
        PEER_IP_1="${IP_NODO1}"
        PEER_IP_2="${IP_NODO2}"
        ;;
    *)
        PEER_IP_1="${IP_NODO1}"
        PEER_IP_2="${IP_NODO2}"
        ;;
esac

export KEEPALIVED_PRIORITY
export KEEPALIVED_STATE
export PEER_IP_1
export PEER_IP_2
export KEEPALIVED_INTERFACE="${KEEPALIVED_INTERFACE:-tailscale0}"
export VIRTUAL_IP="${VIRTUAL_IP:-100.124.30.200}"

mkdir -p /etc/keepalived
envsubst < /keepalived.conf.template > /etc/keepalived/keepalived.conf

echo "================================================="
echo " [keepalived] Iniciando servicio VRRP en Unicast "
echo " Nodo local  : ${NODE_NAME:-desconocido} (${MY_TAILSCALE_IP:-sin IP})"
echo " Rol / Prior.: ${KEEPALIVED_STATE} (Prioridad ${KEEPALIVED_PRIORITY})"
echo " Interfaz    : ${KEEPALIVED_INTERFACE}"
echo " VIP         : ${VIRTUAL_IP}"
echo " Peers       : ${PEER_IP_1:-no def}, ${PEER_IP_2:-no def}"
echo "================================================="

exec keepalived -n -l -D -f /etc/keepalived/keepalived.conf
