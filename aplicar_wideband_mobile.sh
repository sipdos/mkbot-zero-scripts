#!/usr/bin/env bash
# aplicar_wideband_mobile.sh
# Audio de banda ancha (HFP mSBC, 16 kHz) en chan_mobile:
#   - negocia el codec con el movil (AT+BRSF bit 7, AT+BAC=1,2, +BCS/AT+BCS) y acepta el SCO como "transparent"
#   - codifica/decodifica mSBC con libsbc (cargada en tiempo de ejecucion; si falta, todo sigue en CVSD)
#   - el canal Mobile pasa a slin16 cuando quien llama acepta slin16/g722; si no, sigue en 8 kHz
#   - si el movil elige CVSD, convierte 8k<->16k y sigue funcionando
# Se activa con 'widebandspeech=yes' (en [general] o en el dispositivo) de chan_mobile.conf; sin esa linea todo queda como antes.
# Solo recompila chan_mobile. No toca /etc/asterisk.
#   sudo bash aplicar_wideband_mobile.sh            aplica (reinicia Asterisk si no hay llamadas)
#   sudo bash aplicar_wideband_mobile.sh restore    vuelve al chan_mobile anterior
set -uo pipefail
MODDIR=${MODDIR:-/usr/lib/asterisk/modules}
SRC=${SRC:-$(ls -d /usr/src/asterisk-22.*.* 2>/dev/null | sort -V | tail -1)}
BK=/root/backup_wideband_mobile
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)"; exit 1; }
fallo() { echo "!! $1"; exit 1; }
[ -n "$SRC" ] && [ -f "$SRC/addons/chan_mobile.c" ] || fallo "No encuentro addons/chan_mobile.c (SRC=$SRC)"
C="$SRC/addons/chan_mobile.c"
corriendo() { asterisk -rx "module show like chan_mobile" 2>/dev/null | grep -Eq '^[[:space:]]*chan_mobile\.so.*[[:space:]][0-9]+[[:space:]]+Running'; }

reiniciar() {
  if ! command -v asterisk >/dev/null 2>&1 || ! asterisk -rx 'core show version' >/dev/null 2>&1; then
    echo "   Asterisk no esta en marcha: nada que reiniciar"; return 0
  fi
  if asterisk -rx 'core show channels concise' 2>/dev/null | grep -q '!'; then
    echo "   hay una llamada activa: no reinicio. Cuando cuelgues: sudo systemctl restart asterisk"; return 0
  fi
  systemctl restart asterisk
  for i in $(seq 1 40); do asterisk -rx 'core show version' >/dev/null 2>&1 && break; sleep 1; done
  sleep 5
  if corriendo; then
    echo "[ok] chan_mobile en marcha"; asterisk -rx 'mobile show devices'
  else
    echo "!! chan_mobile no arranco (journalctl -u asterisk -n 40). Para volver atras: sudo bash $0 restore"
  fi
}

if [ "${1:-}" = restore ]; then
  [ -f "$BK/chan_mobile.so.orig" ] || fallo "No hay backup en $BK"
  cp -a "$BK/chan_mobile.c.orig" "$C"
  install -m 755 "$BK/chan_mobile.so.orig" "$MODDIR/chan_mobile.so"
  echo "[ok] restaurado el chan_mobile anterior al parche wideband"
  reiniciar; exit 0
fi

echo "== 1. backup (solo la primera vez)"
mkdir -p "$BK"
[ -f "$BK/chan_mobile.c.orig" ]  || cp -a "$C" "$BK/chan_mobile.c.orig"
[ -f "$BK/chan_mobile.so.orig" ] || cp -a "$MODDIR/chan_mobile.so" "$BK/chan_mobile.so.orig" || fallo "No existe $MODDIR/chan_mobile.so"
echo "[ok] backup en $BK"

echo "== 2. libsbc (codec mSBC)"
if [ ! -f /usr/include/sbc/sbc.h ] || ! ldconfig -p 2>/dev/null | grep -q 'libsbc\.so\.1'; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libsbc-dev libsbc1 >/dev/null || fallo "no pude instalar libsbc-dev"
fi
[ -f /usr/include/sbc/sbc.h ] || fallo "falta /usr/include/sbc/sbc.h"
echo "[ok] libsbc disponible"

echo "== 3. parche wideband en chan_mobile.c"
command -v python3 >/dev/null 2>&1 || fallo "falta python3"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/wb_helpers.c" <<'WB_HELPERS_EOF'
/* ---- wideband speech: HFP codec negotiation + mSBC over transparent SCO (patch widebandspeech) ---- */
#define MSBC_PCM_BYTES   240	/* 120 samples @16 kHz = 7.5 ms */
#define MSBC_FRAME_BYTES 57
#define MSBC_PKT_BYTES   60	/* H2 header (2) + frame (57) + pad (1) */

static void *sbc_lib;
static int (*p_sbc_init_msbc)(sbc_t *sbc, unsigned long flags);
static ssize_t (*p_sbc_encode)(sbc_t *sbc, const void *input, size_t input_len, void *output, size_t output_len, ssize_t *written);
static ssize_t (*p_sbc_decode)(sbc_t *sbc, const void *input, size_t input_len, void *output, size_t output_len, size_t *written);
static void (*p_sbc_finish)(sbc_t *sbc);

static int msbc_load(void)
{
	if (sbc_lib) {
		return 0;
	}
	sbc_lib = dlopen("libsbc.so.1", RTLD_NOW | RTLD_LOCAL);
	if (!sbc_lib) {
		return -1;
	}
	*(void **) (&p_sbc_init_msbc) = dlsym(sbc_lib, "sbc_init_msbc");
	*(void **) (&p_sbc_encode) = dlsym(sbc_lib, "sbc_encode");
	*(void **) (&p_sbc_decode) = dlsym(sbc_lib, "sbc_decode");
	*(void **) (&p_sbc_finish) = dlsym(sbc_lib, "sbc_finish");
	if (!p_sbc_init_msbc || !p_sbc_encode || !p_sbc_decode || !p_sbc_finish) {
		dlclose(sbc_lib);
		sbc_lib = NULL;
		return -1;
	}
	return 0;
}

static void msbc_unload(void)
{
	if (sbc_lib) {
		dlclose(sbc_lib);
		sbc_lib = NULL;
	}
}

static void msbc_stop(struct mbl_pvt *pvt)
{
	if (pvt->msbc_enc) {
		p_sbc_finish(pvt->msbc_enc);
		ast_free(pvt->msbc_enc);
		pvt->msbc_enc = NULL;
	}
	if (pvt->msbc_dec) {
		p_sbc_finish(pvt->msbc_dec);
		ast_free(pvt->msbc_dec);
		pvt->msbc_dec = NULL;
	}
}

static int msbc_start(struct mbl_pvt *pvt)
{
	msbc_stop(pvt);
	if (!sbc_lib) {
		return -1;
	}
	if (!(pvt->msbc_enc = ast_calloc(1, sizeof(sbc_t)))) {
		return -1;
	}
	if (p_sbc_init_msbc(pvt->msbc_enc, 0) < 0) {
		ast_free(pvt->msbc_enc);
		pvt->msbc_enc = NULL;
		return -1;
	}
	if (!(pvt->msbc_dec = ast_calloc(1, sizeof(sbc_t)))) {
		msbc_stop(pvt);
		return -1;
	}
	if (p_sbc_init_msbc(pvt->msbc_dec, 0) < 0) {
		ast_free(pvt->msbc_dec);
		pvt->msbc_dec = NULL;
		msbc_stop(pvt);
		return -1;
	}
	pvt->msbc_tx_seq = 0;
	pvt->msbc_rx_len = 0;
	pvt->msbc_rx_seq = -1;
	return 0;
}

/* 240 bytes of slin16 -> one 60 byte SCO packet */
static int msbc_encode_pkt(struct mbl_pvt *pvt, const void *pcm, unsigned char *pkt)
{
	static const unsigned char seqhdr[4] = { 0x08, 0x38, 0xc8, 0xf8 };
	ssize_t written = 0;

	if (!pvt->msbc_enc) {
		return -1;
	}
	pkt[0] = 0x01;
	pkt[1] = seqhdr[pvt->msbc_tx_seq & 3];
	pvt->msbc_tx_seq++;
	if (p_sbc_encode(pvt->msbc_enc, pcm, MSBC_PCM_BYTES, pkt + 2, MSBC_FRAME_BYTES, &written) < 0
		|| written != MSBC_FRAME_BYTES) {
		return -1;
	}
	pkt[MSBC_PKT_BYTES - 1] = 0x00;
	return 0;
}

/* Resample between 8 and 16 kHz (2-tap average down, linear interpolation up). */
static int wb_resample(const short *in, int n, int in_rate, int out_rate, short *out, short *prev)
{
	int i, o = 0;

	if (in_rate == out_rate) {
		memcpy(out, in, n * sizeof(short));
		return n;
	}
	if (in_rate == 16000) {
		for (i = 0; i + 1 < n; i += 2) {
			out[o++] = (short) (((int) in[i] + (int) in[i + 1]) / 2);
		}
		return o;
	}
	for (i = 0; i < n; i++) {
		out[o++] = (short) (((int) *prev + (int) in[i]) / 2);
		out[o++] = in[i];
		*prev = in[i];
	}
	return o;
}

/* Append PCM coming from the SCO side to the channel side accumulator. */
static void wb_rx_push(struct mbl_pvt *pvt, const short *pcm, int n, int src_rate)
{
	short tmp[480];
	int chan_rate = pvt->wide ? 16000 : 8000;

	while (n > 0) {
		int c = n > 240 ? 240 : n;
		int o = wb_resample(pcm, c, src_rate, chan_rate, tmp, &pvt->rx_prev);

		if (pvt->wrx_len + o * 2 > (int) sizeof(pvt->wrx)) {
			pvt->wrx_len = 0;	/* hopeless backlog: drop it */
		}
		memcpy(pvt->wrx + pvt->wrx_len, tmp, o * 2);
		pvt->wrx_len += o * 2;
		pcm += c;
		n -= c;
	}
}

/* Bytes read from the transparent SCO socket (any chunking) -> decoded PCM. */
static void msbc_rx_feed(struct mbl_pvt *pvt, const unsigned char *data, int len)
{
	int i = 0;

	if (pvt->msbc_rx_len + len > (int) sizeof(pvt->msbc_rx)) {
		pvt->msbc_rx_len = 0;
	}
	memcpy(pvt->msbc_rx + pvt->msbc_rx_len, data, len);
	pvt->msbc_rx_len += len;

	while (pvt->msbc_rx_len - i >= MSBC_PKT_BYTES) {
		const unsigned char *b = pvt->msbc_rx + i;
		int idx = -1;
		short pcm[MSBC_PCM_BYTES / 2];

		if (b[0] == 0x01 && b[2] == 0xad) {
			idx = b[1] == 0x08 ? 0 : b[1] == 0x38 ? 1 : b[1] == 0xc8 ? 2 : b[1] == 0xf8 ? 3 : -1;
		}
		if (idx < 0) {
			i++;
			continue;
		}
		if (pvt->msbc_rx_seq >= 0) {
			int lost = (idx - pvt->msbc_rx_seq) & 3;

			pvt->wb_rx_lost += lost;
			memset(pcm, 0, sizeof(pcm));
			while (lost-- > 0) {
				wb_rx_push(pvt, pcm, MSBC_PCM_BYTES / 2, 16000);
			}
		}
		pvt->msbc_rx_seq = (idx + 1) & 3;
		pvt->wb_rx_pkts++;
		{
			size_t out = 0;

			if (!pvt->msbc_dec
				|| p_sbc_decode(pvt->msbc_dec, b + 2, MSBC_FRAME_BYTES, pcm, MSBC_PCM_BYTES, &out) < 0
				|| out != MSBC_PCM_BYTES) {
				memset(pcm, 0, sizeof(pcm));
				pvt->wb_rx_bad++;
			}
		}
		wb_rx_push(pvt, pcm, MSBC_PCM_BYTES / 2, 16000);
		i += MSBC_PKT_BYTES;
	}
	if (i > 0) {
		pvt->msbc_rx_len -= i;
		memmove(pvt->msbc_rx, pvt->msbc_rx + i, pvt->msbc_rx_len);
	}
}

/* Channel PCM (slin or slin16) -> SCO (mSBC packets, or CVSD 48 byte writes). */
static void wb_tx(struct mbl_pvt *pvt, const short *pcm, int n)
{
	int msbc = pvt->sco_codec == 2;
	int sco_rate = msbc ? 16000 : 8000;
	int chan_rate = pvt->wide ? 16000 : 8000;
	int unit = msbc ? MSBC_PCM_BYTES : DEVICE_FRAME_SIZE;
	short tmp[480];

	while (n > 0) {
		int c = n > 240 ? 240 : n;
		int o = wb_resample(pcm, c, chan_rate, sco_rate, tmp, &pvt->tx_prev);

		if (pvt->wtx_len + o * 2 > (int) sizeof(pvt->wtx)) {
			pvt->wtx_len = 0;
		}
		memcpy(pvt->wtx + pvt->wtx_len, tmp, o * 2);
		pvt->wtx_len += o * 2;
		pcm += c;
		n -= c;
		while (pvt->wtx_len >= unit) {
			if (msbc) {
				unsigned char pkt[MSBC_PKT_BYTES];

				if (!msbc_encode_pkt(pvt, pvt->wtx, pkt)) {
					sco_write(pvt->sco_socket, (char *) pkt, MSBC_PKT_BYTES);
					pvt->wb_tx_pkts++;
				}
			} else {
				sco_write(pvt->sco_socket, (char *) pvt->wtx, DEVICE_FRAME_SIZE);
			}
			pvt->wtx_len -= unit;
			memmove(pvt->wtx, pvt->wtx + unit, pvt->wtx_len);
		}
	}
}
WB_HELPERS_EOF
cat > "$TMP/wb_chan.c" <<'WB_CHAN_EOF'
/* Wideband engine: used when the channel is slin16 or the audio connection is mSBC.
 * Called with pvt->lock held. */
static struct ast_frame *mbl_read_wb(struct ast_channel *ast, struct mbl_pvt *pvt)
{
	unsigned char buf[256];
	int fs = pvt->wide ? 640 : 320;
	int r;

	for (;;) {
		if (pvt->wrx_len >= fs) {
			memcpy(pvt->io_buf + AST_FRIENDLY_OFFSET, pvt->wrx, fs);
			pvt->wrx_len -= fs;
			memmove(pvt->wrx, pvt->wrx + fs, pvt->wrx_len);

			memset(&pvt->fr, 0x00, sizeof(struct ast_frame));
			pvt->fr.frametype = AST_FRAME_VOICE;
			pvt->fr.subclass.format = pvt->wide ? ast_format_slin16 : ast_format_slin;
			pvt->fr.src = "Mobile";
			pvt->fr.offset = AST_FRIENDLY_OFFSET;
			pvt->fr.mallocd = 0;
			pvt->fr.data.ptr = pvt->io_buf + AST_FRIENDLY_OFFSET;
			pvt->fr.datalen = fs;
			pvt->fr.samples = fs / 2;
			return &pvt->fr;
		}

		r = recv(pvt->sco_socket, buf, sizeof(buf), MSG_DONTWAIT);
		if (r < 0 && (errno == EAGAIN || errno == EINTR)) {
			return &ast_null_frame;
		}
		if (r <= 0) {
			ast_debug(1, "[%s] read error %d on audio connection, going to wait for new connection\n", pvt->id, r < 0 ? errno : 0);
			close(pvt->sco_socket);
			pvt->sco_socket = -1;
			ast_channel_set_fd(ast, 0, -1);
			return &ast_null_frame;
		}

		if (pvt->sco_codec == 2) {
			msbc_rx_feed(pvt, buf, r);
		} else {
			wb_rx_push(pvt, (const short *) buf, r / 2, 8000);
		}
	}
}

static void mbl_write_wb(struct mbl_pvt *pvt, struct ast_frame *frame)
{
	if (ast_format_cmp(frame->subclass.format, pvt->wide ? ast_format_slin16 : ast_format_slin) != AST_FORMAT_CMP_EQUAL) {
		return;
	}
	wb_tx(pvt, (const short *) frame->data.ptr, frame->datalen / 2);
}

WB_CHAN_EOF
cat > "$TMP/patch.py" <<'WB_PATCH_EOF'
#!/usr/bin/env python3
# Parche "widebandspeech" para addons/chan_mobile.c de Asterisk 22 (idempotente, anclas exactas).
import re, sys, os

path, helpers, chan = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
MARK = "widebandspeech (patch)"
if MARK in src:
    print("ya parcheado"); sys.exit(0)
H = open(helpers).read()
C = open(chan).read()

def once(old, new, what):
    global src
    n = src.count(old)
    if n != 1:
        sys.exit("ancla '%s' encontrada %d veces (esperaba 1): %s" % (what, n, old[:70].replace("\n", "\\n")))
    src = src.replace(old, new)

# 0. base: tramas de 20 ms
src = re.sub(r'(?m)^#define CHANNEL_FRAME_SIZE[ \t]+80$', '#define CHANNEL_FRAME_SIZE 320', src)

# 1. includes y defines
once('#include "asterisk/format_cache.h"\n',
     '#include "asterisk/format_cache.h"\n#include <dlfcn.h>\n#include <sbc/sbc.h>\n', 'include')
once('#define DEVICE_FRAME_FORMAT ast_format_slin\n',
     '''#define DEVICE_FRAME_FORMAT ast_format_slin

/* widebandspeech (patch) */
#ifndef SOL_BLUETOOTH
#define SOL_BLUETOOTH 274
#endif
#ifndef BT_DEFER_SETUP
#define BT_DEFER_SETUP 7
#endif
#ifndef BT_VOICE
#define BT_VOICE 11
struct bt_voice {
	uint16_t setting;
};
#define BT_VOICE_TRANSPARENT 0x0003
#endif
''', 'define format')
once('static int discovery_interval = 60;',
     'static int wideband_default = 0;			/* widebandspeech in [general] */\nstatic int discovery_interval = 60;', 'discovery_interval')

# 2. estructuras
once('	unsigned int alignment_detection:1;		/* do alignment detection on this adapter? */\n',
     '	unsigned int alignment_detection:1;		/* do alignment detection on this adapter? */\n'
     '	unsigned int defer_setup:1;			/* listener uses BT_DEFER_SETUP (wideband) */\n', 'adapter')
once('	char io_buf[CHANNEL_FRAME_SIZE + AST_FRIENDLY_OFFSET];\n',
     '''	char io_buf[1024 + AST_FRIENDLY_OFFSET];
	/* wideband */
	unsigned int wideband:1;			/* widebandspeech enabled and libsbc available */
	unsigned int wide:1;				/* current channel is slin16 */
	unsigned int req_wide:1;			/* the requester can take slin16 */
	int sco_codec;					/* codec of the audio connection: 1 CVSD, 2 mSBC */
	sbc_t *msbc_enc;
	sbc_t *msbc_dec;
	unsigned char msbc_rx[256];
	int msbc_rx_len;
	int msbc_rx_seq;
	unsigned char msbc_tx_seq;
	unsigned char wtx[2048];
	int wtx_len;
	unsigned char wrx[2048];
	int wrx_len;
	short rx_prev;
	short tx_prev;
	unsigned long wb_rx_pkts;
	unsigned long wb_rx_lost;
	unsigned long wb_rx_bad;
	unsigned long wb_tx_pkts;
''', 'io_buf')
once('#define HFP_AG_ERRORS	(1 << 8)\n',
     '#define HFP_AG_ERRORS	(1 << 8)\n#define HFP_HF_CODEC	(1 << 7)\n#define HFP_AG_CODEC	(1 << 9)\n', 'HFP_AG_ERRORS')
once('	int sent_alerting;		/*!< have we sent alerting? */\n',
     '	int sent_alerting;		/*!< have we sent alerting? */\n'
     '	int ag_codec_neg;		/*!< the AG supports codec negotiation */\n'
     '	int wb_ok;			/*!< AT+BAC accepted: the AG may select mSBC */\n'
     '	int codec_sel;			/*!< codec selected by the AG: 1 CVSD, 2 mSBC */\n', 'hfp_pvt')
once('	AT_ECAM,\n} at_message_t;', '	AT_ECAM,\n	AT_BCS,\n	AT_BAC,\n} at_message_t;', 'at enum')

# 3. AT parsing
once('	} else if (at_match_prefix(buf, "+BRSF:")) {\n		return AT_BRSF;\n',
     '	} else if (at_match_prefix(buf, "+BCS:")) {\n		return AT_BCS;\n'
     '	} else if (at_match_prefix(buf, "+BRSF:")) {\n		return AT_BRSF;\n', 'at_read_full')
once('	case AT_NO_CARRIER:\n		return "NO CARRIER";\n',
     '	case AT_NO_CARRIER:\n		return "NO CARRIER";\n	case AT_BCS:\n		return "AT+BCS";\n	case AT_BAC:\n		return "AT+BAC";\n', 'msg2str')
once('	snprintf(cmd, sizeof(cmd), "AT+BRSF=%d\\r", hfp_brsf2int(brsf));',
     '	snprintf(cmd, sizeof(cmd), "AT+BRSF=%d\\r", hfp_brsf2int(brsf) | ((hfp->owner && hfp->owner->wideband) ? HFP_HF_CODEC : 0));', 'send_brsf')
once('	hfp_int2brsf(brsf, &hfp->brsf);\n',
     '	hfp_int2brsf(brsf, &hfp->brsf);\n	hfp->ag_codec_neg = (brsf & HFP_AG_CODEC) ? 1 : 0;\n', 'parse_brsf')
once('static int hfp_send_cind(struct hfp_pvt *hfp)\n{\n	return rfcomm_write(hfp->rsock, "AT+CIND?\\r");\n}\n',
     'static int hfp_send_cind(struct hfp_pvt *hfp)\n{\n	return rfcomm_write(hfp->rsock, "AT+CIND?\\r");\n}\n\n'
     '''static int hfp_send_bac(struct hfp_pvt *hfp, int wide)
{
	return rfcomm_write(hfp->rsock, wide ? "AT+BAC=1,2\\r" : "AT+BAC=1\\r");
}

static int hfp_send_bcs(struct hfp_pvt *hfp, int codec)
{
	char cmd[32];
	snprintf(cmd, sizeof(cmd), "AT+BCS=%d\\r", codec);
	return rfcomm_write(hfp->rsock, cmd);
}
''', 'send_cind')

# 4. respuestas OK / ERROR / +BCS
once('/*!\n * \\brief Handle the BRSF response.',
     '''/*! Continue the service level initialization after BRSF (and BAC). */
static int hfp_after_brsf(struct mbl_pvt *pvt)
{
	if (pvt->blackberry) {
		if (hfp_send_cmer(pvt->hfp, 1) || msg_queue_push(pvt, AT_OK, AT_CMER)) {
			return -1;
		}
	} else {
		if (hfp_send_cind_test(pvt->hfp) || msg_queue_push(pvt, AT_CIND, AT_CIND_TEST)) {
			return -1;
		}
	}
	return 0;
}

/*! The AG selected a codec: +BCS: <id>. */
static int handle_response_bcs(struct mbl_pvt *pvt, char *buf)
{
	int codec = 0;

	if (sscanf(buf, "+BCS:%d", &codec) != 1) {
		ast_debug(1, "[%s] error parsing BCS: %s\\n", pvt->id, buf);
		return 0;
	}
	if (codec == 1 || (codec == 2 && pvt->wideband && pvt->hfp->wb_ok)) {
		if (hfp_send_bcs(pvt->hfp, codec) || msg_queue_push(pvt, AT_OK, AT_BCS)) {
			return -1;
		}
		pvt->hfp->codec_sel = codec;
		ast_debug(1, "[%s] codec selected by the AG: %s\\n", pvt->id, codec == 2 ? "mSBC (wideband)" : "CVSD");
	} else {
		ast_log(LOG_NOTICE, "[%s] the AG selected unsupported codec %d, asking for CVSD\\n", pvt->id, codec);
		if (hfp_send_bac(pvt->hfp, 0) || msg_queue_push(pvt, AT_OK, AT_BCS)) {
			return -1;
		}
	}
	return 0;
}

/*!
 * \\brief Handle the BRSF response.''', 'brsf doc')

m = re.search(r'\t\tcase AT_BRSF:\n\t\t\tast_debug\(1, "\[%s\] BSRF sent successfully\\n", pvt->id\);.*?\t\t\tbreak;\n(?=\t\tcase AT_CIND_TEST:\n\t\t\tast_debug\(1, "\[%s\] CIND test sent successfully)', src, re.S)
if not m:
    sys.exit("no encuentro el bloque AT_BRSF de handle_response_ok")
if src.count(m.group(0)) != 1:
    sys.exit("bloque AT_BRSF de handle_response_ok no unico")
src = src.replace(m.group(0), '''		case AT_BRSF:
			ast_debug(1, "[%s] BSRF sent successfully\\n", pvt->id);

			if (pvt->wideband && pvt->hfp->ag_codec_neg) {
				if (hfp_send_bac(pvt->hfp, 1) || msg_queue_push(pvt, AT_OK, AT_BAC)) {
					ast_debug(1, "[%s] error sending BAC\\n", pvt->id);
					goto e_return;
				}
				break;
			}
			if (hfp_after_brsf(pvt)) {
				ast_debug(1, "[%s] error continuing initialization after BRSF\\n", pvt->id);
				goto e_return;
			}
			break;
		case AT_BAC:
			ast_debug(1, "[%s] AT+BAC accepted, wideband (mSBC) available\\n", pvt->id);
			pvt->hfp->wb_ok = 1;
			if (hfp_after_brsf(pvt)) {
				ast_debug(1, "[%s] error continuing initialization after BAC\\n", pvt->id);
				goto e_return;
			}
			break;
		case AT_BCS:
			ast_debug(1, "[%s] codec confirmation accepted by the AG\\n", pvt->id);
			break;
''')
once('		case AT_BRSF:\n			ast_debug(1, "[%s] error reading BSRF\\n", pvt->id);\n			goto e_return;\n',
     '		case AT_BRSF:\n			ast_debug(1, "[%s] error reading BSRF\\n", pvt->id);\n			goto e_return;\n'
     '''		case AT_BAC:
			ast_debug(1, "[%s] AT+BAC rejected, staying narrowband (CVSD)\\n", pvt->id);
			pvt->hfp->wb_ok = 0;
			if (hfp_after_brsf(pvt)) {
				goto e_return;
			}
			break;
		case AT_BCS:
			ast_debug(1, "[%s] AT+BCS / AT+BAC answer was an error\\n", pvt->id);
			break;
''', 'error brsf')
once('	/* start initialization with the BRSF request */\n	ast_mutex_lock(&pvt->lock);\n	pvt->timeout = 10000;\n',
     '	/* start initialization with the BRSF request */\n	ast_mutex_lock(&pvt->lock);\n	pvt->timeout = 10000;\n'
     '	hfp->ag_codec_neg = 0;\n	hfp->wb_ok = 0;\n	hfp->codec_sel = 1;\n', 'monitor start')
once('		switch (at_msg) {\n		case AT_BRSF:\n			ast_mutex_lock(&pvt->lock);\n			if (handle_response_brsf(pvt, buf)) {',
     '''		switch (at_msg) {
		case AT_BCS:
			ast_mutex_lock(&pvt->lock);
			if (handle_response_bcs(pvt, buf)) {
				ast_mutex_unlock(&pvt->lock);
				goto e_cleanup;
			}
			ast_mutex_unlock(&pvt->lock);
			break;
		case AT_BRSF:
			ast_mutex_lock(&pvt->lock);
			if (handle_response_brsf(pvt, buf)) {''', 'monitor switch')

# 5. canal
once('static struct ast_channel *mbl_new(int state, struct mbl_pvt *pvt, struct cidinfo *cidinfo,\n		const struct ast_assigned_ids *assignedids, const struct ast_channel *requestor)\n{',
     H + '\nstatic struct ast_channel *mbl_new(int state, struct mbl_pvt *pvt, struct cidinfo *cidinfo,\n		const struct ast_assigned_ids *assignedids, const struct ast_channel *requestor)\n{', 'mbl_new def')
once('	struct ast_channel *chn;\n\n	pvt->answered = 0;\n',
     '	struct ast_channel *chn;\n	struct ast_format *chfmt;\n	struct ast_format_cap *nat;\n\n'
     '	pvt->wide = (pvt->wideband && pvt->hfp && pvt->hfp->wb_ok && pvt->req_wide) ? 1 : 0;\n'
     '	pvt->req_wide = 1;\n	pvt->wtx_len = 0;\n	pvt->wrx_len = 0;\n	pvt->rx_prev = 0;\n	pvt->tx_prev = 0;\n'
     '	pvt->answered = 0;\n', 'mbl_new vars')
once('''	ast_channel_nativeformats_set(chn, mbl_tech.capabilities);
	ast_channel_set_rawreadformat(chn, DEVICE_FRAME_FORMAT);
	ast_channel_set_rawwriteformat(chn, DEVICE_FRAME_FORMAT);
	ast_channel_set_writeformat(chn, DEVICE_FRAME_FORMAT);
	ast_channel_set_readformat(chn, DEVICE_FRAME_FORMAT);
''', '''	chfmt = pvt->wide ? ast_format_slin16 : DEVICE_FRAME_FORMAT;
	if ((nat = ast_format_cap_alloc(AST_FORMAT_CAP_FLAG_DEFAULT))) {
		ast_format_cap_append(nat, chfmt, 0);
		ast_channel_nativeformats_set(chn, nat);
		ao2_ref(nat, -1);
	} else {
		ast_channel_nativeformats_set(chn, mbl_tech.capabilities);
	}
	ast_channel_set_rawreadformat(chn, chfmt);
	ast_channel_set_rawwriteformat(chn, chfmt);
	ast_channel_set_writeformat(chn, chfmt);
	ast_channel_set_readformat(chn, chfmt);
''', 'mbl_new formats')
once('	if (ast_format_cap_iscompatible_format(cap, DEVICE_FRAME_FORMAT) == AST_FORMAT_CMP_NOT_EQUAL) {',
     '	if (ast_format_cap_iscompatible_format(cap, DEVICE_FRAME_FORMAT) == AST_FORMAT_CMP_NOT_EQUAL\n'
     '		&& ast_format_cap_iscompatible_format(cap, ast_format_slin16) == AST_FORMAT_CMP_NOT_EQUAL) {', 'request fmt')
once('	ast_mutex_lock(&pvt->lock);\n	chn = mbl_new(AST_STATE_DOWN, pvt, NULL, assignedids, requestor);',
     '	ast_mutex_lock(&pvt->lock);\n	pvt->req_wide = ast_format_cap_iscompatible_format(cap, ast_format_slin16) != AST_FORMAT_CMP_NOT_EQUAL;\n'
     '	chn = mbl_new(AST_STATE_DOWN, pvt, NULL, assignedids, requestor);', 'request wide')
once('	ast_channel_set_fd(ast, 0, -1);\n	close(pvt->sco_socket);\n	pvt->sco_socket = -1;\n\n	if (pvt->needchup) {',
     '''	ast_channel_set_fd(ast, 0, -1);
	close(pvt->sco_socket);
	pvt->sco_socket = -1;
	if (pvt->wb_rx_pkts || pvt->wb_tx_pkts) {
		ast_log(LOG_NOTICE, "[%s] wideband stats: mSBC rx=%lu lost=%lu bad=%lu tx=%lu\\n",
			pvt->id, pvt->wb_rx_pkts, pvt->wb_rx_lost, pvt->wb_rx_bad, pvt->wb_tx_pkts);
	}
	pvt->wb_rx_pkts = pvt->wb_rx_lost = pvt->wb_rx_bad = pvt->wb_tx_pkts = 0;
	pvt->sco_codec = 1;
	pvt->wtx_len = 0;
	pvt->wrx_len = 0;
	msbc_stop(pvt);

	if (pvt->needchup) {''', 'hangup')
once('static struct ast_frame *mbl_read(struct ast_channel *ast)\n{', C + 'static struct ast_frame *mbl_read(struct ast_channel *ast)\n{', 'mbl_read def')
once('	memset(&pvt->fr, 0x00, sizeof(struct ast_frame));\n	pvt->fr.frametype = AST_FRAME_VOICE;\n	pvt->fr.subclass.format = DEVICE_FRAME_FORMAT;',
     '	if (pvt->wide || pvt->sco_codec == 2) {\n		fr = mbl_read_wb(ast, pvt);\n		ast_mutex_unlock(&pvt->lock);\n		return fr;\n	}\n\n'
     '	memset(&pvt->fr, 0x00, sizeof(struct ast_frame));\n	pvt->fr.frametype = AST_FRAME_VOICE;\n	pvt->fr.subclass.format = DEVICE_FRAME_FORMAT;', 'mbl_read body')
once('	ast_smoother_feed(pvt->bt_out_smoother, frame);\n',
     '	if (pvt->wide || pvt->sco_codec == 2) {\n		mbl_write_wb(pvt, frame);\n		ast_mutex_unlock(&pvt->lock);\n		return 0;\n	}\n\n'
     '	ast_smoother_feed(pvt->bt_out_smoother, frame);\n', 'mbl_write')

# 6. SCO: listener diferido y seleccion de codec
once('	if (listen(adapter->sco_socket, 5) < 0) {',
     '''	if (adapter->defer_setup) {
		int defer = 1;
		if (setsockopt(adapter->sco_socket, SOL_BLUETOOTH, BT_DEFER_SETUP, &defer, sizeof(defer)) < 0) {
			ast_log(LOG_WARNING, "Unable to set BT_DEFER_SETUP on adapter %s (%d): no wideband\\n", adapter->id, errno);
			adapter->defer_setup = 0;
		}
	}
	if (listen(adapter->sco_socket, 5) < 0) {''', 'sco_bind')
once('	ast_mutex_lock(&pvt->lock);\n	if (pvt->sco_socket != -1) {\n		close(pvt->sco_socket);\n		pvt->sco_socket = -1;\n	}\n\n	pvt->sco_socket = sock;',
     '''	ast_mutex_lock(&pvt->lock);
	if (pvt->sco_socket != -1) {
		close(pvt->sco_socket);
		pvt->sco_socket = -1;
	}

	pvt->sco_codec = 1;
	pvt->wtx_len = 0;
	pvt->wrx_len = 0;
	pvt->rx_prev = 0;
	pvt->tx_prev = 0;
	if (adapter->defer_setup) {
		char kick;

		if (pvt->hfp && pvt->wideband && pvt->hfp->codec_sel == 2) {
			struct bt_voice voice;

			memset(&voice, 0, sizeof(voice));
			voice.setting = BT_VOICE_TRANSPARENT;
			if (setsockopt(sock, SOL_BLUETOOTH, BT_VOICE, &voice, sizeof(voice)) < 0) {
				ast_log(LOG_WARNING, "[%s] unable to select transparent voice for mSBC (errno %d), the audio will be wrong\\n", pvt->id, errno);
			} else if (msbc_start(pvt)) {
				ast_log(LOG_WARNING, "[%s] unable to start the mSBC codec, the audio will be wrong\\n", pvt->id);
			} else {
				pvt->sco_codec = 2;
			}
		}
		/* accept the deferred audio connection */
		if (recv(sock, &kick, 1, MSG_DONTWAIT) < 0 && errno != EAGAIN) {
			ast_debug(1, "[%s] audio connection accept kick failed (errno %d)\\n", pvt->id, errno);
		}
	}
	ast_log(LOG_NOTICE, "[%s] audio connection: %s, MTU %d\\n", pvt->id, pvt->sco_codec == 2 ? "mSBC (wideband)" : "CVSD", so.mtu);

	pvt->sco_socket = sock;''', 'sco_accept')

# 7. configuracion
once('static struct adapter_pvt *mbl_load_adapter(struct ast_config *cfg, const char *cat)\n{',
     '''/*! Is widebandspeech requested anywhere in the configuration (and is libsbc usable)? */
static int mbl_cfg_wideband_wanted(struct ast_config *cfg)
{
	const char *c;
	const char *v;
	int wanted = 0;

	for (c = ast_category_browse(cfg, NULL); c; c = ast_category_browse(cfg, c)) {
		v = ast_variable_retrieve(cfg, c, "widebandspeech");
		if (v && ast_true(v)) {
			wanted = 1;
		}
	}
	if (wanted && msbc_load()) {
		ast_log(LOG_WARNING, "widebandspeech requested but libsbc.so.1 is not available (apt install libsbc1): staying narrowband\\n");
		return 0;
	}
	return wanted;
}

static struct adapter_pvt *mbl_load_adapter(struct ast_config *cfg, const char *cat)
{''', 'load_adapter def')
once('	/* bind the sco listener socket */\n	if (sco_bind(adapter) < 0) {',
     '	adapter->defer_setup = mbl_cfg_wideband_wanted(cfg);\n\n	/* bind the sco listener socket */\n	if (sco_bind(adapter) < 0) {', 'load_adapter bind')
once('	pvt->has_sms = 1;\n\n	/* setup the bt_out_smoother */',
     '	pvt->has_sms = 1;\n	pvt->wideband = wideband_default && sbc_lib;\n	pvt->req_wide = 1;\n	pvt->sco_codec = 1;\n	pvt->msbc_rx_seq = -1;\n\n	/* setup the bt_out_smoother */', 'load_device defaults')
once('		} else if (!strcasecmp(v->name, "blackberry")) {\n			pvt->blackberry = ast_true(v->value);\n			pvt->has_sms = 0;\n		}\n	}\n',
     '''		} else if (!strcasecmp(v->name, "blackberry")) {
			pvt->blackberry = ast_true(v->value);
			pvt->has_sms = 0;
		} else if (!strcasecmp(v->name, "widebandspeech")) {
			pvt->wideband = ast_true(v->value) && sbc_lib;
		}
	}
''', 'load_device option')
once('		if (!strcasecmp(v->name, "interval")) {\n			if (!sscanf(v->value, "%d", &discovery_interval)) {\n				ast_log(LOG_NOTICE, "error parsing \'interval\' in general section, using default value\\n");\n			}\n		}\n',
     '''		if (!strcasecmp(v->name, "interval")) {
			if (!sscanf(v->value, "%d", &discovery_interval)) {
				ast_log(LOG_NOTICE, "error parsing 'interval' in general section, using default value\\n");
			}
		} else if (!strcasecmp(v->name, "widebandspeech")) {
			wideband_default = ast_true(v->value);
		}
''', 'general option')
once('	/* load adapters */\n',
     '	/* load adapters */\n	if (mbl_cfg_wideband_wanted(cfg)) {\n		ast_log(LOG_NOTICE, "widebandspeech enabled: HFP codec negotiation (mSBC, 16 kHz)\\n");\n	}\n', 'load adapters')
once('		msg_queue_flush(pvt);\n\n		if (pvt->hfp) {\n			ast_free(pvt->hfp);',
     '		msg_queue_flush(pvt);\n		msbc_stop(pvt);\n\n		if (pvt->hfp) {\n			ast_free(pvt->hfp);', 'unload pvt')
once('	if (sdp_session)\n		sdp_close(sdp_session);\n', '	if (sdp_session)\n		sdp_close(sdp_session);\n\n	msbc_unload();\n', 'unload end')
once('	ast_format_cap_append(mbl_tech.capabilities, DEVICE_FRAME_FORMAT, 0);\n',
     '	ast_format_cap_append(mbl_tech.capabilities, DEVICE_FRAME_FORMAT, 0);\n	ast_format_cap_append(mbl_tech.capabilities, ast_format_slin16, 0);\n', 'caps')


# 8. registro SDP Hands-Free 1.7 con Wideband Speech (el movil lo consulta antes de ofrecer mSBC)
once('static sdp_session_t *sdp_register(void)\n{',
     '''static void sdp_register_hf_record(sdp_session_t *session)
{
	uuid_t hf_uuid, ga_uuid, root_uuid, l2cap_uuid, rfcomm_uuid;
	sdp_list_t *class_list, *root_list, *l2cap_list, *rfcomm_list, *proto_list, *access_list, *pfseq;
	sdp_profile_desc_t profile;
	sdp_data_t *channel;
	uint8_t rfcomm_channel = 2;
	uint16_t features = 0x0024;	/* CLI presentation + wideband speech */
	sdp_record_t *record = sdp_record_alloc();

	sdp_uuid16_create(&hf_uuid, HANDSFREE_SVCLASS_ID);
	sdp_uuid16_create(&ga_uuid, GENERIC_AUDIO_SVCLASS_ID);
	class_list = sdp_list_append(0, &hf_uuid);
	class_list = sdp_list_append(class_list, &ga_uuid);
	sdp_set_service_classes(record, class_list);

	memset(&profile, 0, sizeof(profile));
	sdp_uuid16_create(&profile.uuid, HANDSFREE_PROFILE_ID);
	profile.version = 0x0107;
	pfseq = sdp_list_append(0, &profile);
	sdp_set_profile_descs(record, pfseq);

	sdp_uuid16_create(&root_uuid, PUBLIC_BROWSE_GROUP);
	root_list = sdp_list_append(0, &root_uuid);
	sdp_set_browse_groups(record, root_list);

	sdp_uuid16_create(&l2cap_uuid, L2CAP_UUID);
	l2cap_list = sdp_list_append(0, &l2cap_uuid);
	proto_list = sdp_list_append(0, l2cap_list);
	sdp_uuid16_create(&rfcomm_uuid, RFCOMM_UUID);
	channel = sdp_data_alloc(SDP_UINT8, &rfcomm_channel);
	rfcomm_list = sdp_list_append(0, &rfcomm_uuid);
	sdp_list_append(rfcomm_list, channel);
	sdp_list_append(proto_list, rfcomm_list);
	access_list = sdp_list_append(0, proto_list);
	sdp_set_access_protos(record, access_list);

	sdp_set_info_attr(record, "Asterisk Hands-Free", "Asterisk", "Asterisk Hands-Free");
	sdp_attr_add_new(record, SDP_ATTR_SUPPORTED_FEATURES, SDP_UINT16, &features);

	if (sdp_record_register(session, record, 0) < 0) {
		ast_log(LOG_WARNING, "Failed to register the Hands-Free SDP record (%d)\\n", errno);
	}

	sdp_data_free(channel);
	sdp_list_free(rfcomm_list, 0);
	sdp_list_free(root_list, 0);
	sdp_list_free(access_list, 0);
	sdp_list_free(class_list, 0);
	sdp_list_free(pfseq, 0);
}

static sdp_session_t *sdp_register(void)
{''', 'sdp def')
once('	sdp_data_free(channel);\n	sdp_list_free(rfcomm_list, 0);\n	sdp_list_free(root_list, 0);\n	sdp_list_free(access_proto_list, 0);\n	sdp_list_free(svc_uuid_list, 0);\n\n	return session;',
     '	if (session && sbc_lib) {\n		sdp_register_hf_record(session);\n	}\n\n	sdp_data_free(channel);\n	sdp_list_free(rfcomm_list, 0);\n	sdp_list_free(root_list, 0);\n	sdp_list_free(access_proto_list, 0);\n	sdp_list_free(svc_uuid_list, 0);\n\n	return session;', 'sdp end')

src = src.replace('/* widebandspeech (patch) */', '/* ' + MARK + ' */', 1)
open(path, 'w').write(src)
print("parche aplicado")
WB_PATCH_EOF
cp -a "$C" "$TMP/chan_mobile.c.try"
python3 -I "$TMP/patch.py" "$TMP/chan_mobile.c.try" "$TMP/wb_helpers.c" "$TMP/wb_chan.c" || fallo "el parche no encaja con este chan_mobile.c (no se toco nada)"
cp -a "$TMP/chan_mobile.c.try" "$C"
grep -q 'widebandspeech (patch)' "$C" || fallo "el parche no quedo aplicado"

echo "== 4. compilar solo chan_mobile con los mismos flags de la compilacion original (-j1)"
cd "$SRC" || fallo "No entro en $SRC"
FL=$(cat .zero_flags 2>/dev/null || true)
OPTF=${FL%% | *}; LDF=${FL##* | }
[ -n "$FL" ] || { OPTF="-O2 -pipe"; LDF=""; }
touch addons/chan_mobile.c
OPTIMIZE=-O2 ASTCFLAGS="$OPTF" ASTLDFLAGS="$LDF" nice -n 10 make -j1 addons >/root/chan_mobile_rebuild.log 2>&1 \
  || { tail -20 /root/chan_mobile_rebuild.log; fallo "fallo la compilacion (log: /root/chan_mobile_rebuild.log). Nada instalado; para volver: sudo bash $0 restore"; }
[ addons/chan_mobile.so -nt "$BK/chan_mobile.so.orig" ] || fallo "No se regenero addons/chan_mobile.so"

echo "== 5. instalar y reiniciar"
install -m 755 addons/chan_mobile.so "$MODDIR/chan_mobile.so" || fallo "No pude instalar el modulo"
echo "[ok] instalado. Restaurar: sudo bash $0 restore"
reiniciar
echo
echo "Para ver la negociacion: asterisk -rx 'core set verbose 3' ; en el log busca '[micelular] audio connection: mSBC (wideband)'"
