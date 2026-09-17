#!/bin/bash
set -e

# Reemplazar variables de entorno en la plantilla de configuración
envsubst '$IP_NODO1 $IP_NODO2 $IP_NODO3 $NODE_NAME $MY_TAILSCALE_IP' < /usr/local/etc/haproxy/haproxy.cfg.template > /usr/local/etc/haproxy/haproxy.cfg

echo "================================================="
echo " [HAProxy] Iniciando servicio de balanceo/proxy  "
echo " Nodo local : ${NODE_NAME:-desconocido} (${MY_TAILSCALE_IP:-sin IP})"
echo " Backend N1 : ${IP_NODO1:-no def}"
echo " Backend N2 : ${IP_NODO2:-no def}"
echo " Backend N3 : ${IP_NODO3:-no def}"
echo " Puertos    : 5000 (Escritura) | 5001 (Lectura) | 7000 (Stats)"
echo "================================================="

exec haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg
