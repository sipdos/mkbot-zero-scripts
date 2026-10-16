#!/usr/bin/env bash
# aplicar_chan_mobile_20ms.sh
# Arregla "sin audio en MicroSIP (PJSIP) llamando por Bluetooth":
#   chan_mobile entrega audio en tramas de 80 bytes slin = 5 ms. Asterisk las manda tal cual por RTP
#   (40 bytes de ulaw cada 5 ms). pjmedia (MicroSIP) descarta todo paquete G.711 de menos de 10 ms,
#   asi que no oye nada. IAX2 acepta cualquier tamano, por eso KIAX si funciona.
#   Solucion: CHANNEL_FRAME_SIZE 80 -> 320 (tramas de 20 ms, ademas 4x menos paquetes por segundo).
# Solo recompila chan_mobile (un archivo). No toca /etc/asterisk ni el resto de modulos.
#   sudo bash aplicar_chan_mobile_20ms.sh            aplica
#   sudo bash aplicar_chan_mobile_20ms.sh restore    vuelve al chan_mobile anterior
set -uo pipefail
MODDIR=${MODDIR:-/usr/lib/asterisk/modules}
SRC=${SRC:-$(ls -d /usr/src/asterisk-22.*.* 2>/dev/null | sort -V | tail -1)}
BK=/root/backup_chan_mobile_frame
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)"; exit 1; }
fallo() { echo "!! $1"; exit 1; }
[ -n "$SRC" ] && [ -f "$SRC/addons/chan_mobile.c" ] || fallo "No encuentro addons/chan_mobile.c (SRC=$SRC)"
C="$SRC/addons/chan_mobile.c"

recargar() {
  if ! asterisk -rx 'core show version' >/dev/null 2>&1; then echo "   Asterisk no esta en marcha: no recargo"; return 0; fi
  if asterisk -rx 'core show channels concise' 2>/dev/null | grep -q '!'; then
    echo "   hay llamada activa: no recargo. Cuando cuelgues: asterisk -rx 'module unload chan_mobile' && asterisk -rx 'module load chan_mobile'"
    return 0
  fi
  asterisk -rx 'module unload chan_mobile' >/dev/null 2>&1
  asterisk -rx 'module load chan_mobile' >/dev/null 2>&1; sleep 4
  if asterisk -rx 'module show like chan_mobile' 2>/dev/null | grep -Eq '^[[:space:]]*chan_mobile\.so.*[[:space:]][0-9]+[[:space:]]+Running'; then
    echo "[ok] chan_mobile en marcha"; asterisk -rx 'mobile show devices'
  else
    echo "!! chan_mobile no arranco. Estado Bluetooth:"; systemctl is-active bluetooth; hciconfig 2>/dev/null | head -4
    echo "   Para volver atras: sudo bash $0 restore"
  fi
}

if [ "${1:-}" = restore ]; then
  [ -f "$BK/chan_mobile.so.orig" ] || fallo "No hay backup en $BK"
  cp -a "$BK/chan_mobile.c.orig" "$C"
  install -m 755 "$BK/chan_mobile.so.orig" "$MODDIR/chan_mobile.so"
  echo "[ok] restaurado chan_mobile original (tramas de 5 ms)"
  recargar; exit 0
fi

echo "== 1. backup (solo la primera vez)"
mkdir -p "$BK"
[ -f "$BK/chan_mobile.c.orig" ]  || cp -a "$C" "$BK/chan_mobile.c.orig"
[ -f "$BK/chan_mobile.so.orig" ] || cp -a "$MODDIR/chan_mobile.so" "$BK/chan_mobile.so.orig" || fallo "No existe $MODDIR/chan_mobile.so"
echo "[ok] backup en $BK"

echo "== 2. parche CHANNEL_FRAME_SIZE 320"
if grep -qE '^#define CHANNEL_FRAME_SIZE[[:space:]]+320$' "$C"; then
  echo "   ya estaba parcheado"
else
  sed -i -E 's/^#define CHANNEL_FRAME_SIZE[[:space:]]+80$/#define CHANNEL_FRAME_SIZE 320/' "$C"
  grep -qE '^#define CHANNEL_FRAME_SIZE[[:space:]]+320$' "$C" || fallo "No pude aplicar el parche (valor original distinto)"
fi
grep -n 'define CHANNEL_FRAME_SIZE' "$C"

echo "== 3. compilar solo chan_mobile con los mismos flags de la compilacion original (-j1)"
cd "$SRC" || fallo "No entro en $SRC"
FL=$(cat .zero_flags 2>/dev/null || true)
OPTF=${FL%% | *}; LDF=${FL##* | }
[ -n "$FL" ] || { OPTF="-O2 -pipe"; LDF=""; }
touch addons/chan_mobile.c
OPTIMIZE=-O2 ASTCFLAGS="$OPTF" ASTLDFLAGS="$LDF" nice -n 10 make -j1 addons >/root/chan_mobile_rebuild.log 2>&1 \
  || { tail -15 /root/chan_mobile_rebuild.log; fallo "fallo la compilacion (log: /root/chan_mobile_rebuild.log)"; }
[ addons/chan_mobile.so -nt "$BK/chan_mobile.so.orig" ] || fallo "No se regenero addons/chan_mobile.so"

echo "== 4. instalar y recargar"
install -m 755 addons/chan_mobile.so "$MODDIR/chan_mobile.so" || fallo "No pude instalar el modulo"
echo "[ok] instalado. Restaurar: sudo bash $0 restore"
recargar
