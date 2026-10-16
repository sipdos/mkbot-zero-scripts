#!/usr/bin/env bash
# arrancar_asterisk22_zero.sh
# Deja Asterisk 22 compilado y arrancando con IAX2 + PJSIP + dialplan + chan_mobile en la Zero W.
# Idempotente: se puede relanzar y salta lo ya hecho. No toca /etc/asterisk.
#   - SIN swap de ningun tipo (retira /swapfile, dphys-swapfile, fstab y zram)
#   - pjproject: habilita g711/g722/g7221/l16/resample; speex/gsm/ilbc se quedan fuera (su libreria
#     no se enlaza en libasteriskpj y rompe el link); Asterisk no usa los codecs de pjmedia
#   - compila con -O2 y flags para ARM1176 (armv6, VFP hard-float) + LOW_MEMORY
#   - chan_mobile se activa en menuselect y se compila con el resto
# Tarda horas: ejecutalo dentro de tmux.
#   tmux new -s ast22
#   sudo bash arrancar_asterisk22_zero.sh
set -uo pipefail

LOG=/root/asterisk22_build.log
OLD=/usr/src/asterisk-20.21.0
MODDIR=/usr/lib/asterisk/modules
PJ=third-party/pjproject

CPU="-mcpu=arm1176jzf-s -mfpu=vfp -mfloat-abi=hard"
OPTF="-O2 -pipe -fomit-frame-pointer $CPU"
LDF="-Wl,-O1 -Wl,--as-needed"

# Imprescindibles: si menuselect los bloquea, se para ANTES de compilar.
REQ="pbx_config res_timing_timerfd res_crypto chan_iax2 chan_mobile chan_pjsip bridge_simple \
app_dial app_echo app_playback app_stack codec_ulaw codec_alaw codec_gsm codec_g722 codec_adpcm \
codec_resample codec_a_mu format_wav func_jitterbuffer res_pjproject res_sorcery_config \
res_sorcery_memory res_sorcery_astdb res_pjsip res_pjsip_session res_pjsip_authenticator_digest \
res_pjsip_endpoint_identifier_ip res_pjsip_endpoint_identifier_user res_pjsip_sdp_rtp \
res_pjsip_registrar res_pjsip_outbound_registration res_pjsip_pubsub res_rtp_asterisk \
res_statsd res_geolocation res_agi"
# Extras utiles para dialplan/PJSIP (si alguno no existe o esta bloqueado, se ignora).
OPT="bridge_native_rtp bridge_softmix bridge_holding res_speech res_pjsip_outbound_authenticator_digest \
res_pjsip_nat res_pjsip_caller_id res_pjsip_dtmf_info res_pjsip_rfc3326 res_pjsip_refer res_pjsip_acl \
res_pjsip_logger res_pjsip_header_funcs res_pjsip_exten_state res_pjsip_pidf_body_generator \
res_pjsip_xpidf_body_generator res_pjsip_dialog_info_body_generator res_pjsip_config_wizard \
res_pjsip_empty_info res_pjsip_path res_pjsip_dlg_options func_callerid \
func_channel func_logic func_strings func_cut func_global func_timeout func_math func_env \
func_devstate func_volume func_pjsip_aor func_pjsip_contact func_pjsip_endpoint app_exec \
app_senddtmf app_verbose app_read app_system format_wav_gsm format_gsm format_pcm format_sln"
ESSENTIAL="chan_iax2 chan_pjsip chan_mobile res_pjsip res_pjproject pbx_config"

[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)"; exit 1; }
exec > >(tee -a "$LOG") 2>&1
fallo() { echo "!! $1"; echo "   Log: $LOG"; exit 1; }

echo "== 1. backup (se reutiliza el existente; no se borra nada de /etc/asterisk)"
BK=$(ls -dt /root/backup_asterisk20_* 2>/dev/null | head -1)
if [ -z "$BK" ]; then
  BK=/root/backup_asterisk20_$(date +%F_%H%M)
  mkdir -p "$BK"
  [ -d /etc/asterisk ] || fallo "No existe /etc/asterisk"
  cp -a /etc/asterisk "$BK/etc_asterisk"
  [ -f "$MODDIR/chan_mobile.so" ] && cp -a "$MODDIR/chan_mobile.so" "$BK/"
  [ -f "$OLD/addons/chan_mobile.c" ] && cp -a "$OLD/addons/chan_mobile.c" "$BK/"
fi
echo "[ok] backup en $BK"

echo "== 2. sin swap (se desactiva todo: SD, zram y archivos de swap)"
[ -f /etc/fstab.pre_noswap ] || cp -a /etc/fstab /etc/fstab.pre_noswap
swapoff -a 2>/dev/null || true
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
rm -f /swapfile
[ -f /etc/dphys-swapfile ] && sed -i -E 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=0/' /etc/dphys-swapfile
systemctl disable --now dphys-swapfile >/dev/null 2>&1 || true
systemctl disable --now zram-swap.service zramswap.service systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
systemctl mask systemd-zram-setup@zram0.service dev-zram0.swap >/dev/null 2>&1 || true
[ -z "$(swapon --show --noheadings 2>/dev/null)" ] || fallo "Sigue habiendo swap activo: $(swapon --show --noheadings)"
echo "[ok] sin swap. RAM libre: $(free -m | awk '/^Mem:/{print $7}') MB"

echo "== 3. retirar Asterisk 20 (solo si no hay ya una 22 instalada)"
if ! asterisk -V 2>/dev/null | grep -q 'Asterisk 22'; then
  if timeout 5 asterisk -rx 'core show channels concise' 2>/dev/null | grep -q '^IAX2/\|^Mobile/\|^PJSIP/'; then
    fallo "Hay una llamada activa: no paro Asterisk. Cuelga y vuelve a ejecutar"
  fi
  systemctl stop asterisk 2>/dev/null || true
  if [ -d "$MODDIR" ] && [ -f "$OLD/Makefile" ]; then (cd "$OLD" && make uninstall >/dev/null 2>&1) || true; fi
  rm -rf "$MODDIR"
  ldconfig
fi
echo "[ok] configuracion intacta en /etc/asterisk"

echo "== 4. dependencias"
PKGS="build-essential git autoconf automake libtool pkg-config libedit-dev libjansson-dev libsqlite3-dev uuid-dev libxml2-dev libxslt1-dev libncurses-dev libssl-dev libbluetooth-dev"
MISS=""; for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || MISS="$MISS $p"; done
if [ -n "$MISS" ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISS >/dev/null || fallo "apt-get fallo"
fi
FREE=$(df -Pm /usr/src | awk 'NR==2{print $4}')
[ "$FREE" -gt 1500 ] || fallo "Solo hay ${FREE} MB libres en /usr/src (hacen falta ~1500 MB)"
echo "[ok] dependencias listas"

echo "== 5. codigo fuente 22.x"
SRC=$(ls -d /usr/src/asterisk-22.*.* 2>/dev/null | sort -V | tail -1)
if [ -z "$SRC" ] || [ ! -f "$SRC/configure.ac" ]; then
  VER=$(git ls-remote --tags --refs https://github.com/asterisk/asterisk.git 'refs/tags/22.*' \
    | awk -F/ '{print $3}' | grep -E '^22\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  [ -n "$VER" ] || fallo "No encuentro tags 22.x en GitHub"
  SRC=/usr/src/asterisk-$VER
  git clone --depth 1 --branch "$VER" https://github.com/asterisk/asterisk.git "$SRC" || fallo "git clone fallo"
fi
cd "$SRC" || fallo "No entro en $SRC"
echo "[ok] codigo en $SRC"

echo "== 6. pjproject: habilitar g711/g722/g7221/l16/resample (speex/gsm/ilbc no enlazan en Asterisk)"
PJR="$PJ/Makefile.rules"
if [ ! -f "$PJ/.zero_codecs_v2" ]; then
  [ -f "$PJR.orig" ] || cp -a "$PJR" "$PJR.orig"
  cp -a "$PJR.orig" "$PJR"
  sed -i -E 's/[[:space:]]*--disable-(g711-codec|g722-codec|g7221-codec|l16-codec|resample)//g' "$PJR"
  if grep -qE -e '--disable-(g711|g722|g7221|l16)-codec|--disable-resample' "$PJR"; then
    fallo "No pude quitar los --disable de codecs en $PJR"
  fi
  make -C "$PJ" clean >/dev/null 2>&1 || true
  rm -f "$PJ/source/build.mak"
  touch "$PJ/.zero_codecs_v2"
  echo "   parcheado: $PJR (original en $PJR.orig)"
fi
echo "[ok] codecs de pjproject habilitados donde Asterisk lo permite"

echo "== 7. bootstrap + configure (pjproject embebido)"
[ -f configure ] || ./bootstrap.sh > /root/asterisk22_bootstrap.log 2>&1 || fallo "bootstrap fallo (mira /root/asterisk22_bootstrap.log)"
if [ ! -f makeopts ] || [ "$(cat .zero_flags 2>/dev/null)" != "$OPTF | $LDF" ]; then
  CFLAGS="$OPTF" LDFLAGS="$LDF" ./configure --with-pjproject-bundled --disable-xmldoc \
    > /root/asterisk22_configure.log 2>&1 || fallo "configure fallo (mira /root/asterisk22_configure.log)"
  echo "$OPTF | $LDF" > .zero_flags
fi
grep -q '^LIBXSLT_LIB=.*xslt' makeopts || fallo "configure no detecta libxslt"
echo "[ok] configure correcto"

echo "== 8. menuselect: base + chan_mobile + PJSIP + LOW_MEMORY (una sola pasada)"
make menuselect.makeopts >/dev/null 2>&1 || fallo "make menuselect.makeopts fallo"
MS=menuselect/menuselect
ARGS=(--disable-all)
for m in $REQ $OPT LOW_MEMORY; do ARGS+=(--enable "$m"); done
$MS "${ARGS[@]}" menuselect.makeopts || fallo "menuselect no pudo aplicar la seleccion (algun modulo no existe en esta version)"
$MS --check-deps menuselect.makeopts >/dev/null 2>&1 || true

echo "== 9. comprobar bloqueos ANTES de compilar (solo los modulos imprescindibles)"
# Modulos desactivados = los de cada categoria MENUSELECT_*; BUILD_DEPS/CFLAGS/EMBED/DEPSFAILED NO cuentan.
DIS=$(grep -vE '^MENUSELECT_(BUILD_DEPS|CFLAGS|EMBED|DEPSFAILED)=' menuselect.makeopts | sed -n 's/^MENUSELECT_[A-Z_]*=//p' | tr ' ' '\n')
BAD=""; for m in $REQ; do echo "$DIS" | grep -qx "$m" && BAD="$BAD $m"; done
if [ -n "$BAD" ]; then
  echo "   bloqueados:$BAD"
  grep -E '^MENUSELECT_DEPSFAILED=' menuselect.makeopts | grep -wE "$(echo $BAD | tr ' ' '|')" | sed 's/^/   /'
  echo "   dependencias en 0:"; grep '=0$' build_tools/menuselect-deps | tr '\n' ' '; echo
  fallo "menuselect descarta modulos imprescindibles (arriba). Pegame esta salida."
fi
grep -q '^MENUSELECT_CFLAGS=.*LOW_MEMORY' menuselect.makeopts && echo "[ok] LOW_MEMORY activo" || echo "   aviso: LOW_MEMORY no quedo activo"
echo "[ok] sin bloqueos"

echo "== 10. compilar (-j1, nice). Tarda horas."
OPTIMIZE=-O2 ASTCFLAGS="$OPTF" ASTLDFLAGS="$LDF" nice -n 10 make -j1 || fallo "make fallo (mira $LOG)"
if [ -z "$(find addons -name chan_mobile.so -print -quit)" ]; then
  make -C addons ASTTOPDIR="$SRC" SOLINK=-shared chan_mobile.so || true
fi
FALTAN=""
for m in $ESSENTIAL; do
  [ -n "$(find . -name "$m.so" -not -path './third-party/*' -print -quit)" ] || FALTAN="$FALTAN $m"
done
[ -z "$FALTAN" ] || fallo "No se generaron:$FALTAN"
for m in $REQ; do
  [ -n "$(find . -name "$m.so" -not -path './third-party/*' -print -quit)" ] || echo "   aviso: no se genero $m.so"
done
echo "[ok] modulos compilados"
echo "   pjproject configurado con: $(sed -n 's/^  \$ \.\/aconfigure //p' "$PJ/source/config.log" 2>/dev/null | head -1)"

echo "== 11. instalar (sin samples: /etc/asterisk no se toca)"
make install || fallo "make install fallo"
[ -f "$MODDIR/chan_mobile.so" ] || install -m 644 addons/chan_mobile.so "$MODDIR/" || fallo "No pude instalar chan_mobile.so"
ldconfig
echo "[ok] instalado: $(asterisk -V 2>/dev/null)"

echo "== 12. servicio y permisos"
if ! systemctl cat asterisk >/dev/null 2>&1; then
cat > /etc/systemd/system/asterisk.service <<'EOF'
[Unit]
Description=Asterisk 22
After=network-online.target bluetooth.service
Wants=network-online.target bluetooth.service
[Service]
Type=simple
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
fi
RU=$(sed -nE 's/^[[:space:]]*runuser[[:space:]]*=>?[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' /etc/asterisk/asterisk.conf | head -1)
if [ -n "$RU" ] && id "$RU" >/dev/null 2>&1; then
  chown -R "$RU": /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
fi
systemctl daemon-reload
systemctl enable asterisk >/dev/null 2>&1 || true

echo "== 13. arrancar y verificar"
if systemctl is-active -q asterisk && timeout 5 asterisk -rx 'core show channels concise' 2>/dev/null | grep -q '/'; then
  echo "   hay llamada activa: no reinicio"
else
  systemctl restart asterisk
fi
sleep 8
asterisk -rx 'core show version' || fallo "Asterisk no responde (journalctl -u asterisk -n 60)"
corriendo() { asterisk -rx "module show like $1" 2>/dev/null | grep -Eq "^[[:space:]]*$1\.so.*[[:space:]][0-9]+[[:space:]]+Running"; }
OKALL=1
for m in chan_iax2 chan_pjsip chan_mobile pbx_config res_pjsip; do
  if [ "$m" = chan_mobile ] && ! corriendo "$m"; then
    asterisk -rx 'module load chan_mobile' >/dev/null 2>&1; sleep 3
  fi
  if corriendo "$m"; then echo "[ok] $m en marcha"
  else echo "[!!] $m NO esta en marcha"; OKALL=0; fi
done
[ "$OKALL" = 1 ] || { echo "-- Bluetooth"; systemctl is-active bluetooth 2>&1; rfkill list bluetooth 2>&1 | head -4; }
echo "-- PJSIP";   asterisk -rx 'pjsip show transports' 2>&1 | head -8
echo "-- IAX2";    asterisk -rx 'iax2 show peers' 2>&1 | head -8
echo "-- Mobile";  asterisk -rx 'mobile show devices' 2>&1 | head -5
echo "-- Dialplan"; asterisk -rx 'dialplan show from-mobile' 2>&1 | head -12
echo "-- Errores de arranque"
if [ -f /var/log/asterisk/full ]; then tail -n 400 /var/log/asterisk/full; else journalctl -u asterisk -n 400 --no-pager 2>/dev/null; fi \
  | grep -Ei 'error|unable to load|requires|undefined|failed to load' | tail -n 15
[ "$OKALL" = 1 ] && echo "[ok] Asterisk 22 arrancado con IAX2, PJSIP, dialplan y chan_mobile." \
                 || echo "!! Faltan modulos: pegame la seccion 'Errores de arranque'."
echo "Backup: $BK   Log: $LOG"
