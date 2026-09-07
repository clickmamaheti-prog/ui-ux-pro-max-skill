#!/usr/bin/env bash
# design-lab auto-runner (v3: STREAMING — hindari timeout 524 Cloudflare)
# Alur: baca skill ui-ux-pro-max + brief -> panggil gateway vector (free tier,
# TANPA kunci user, stream:true) -> akumulasi delta -> simpan -> push branch.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p output
echo "{\"status\": \"running\", \"started\": \"$(date -u +%FT%TZ)\"}" > output/status.json

command -v python3 >/dev/null 2>&1 || { sudo apt-get update -qq; sudo apt-get install -y -qq python3 >/dev/null; }

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
    "max_tokens": 12000,
    "temperature": 0.7
}
with open('/tmp/req_base.json', 'w', encoding='utf-8') as f:
    f.write(json.dumps(payload, ensure_ascii=False))
print('skill chars:', len(skill), '| task chars:', len(task))
PY

# 2) Streaming call per model + fallback + retry
python3 - <<'PY'
import json, time, urllib.request

GW = "https://vector-tui.methatech.eu.org/v1/chat/completions"
MODELS = ["mimo-v2.5", "glm-5.3-flash", "hy3"]
base = json.load(open('/tmp/req_base.json', encoding='utf-8'))

def gen(model):
    payload = dict(base, model=model)
    data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(GW, data=data, headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer vectorhead-free-anonymous",
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

result, used, err = None, None, None
for model in MODELS:
    for attempt in (1, 2):
        t0 = time.time()
        try:
            text = gen(model)
            if text and len(text.strip()) > 500:
                result, used = text, model
                print('SUKSES model=%s attempt=%d chars=%d waktu=%.0fs' % (
                    model, attempt, len(text), time.time() - t0))
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
    with open('output/index.html', 'w', encoding='utf-8') as f:
        f.write(t)
    status.update(status='ok', model=used, bytes=len(t))
else:
    status.update(status='failed', error=(err or 'tidak ada hasil')[:600])
with open('output/status.json', 'w', encoding='utf-8') as f:
    json.dump(status, f, indent=2)
print('STATUS:', json.dumps(status))
PY

# 3) Push hasil ke branch design-output (persist walau Codespace dihapus)
git config user.email "design-lab@users.noreply.github.com"
git config user.name "design-lab"
git checkout -B design-output 2>/dev/null || git checkout design-output
git add output
git commit -m "design-lab: hasil desain otomatis" || echo "nothing to commit"
git push --force origin design-output || \
  git push --force "https://x-access-token:${GITHUB_TOKEN}@github.com/clickmamaheti-prog/ui-ux-pro-max-skill.git" design-output
echo "DESIGN-LAB DONE"
