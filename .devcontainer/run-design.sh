#!/usr/bin/env bash
# design-lab auto-runner (v4: BRANCH PER-JOB + CEK KELENGKAPAN)
# Alur: baca skill ui-ux-pro-max + brief -> panggil gateway vector (free tier,
# TANPA kunci user, stream:true) -> akumulasi delta -> cek </html> (lanjutkan
# bila terpotong) -> simpan -> push ke branch design-output-<job-id>.
#
# v4 (2026-09-08):
# - Job id dibaca dari TASK.md baris "# Brief Desain (job <id>)" -> hasil di-push
#   ke branch design-output-<id> (bukan lagi branch tetap design-output) agar
#   gateway /v1/design/status/:job menemukan hasil per-job sejak awal.
#   Branch tetap design-output TETAP di-push (kompatibilitas fallback gateway).
# - Kelengkapan: bila HTML tidak berakhir </html> (max_tokens habis), satu
#   percobaan lanjutan ("lanjutkan persis dari karakter terakhir") ditambahkan
#   sebelum menulis file. Status json mencatat complete:true/false.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p output
echo "{\"status\": \"running\", \"started\": \"$(date -u +%FT%TZ)\"}" > output/status.json

command -v python3 >/dev/null 2>&1 || { sudo apt-get update -qq; sudo apt-get install -y -qq python3 >/dev/null; }

# 0) Job id dari TASK.md (fallback: kosong -> mode legacy branch tetap)
JOB_ID=$(python3 - <<'PY'
import re
try:
    t = open('TASK.md', encoding='utf-8', errors='replace').read(300)
except Exception:
    t = ''
m = re.search(r'job\s+([a-z0-9-]{4,64})', t)
print(m.group(1) if m else '')
PY
)
OUT_BRANCH="design-output"
[ -n "$JOB_ID" ] && OUT_BRANCH="design-output-${JOB_ID}"
echo "job id: '${JOB_ID:-}' -> branch output: $OUT_BRANCH"

# 1) Payload dasar: skill sebagai sistem, brief sebagai tugas
python3 - <<'PY'
import glob, json, os

def read(p, limit):
    try:
        return open(p, encoding='utf-8', errors='replace').read()[:limit]
    except Exception:
        return ''

candidates = ['.claude/skills/design/SKILL.md',
              '.claude/skills/design-system/SKILL.md',
              '.claude/skills/brand/SKILL.md']
texts = ['=== %s ===\n%s' % (c, read(c, 9000)) for c in candidates if os.path.isfile(c)]
if not texts:
    found = sorted(glob.glob('**/SKILL.md', recursive=True))
    if found:
        texts = [read(found[0], 14000)]
    else:
        texts = [read('CLAUDE.md', 14000)]
skill = '\n\n'.join(texts)[:14000]
task = read('TASK.md', 5000)
payload = {
    "stream": True,
    "messages": [
        {"role": "system", "content":
            "Kamu desainer UI/UX profesional. Patuhi PANDUAN SKILL berikut secara ketat. "
            "Keluarkan HANYA satu file HTML lengkap, tanpa penjelasan apa pun.\n\n"
            "=== PANDUAN SKILL ===\n" + skill},
        {"role": "user", "content":
            task + "\n\nKeluarkan SATU file index.html lengkap (CSS/JS inline, responsif, "
                   "teks bahasa Indonesia). Hanya kode, tanpa penjelasan."}
    ],
    "max_tokens": 16000,
    "temperature": 0.7
}
with open('/tmp/req_base.json', 'w', encoding='utf-8') as f:
    f.write(json.dumps(payload, ensure_ascii=False))
print('skill chars:', len(skill), '| task chars:', len(task))
PY

# 2) Streaming call per model + fallback + retry + cek kelengkapan
python3 - <<'PY'
import json, time, urllib.request

GW = "https://vector-tui.methatech.eu.org/v1/chat/completions"
MODELS = ["mimo-v2.5", "glm-5.3-flash", "hy3"]
base = json.load(open('/tmp/req_base.json', encoding='utf-8'))

def gen(model, extra_user=None):
    payload = dict(base, model=model)
    if extra_user:
        payload["messages"] = payload["messages"] + [{"role": "user", "content": extra_user}]
    data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(GW, data=data, headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer vectorhead-free-anonymous",
        "User-Agent": "curl/8.5.0",
    }, method='POST')
    parts, raw_buf = [], []
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            line = raw.decode('utf-8', 'replace').strip()
            if not line:
                continue
            raw_buf.append(line)
            if not line.startswith('data:'):
                continue
            body = line[5:].strip()
            if body == '[DONE]':
                break
            try:
                j = json.loads(body)
            except Exception:
                continue
            ch = (j.get('choices') or [{}])
            delta = (ch[0].get('delta') or {}) if ch else {}
            piece = delta.get('content') or (ch[0].get('message') or {}).get('content') or ''
            if piece:
                parts.append(piece)
    text = ''.join(parts)
    if not text and raw_buf:
        # fallback: mungkin body JSON tunggal (bukan SSE)
        try:
            j = json.loads('\n'.join(l for l in raw_buf if not l.startswith('data:')))
            text = ((j.get('choices') or [{}])[0].get('message') or {}).get('content') or ''
        except Exception:
            pass
    return text

def is_complete(t):
    # lengkap = ada </html> dan tidak berakhir di tengah tag pembuka
    s = t.rstrip()
    return s.lower().endswith('</html>') and not s.rstrip().endswith(('<', '</'))

result, used, err, continued = None, None, None, False
for model in MODELS:
    for attempt in (1, 2):
        t0 = time.time()
        try:
            text = gen(model)
            if text and len(text.strip()) > 500:
                # v4: cek kelengkapan — bila terpotong, minta lanjutan SEKALI
                if not is_complete(text):
                    tail = text[-400:]
                    print('TERPOTONG (tanpa </html>) — minta lanjutan model=%s' % model)
                    try:
                        cont = gen(model, extra_user=(
                            "LANJUTKAN persis dari karakter terakhir output sebelumnya. "
                            "JANGAN ulangi bagian mana pun. 400 karakter terakhir output "
                            "sebelumnya:\n...\n" + tail + "\n\n"
                            "Lanjutkan HANYA sisanya hingga </html>. Tanpa penjelasan."
                        ))
                        if cont and len(cont.strip()) > 100:
                            # buang pembungkus markdown bila model menambahkan
                            c = cont.strip()
                            if c.startswith('```'):
                                c = c.strip('`')
                                if c[:4].lower() == 'html':
                                    c = c[4:]
                            text = text + c
                            continued = True
                            print('lanjutan diterima: +%d chars' % len(c))
                    except Exception as ce:
                        print('lanjutan gagal: %s' % str(ce)[:200])
                result, used = text, model
                print('SUKSES model=%s attempt=%d chars=%d complete=%s waktu=%.0fs' % (
                    model, attempt, len(text), is_complete(text), time.time() - t0))
                break
            err = 'konten kosong/pendek (%s)' % len(text or '')
            print('model=%s attempt=%d gagal: %s (%.0fs)' % (model, attempt, err, time.time() - t0))
        except Exception as e:
            err = '%s: %s' % (type(e).__name__, str(e)[:300])
            print('model=%s attempt=%d error: %s (%.0fs)' % (model, attempt, err, time.time() - t0))
        time.sleep(8)
    if result:
        break

status = {"finished": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
if result:
    t = result.strip()
    if t.startswith('```'):
        t = t.strip('`')
        if t[:4].lower() == 'html':
            t = t[4:]
    complete = t.lower().rstrip().endswith('</html>')
    with open('output/index.html', 'w', encoding='utf-8') as f:
        f.write(t)
    status.update(status='ok', model=used, bytes=len(t), complete=complete)
    if continued:
        status['continued'] = True
    if not complete:
        status['warning'] = 'HTML tidak berakhir </html> walau setelah percobaan lanjutan'
else:
    status.update(status='failed', error=(err or 'tidak ada hasil')[:600])
with open('output/status.json', 'w', encoding='utf-8') as f:
    json.dump(status, f, indent=2)
print('STATUS:', json.dumps(status))
PY

# 3) Push hasil ke branch output (persist walau Codespace dihapus)
#    v4: branch per-job design-output-<id> (dibaca gateway) + branch tetap
#    design-output (kompatibilitas fallback gateway lama).
git config user.email "design-lab@users.noreply.github.com"
git config user.name "design-lab"

push_branch() {
  local BR="$1"
  git checkout -B "$BR" 2>/dev/null || git checkout "$BR"
  git add output
  git commit -m "design-lab: hasil desain job ${JOB_ID:-anonim}" || echo "nothing to commit"
  git push --force origin "$BR" || \
    git push --force "https://x-access-token:${GITHUB_TOKEN}@github.com/clickmamaheti-prog/ui-ux-pro-max-skill.git" "$BR"
}

push_branch "$OUT_BRANCH"
if [ -n "$JOB_ID" ] && [ "$OUT_BRANCH" != "design-output" ]; then
  push_branch "design-output"
fi
echo "DESIGN-LAB DONE (branch: $OUT_BRANCH)"
