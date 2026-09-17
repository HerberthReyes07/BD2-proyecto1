#!/bin/sh
# Script ejecutado por keepalived para monitorear HAProxy.
# Si HAProxy responde correctamente en su puerto de estadísticas (7000), retorna 0 (OK).
# Si HAProxy cae o no responde, retorna 1 (fallo), provocando reducción de peso o cesión de la VIP.
curl -s -f http://127.0.0.1:7000/ > /dev/null 2>&1
