#!/usr/bin/env bash
# design-lab auto-runner
# Alur: baca skill ui-ux-pro-max + brief -> panggil gateway vector (free tier,
# TANPA kunci user) -> simpan hasil -> push ke branch design-output.
# Codespace kemudian DIHAPUS dari luar; hasil tetap tersimpan di branch.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p output
now() { date -u +%FT%TZ; }
echo "{\"status\": \"running\", \"started\": \"$(now)\"}" > output/status.json

# 1) Instruksi skill: repo ini ADALAH skill-nya (sub-skill dipilih eksplisit)
command -v python3 >/dev/null 2>&1 || { sudo apt-get update -qq; sudo apt-get install -y -qq python3 >/dev/null; }

# 2) Susun permintaan: skill sebagai sistem, brief sebagai tugas
python3 - <<'PY'
import glob

def read(p, limit):
    try:
        return open(p, encoding='utf-8', errors='replace').read()[:limit]
    except Exception:
        return ''

candidates = ['.claude/skills/design/SKILL.md',
              '.claude/skills/design-system/SKILL.md',
              '.claude/skills/brand/SKILL.md']
texts = ['=== %s ===\n%s' % (c, read(c, 9000)) for c in candidates if __import__('os').path.isfile(c)]
if not texts:
    found = sorted(glob.glob('**/SKILL.md', recursive=True))
    if found:
        texts = [read(found[0], 14000)]
    else:
        texts = [read('CLAUDE.md', 14000)]
skill = '\n\n'.join(texts)[:14000]
task = read('TASK.md', 5000)
print('skill chars:', len(skill), '| task chars:', len(task))
payload = {
    "model": "glm-5.3-flash",
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
with open('/tmp/req.json', 'w', encoding='utf-8') as f:
    f.write(json.dumps(payload, ensure_ascii=False))
print("request ready: skill=%s (%d chars), task=%d chars" % (
    os.environ.get('SKILL_FILE', 'CLAUDE.md'), len(skill), len(task)))
PY

# 3) Panggil gateway vector (free tier — kunci provider ada di gateway, bukan di sini)
HTTP=$(curl -s --max-time 280 -o /tmp/resp.json -w "%{http_code}" \
  -X POST "https://vector-tui.methatech.eu.org/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer vectorhead-free-anonymous" \
  --data-binary @/tmp/req.json)
echo "gateway HTTP $HTTP"

# 4) Simpan hasil + status
python3 - "$HTTP" <<'PY'
import json, sys, datetime
http = sys.argv[1]
status = {"http": http, "finished": datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}
try:
    with open('/tmp/resp.json', encoding='utf-8', errors='replace') as f:
        d = json.load(f)
    if http == '200':
        txt = (d.get('choices') or [{}])[0].get('message', {}).get('content') or ''
        t = txt.strip()
        if t.startswith('```'):
            t = t.strip('`')
            if t[:4].lower() == 'html':
                t = t[4:]
        with open('output/index.html', 'w', encoding='utf-8') as f:
            f.write(t)
        status.update(status='ok' if len(t) > 500 else 'too_short', bytes=len(txt))
    else:
        status.update(status='failed', error=str(d)[:600])
except Exception as e:
    raw = ''
    try:
        raw = open('/tmp/resp.json', errors='replace').read()[:300]
    except Exception:
        pass
    status.update(status='failed', error='%s: %s :: %s' % (type(e).__name__, e, raw))
with open('output/status.json', 'w', encoding='utf-8') as f:
    json.dump(status, f, indent=2)
print('status:', json.dumps(status))
PY

# 5) Push hasil ke branch design-output (persist walau Codespace dihapus)
git config user.email "design-lab@users.noreply.github.com"
git config user.name "design-lab"
git checkout -B design-output 2>/dev/null || git checkout design-output
git add output
git commit -m "design-lab: hasil desain otomatis" || echo "nothing to commit"
git push origin design-output || \
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/clickmamaheti-prog/ui-ux-pro-max-skill.git" design-output
echo "DESIGN-LAB DONE"
