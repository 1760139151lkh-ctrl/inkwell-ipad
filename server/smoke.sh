#!/usr/bin/env bash
# End-to-end smoke test for the Inkwell backup API.
#   server/smoke.sh                       # against NEON_FUNCTION_API_BASE_URL from .env
#   server/smoke.sh http://localhost:8788 # against `neon dev`
# Reads INKWELL_API_TOKEN from .env.local (never printed). Needs curl, jq, node, uuidgen, shasum.
# Creates a throwaway note, exercises every route, then HARD-deletes it (rows + objects).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-$(grep '^NEON_FUNCTION_API_BASE_URL=' .env | cut -d= -f2-)}"
BASE="${BASE%/}"
TOKEN="$(grep '^INKWELL_API_TOKEN=' .env.local | cut -d= -f2-)"
[ -n "$TOKEN" ] || { echo "INKWELL_API_TOKEN missing from .env.local" >&2; exit 1; }

TMP="$(mktemp -d)"
NOTE_ID="$(uuidgen | tr 'A-Z' 'a-z')"
SUBJ_ID="$(uuidgen | tr 'A-Z' 'a-z')"
REC_ID="$(uuidgen | tr 'A-Z' 'a-z')"
EL_ID="$(uuidgen | tr 'A-Z' 'a-z')"
PASS=0; FAIL=0

cleanup() {
  node server/scripts/purge-note.mjs "$NOTE_ID" --subject "$SUBJ_ID" 2>/dev/null | sed 's/^/cleanup: /' || echo "cleanup FAILED for $NOTE_ID"
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); echo "PASS  $*"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
# api METHOD PATH [BODY_FILE] -> writes body to $TMP/out, echoes status
api() {
  local args=(-sS -o "$TMP/out" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN")
  [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' --data-binary "@$3")
  curl "${args[@]}" "$BASE$2"
}
expect() { # expect STATUS ACTUAL LABEL
  if [ "$1" = "$2" ]; then ok "$3 ($2)"; else fail "$3 (want $1, got $2): $(head -c 300 "$TMP/out")"; fi
}

echo "base: $BASE"
echo "note: $NOTE_ID"

# 1. health + auth
s=$(api GET /api/health); expect 200 "$s" "GET /api/health"; echo "      $(cat "$TMP/out")"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' "$BASE/api/health"); expect 401 "$s" "no token -> 401"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' -H "Authorization: Bearer nope" "$BASE/api/health"); expect 401 "$s" "wrong token -> 401"
echo "      $(cat "$TMP/out")"

# 2. PUT note
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$TMP/note.json" <<EOF
{
  "subject": {"id":"$SUBJ_ID","name":"Smoke Test","color_hex":"#4A90E2","sort_index":0,"divider_id":null,"updated_at":"$NOW","deleted_at":null},
  "note": {"id":"$NOTE_ID","subject_id":"$SUBJ_ID","title":"Smoke note",
           "paper":{"style":"ruled","color":"white","spacing":"medium","landscape":false},
           "page_count":2,"bookmarked_pages":[1],"created_at":"$NOW","modified_at":"$NOW","deleted_at":null,
           "drawing_key":"notes/$NOTE_ID/drawing.pkdrawing","drawing_sha256":null,"thumb_key":null},
  "recordings": [{"id":"$REC_ID","ord":0,"name":"Recording 1","started_at":"$NOW","duration_s":12.5,
                  "audio_key":"notes/$NOTE_ID/audio/$REC_ID.m4a","audio_sha256":null,"transcript_status":"complete","deleted_at":null}],
  "transcripts": [{"recording_id":"$REC_ID","locale":"en-US","engine":"SpeechAnalyzer",
                   "segments":[{"start":0.0,"end":1.2,"text":"hello smoke","words":[{"w":"hello","s":0.0,"e":0.5},{"w":"smoke","s":0.6,"e":1.2}]}],
                   "full_text":"hello smoke test transcript"}],
  "strokes_index": {"strokes":[{"i":0,"created_at":"$NOW","t_note":1.5,"page":0,"bbox":[10,20,30,40]}]},
  "elements": [{"id":"$EL_ID","kind":"text","frame":{"x":1,"y":2,"w":3,"h":4},"created_at":"$NOW","text":"hi","file_key":null,"deleted_at":null}]
}
EOF
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/note.json"); expect 200 "$s" "PUT /api/notes/:id"; echo "      $(cat "$TMP/out")"

# 3. GET it back
s=$(api GET "/api/notes/$NOTE_ID"); expect 200 "$s" "GET /api/notes/:id"
if jq -e --arg t "Smoke note" '.note.title==$t and (.recordings|length)==1 and (.transcripts|length)==1 and (.strokes_index.strokes|length)==1 and (.elements|length)==1 and .subject.name=="Smoke Test"' "$TMP/out" >/dev/null; then
  ok "GET body round-trips (title, recording, transcript, strokes_index, element, subject)"
else fail "GET body mismatch: $(head -c 400 "$TMP/out")"; fi

# 4. presigned upload -> PUT bytes -> presigned download -> sha256 compare
head -c 4096 /dev/urandom > "$TMP/drawing.pkdrawing"
SHA="$(shasum -a 256 "$TMP/drawing.pkdrawing" | cut -d' ' -f1)"
jq -n --arg n "$NOTE_ID" --arg s "$SHA" '{noteId:$n, files:[{path:"drawing.pkdrawing", sha256:$s, contentType:"application/octet-stream"}]}' > "$TMP/up.json"
s=$(api POST /api/uploads "$TMP/up.json"); expect 200 "$s" "POST /api/uploads"
UP_URL="$(jq -r '.uploads[0].url' "$TMP/out")"; KEY="$(jq -r '.uploads[0].key' "$TMP/out")"
HDRS=(); while IFS= read -r h; do HDRS+=(-H "$h"); done < <(jq -r '.uploads[0].headers|to_entries[]|"\(.key): \(.value)"' "$TMP/out")
echo "      key=$KEY expires_at=$(jq -r '.uploads[0].expires_at' "$TMP/out") headers=$(jq -c '.uploads[0].headers|keys' "$TMP/out")"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' -X PUT "${HDRS[@]}" --data-binary "@$TMP/drawing.pkdrawing" "$UP_URL"); expect 200 "$s" "PUT bytes to presigned URL"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' -X PUT -H "Content-Type: application/octet-stream" --data-binary "@$TMP/drawing.pkdrawing" "$UP_URL"); expect 403 "$s" "presigned PUT without x-amz-meta-sha256 -> 403"
jq -n --arg k "$KEY" '{keys:[$k]}' > "$TMP/down.json"
s=$(api POST /api/downloads "$TMP/down.json"); expect 200 "$s" "POST /api/downloads"
DL_URL="$(jq -r '.downloads[0].url' "$TMP/out")"
s=$(curl -sS -o "$TMP/got" -w '%{http_code}' "$DL_URL"); expect 200 "$s" "GET bytes from presigned URL"
GOT="$(shasum -a 256 "$TMP/got" | cut -d' ' -f1)"
if [ "$GOT" = "$SHA" ]; then ok "sha256 matches ($SHA)"; else fail "sha256 mismatch: sent $SHA got $GOT"; fi

# 5. validation
jq -n --arg n "$NOTE_ID" '{noteId:$n, files:[{path:"../etc/passwd", sha256:("a"*64), contentType:"text/plain"}]}' > "$TMP/bad.json"
s=$(api POST /api/uploads "$TMP/bad.json"); expect 400 "$s" "upload path traversal -> 400"
echo '{"keys":["other/secret.txt"]}' > "$TMP/bad2.json"
s=$(api POST /api/downloads "$TMP/bad2.json"); expect 400 "$s" "download outside notes/ -> 400"
s=$(api GET /api/notes/not-a-uuid); expect 400 "$s" "GET bad id -> 400"
s=$(api GET "/api/notes/$(uuidgen | tr 'A-Z' 'a-z')"); expect 404 "$s" "GET unknown note -> 404"

# 5b. speaker names on the note: set, preserved when omitted, validated
jq '.note.speaker_names={"S1":"Kunal","'"$REC_ID"':S2":"Pat"}' "$TMP/note.json" > "$TMP/names.json"
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/names.json"); expect 200 "$s" "PUT note with speaker_names"
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/note.json"); expect 200 "$s" "PUT note without speaker_names"
s=$(api GET "/api/notes/$NOTE_ID")
if jq -e --arg k "$REC_ID:S2" '.note.speaker_names.S1=="Kunal" and .note.speaker_names[$k]=="Pat"' "$TMP/out" >/dev/null; then
  ok "speaker_names stored and kept when a later PUT omits them"; else fail "speaker_names: $(jq -c .note.speaker_names "$TMP/out")"; fi
jq '.note.speaker_names={"Bob":"x"}' "$TMP/note.json" > "$TMP/names_bad.json"
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/names_bad.json"); expect 400 "$s" "speaker_names bad key -> 400"

# 5c. diarization: cheap contract checks (no provider call)
s=$(api GET "/api/recordings/$REC_ID/diarization"); expect 200 "$s" "GET diarization before any request"
jq -e '.status=="none"' "$TMP/out" >/dev/null && ok "status none" || fail "want status none: $(cat "$TMP/out")"
s=$(api POST "/api/recordings/$REC_ID/diarize"); expect 409 "$s" "POST diarize before the audio object exists -> 409"
echo "      $(cat "$TMP/out")"
s=$(api POST "/api/recordings/$(uuidgen | tr 'A-Z' 'a-z')/diarize"); expect 404 "$s" "POST diarize unknown recording -> 404"

# 5d. diarization end to end (real provider call, ~$0.005): SMOKE_DIARIZE=1 npm run smoke
# Builds an 83 s, 3-voice meeting from review/demo-assets (macOS `say` clips + 0.6 s gaps), uploads it as this
# recording's audio, diarizes, and checks speakers + timing against the known clip boundaries.
if [ "${SMOKE_DIARIZE:-0}" = "1" ]; then
  A=review/demo-assets; GAP=0.6; t=0; : > "$TMP/list.txt"; : > "$TMP/bounds.tsv"
  ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=48000:cl=mono -t $GAP -c:a pcm_s16le "$TMP/gap.wav"
  N=$(jq '.recordings[0].lines|length' $A/script.json)
  for i in $(seq 0 $((N-1))); do
    f=$(jq -r ".recordings[0].lines[$i].file" $A/script.json); v=$(jq -r ".recordings[0].lines[$i].voice" $A/script.json)
    ffmpeg -loglevel error -y -i "$A/$f" -ar 48000 -ac 1 -c:a pcm_s16le "$TMP/c$i.wav"
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/c$i.wav")
    printf '%s\t%s\t%s\n' "$t" "$(echo "$t+$d" | bc)" "$v" >> "$TMP/bounds.tsv"
    printf "file '%s'\nfile '%s'\n" "$TMP/c$i.wav" "$TMP/gap.wav" >> "$TMP/list.txt"
    t=$(echo "$t+$d+$GAP" | bc)
  done
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$TMP/list.txt" -ar 48000 -ac 1 -c:a aac -b:a 64k "$TMP/meeting.m4a"
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/meeting.m4a")
  ASHA="$(shasum -a 256 "$TMP/meeting.m4a" | cut -d' ' -f1)"
  jq -n --arg n "$NOTE_ID" --arg p "audio/$REC_ID.m4a" --arg s "$ASHA" '{noteId:$n, files:[{path:$p, sha256:$s, contentType:"audio/mp4"}]}' > "$TMP/upa.json"
  s=$(api POST /api/uploads "$TMP/upa.json"); expect 200 "$s" "POST /api/uploads (audio)"
  UP_URL="$(jq -r '.uploads[0].url' "$TMP/out")"
  HDRS=(); while IFS= read -r h; do HDRS+=(-H "$h"); done < <(jq -r '.uploads[0].headers|to_entries[]|"\(.key): \(.value)"' "$TMP/out")
  s=$(curl -sS -o "$TMP/out" -w '%{http_code}' -X PUT "${HDRS[@]}" --data-binary "@$TMP/meeting.m4a" "$UP_URL"); expect 200 "$s" "PUT audio bytes ($(wc -c < "$TMP/meeting.m4a" | tr -d ' ') B, ${DUR}s)"
  jq --arg s "$ASHA" --argjson d "$DUR" '.recordings[0].audio_sha256=$s | .recordings[0].duration_s=$d' "$TMP/note.json" > "$TMP/note_a.json"
  s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/note_a.json"); expect 200 "$s" "PUT note with audio_sha256"

  T0=$(date +%s)
  s=$(api POST "/api/recordings/$REC_ID/diarize"); expect 202 "$s" "POST diarize -> 202"; echo "      $(jq -c . "$TMP/out")"
  s=$(api POST "/api/recordings/$REC_ID/diarize"); expect 202 "$s" "POST diarize again while running -> 202 (idempotent)"
  ST=""; for _ in $(seq 1 100); do
    sleep 3; s=$(api GET "/api/recordings/$REC_ID/diarization"); ST=$(jq -r .status "$TMP/out")
    [ "$ST" = done ] || [ "$ST" = failed ] && break
  done
  echo "      finished in $(( $(date +%s) - T0 ))s wall (incl. 3 s poll interval): status=$ST $(jq -c '{error,attempts,audio_duration_s}' "$TMP/out")"
  [ "$ST" = done ] && ok "diarization done" || fail "diarization status $ST"
  cp "$TMP/out" "$TMP/diar.json"
  if node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).transcript;
    const clips = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").map(l => { const [s, e, v] = l.split("\t"); return { s: +s, e: +e, v }; });
    const TOL = 0.35, voiceToLabel = {}, labelToVoice = {}; let bad = 0;
    for (const seg of j.segments) {
      const c = clips.find(c => seg.start >= c.s - TOL && seg.end <= c.e + TOL);
      const wordsOk = seg.words.length > 0 && seg.words.every(w => w.start >= seg.start - 1e-6 && w.end <= seg.end + 1e-6 && w.end >= w.start);
      if (!c || !wordsOk || !seg.speaker) { bad++; console.log("      misaligned:", seg.speaker, seg.start, seg.end, seg.text); continue; }
      (voiceToLabel[c.v] ??= new Set()).add(seg.speaker); (labelToVoice[seg.speaker] ??= new Set()).add(c.v);
    }
    const pure = Object.values(voiceToLabel).every(s => s.size === 1) && Object.values(labelToVoice).every(s => s.size === 1);
    console.log("      speakers:", JSON.stringify(j.speakers), "segments:", j.segments.length, "engine:", j.engine, "locale:", j.locale);
    console.log("      voice -> label:", JSON.stringify(Object.fromEntries(Object.entries(voiceToLabel).map(([k, v]) => [k, [...v].join("|")]))));
    for (const s of j.segments.slice(0, 4)) console.log(`      [${s.speaker} ${s.start.toFixed(2)}-${s.end.toFixed(2)}] ${s.text}`);
    process.exit(j.speakers.length >= 2 && bad === 0 && pure ? 0 : 1);
  ' "$TMP/diar.json" "$TMP/bounds.tsv"; then ok "≥2 speakers, every segment inside one clip, one label per voice"; else fail "speaker/timing check"; fi
  s=$(api GET "/api/notes/$NOTE_ID")
  if jq -e '.transcripts[0].engine=="elevenlabs/scribe_v2" and (.transcripts[0].segments[0].speaker|test("^S[0-9]+$"))' "$TMP/out" >/dev/null; then
    ok "transcripts row replaced with the diarized transcript"; else fail "transcripts row: $(jq -c '.transcripts[0]|{engine,locale}' "$TMP/out")"; fi
  s=$(api POST "/api/recordings/$REC_ID/diarize"); expect 200 "$s" "POST diarize when done -> 200 with the result"
fi

# 6. list since
SINCE="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-5 min' +%Y-%m-%dT%H:%M:%SZ)"
s=$(api GET "/api/notes?since=$SINCE&urls=1"); expect 200 "$s" "GET /api/notes?since="
if jq -e --arg id "$NOTE_ID" '[.notes[]|select(.note.id==$id)]|length==1' "$TMP/out" >/dev/null; then
  ok "list contains the smoke note ($(jq '.notes|length' "$TMP/out") note(s) since $SINCE, $(jq '.subjects|length' "$TMP/out") subject(s))"
else fail "list missing smoke note"; fi

# 6b. agent handoff: 3 recordings (2 speaker-labelled, 1 plain), export PDF + PNG, POST handoff, public /h/<token>.
# SMOKE_HANDOFF_OUT=<file> saves the rendered Markdown briefing.
REC2_ID="$(uuidgen | tr 'A-Z' 'a-z')"; REC3_ID="$(uuidgen | tr 'A-Z' 'a-z')"
R1_AT="2026-09-28T19:17:00.000Z"; R2_AT="2026-09-28T19:21:00.000Z"; R3_AT="2026-09-28T19:25:00.000Z"
jq --arg r1 "$REC_ID" --arg r2 "$REC2_ID" --arg r3 "$REC3_ID" --arg n "$NOTE_ID" --arg a1 "$R1_AT" --arg a2 "$R2_AT" --arg a3 "$R3_AT" '
  .note.title = "Vendor sync: refunds + QA" |
  .note.speaker_names = {"S1":"Reed","S2":"Karen","S3":"Maya",($r2+":S1"):"Karen",($r2+":S2"):"Reed"} |
  .recordings = [
    {id:$r1,ord:0,name:"Recording 1",started_at:$a1,duration_s:83.0,audio_key:("notes/"+$n+"/audio/"+$r1+".m4a"),audio_sha256:null,transcript_status:"complete",deleted_at:null},
    {id:$r2,ord:1,name:"Recording 2",started_at:$a2,duration_s:83.0,audio_key:null,audio_sha256:null,transcript_status:"complete",deleted_at:null},
    {id:$r3,ord:2,name:"Hallway",started_at:$a3,duration_s:20.0,audio_key:null,audio_sha256:null,transcript_status:"complete",deleted_at:null}] |
  .transcripts = [
    {recording_id:$r1,locale:"en-US",engine:"elevenlabs/scribe_v2",full_text:"…",segments:[
      {start:0.04,end:2.68,text:"Okay. Thanks everyone for jumping on.",speaker:"S1"},
      {start:3.1,end:6.0,text:"Quick agenda: refunds, then QA.",speaker:"S1"},
      {start:19.5,end:24.9,text:"One risk. Refunds are still manual, support does them by hand in the dashboard.",speaker:"S2"},
      {start:25.3,end:29.8,text:"Then we should wire up Stripe webhooks for refunds before launch.",speaker:"S1"},
      {start:30.2,end:33.0,text:"Agreed, I can take that.",speaker:"S3"},
      {start:70.0,end:74.5,text:"Last thing before we switch rooms: the launch is still Friday.",speaker:"S1"}]},
    {recording_id:$r2,locale:"en-US",engine:"elevenlabs/scribe_v2",full_text:"…",segments:[
      {start:5.0,end:9.0,text:"So who owns QA for the release?",speaker:"S1"},
      {start:9.4,end:12.0,text:"I will, by Thursday.",speaker:"S2"},
      {start:12.3,end:14.0,text:"Great, thanks.",speaker:"S2"}]},
    {recording_id:$r3,locale:"en-US",engine:"SpeechAnalyzer",full_text:"remember to send the deck",segments:[
      {start:1.0,end:2.0,text:"remember to"},{start:2.1,end:3.0,text:"send the deck"}]}] |
  .strokes_index = null | .elements = []' "$TMP/note.json" > "$TMP/note_h.json"
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/note_h.json"); expect 200 "$s" "PUT note with 3 recordings + speaker names"

printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$TMP/notes.pdf"
printf '\x89PNG\r\n\x1a\n' > "$TMP/page-1.png"; head -c 512 /dev/urandom >> "$TMP/page-1.png"
head -c 2048 /dev/urandom > "$TMP/rec1.m4a"
jq -n --arg n "$NOTE_ID" --arg r1 "$REC_ID" \
  --arg s1 "$(shasum -a 256 "$TMP/notes.pdf" | cut -d' ' -f1)" --arg s2 "$(shasum -a 256 "$TMP/page-1.png" | cut -d' ' -f1)" --arg s3 "$(shasum -a 256 "$TMP/rec1.m4a" | cut -d' ' -f1)" \
  '{noteId:$n, files:[{path:"export/notes.pdf",sha256:$s1,contentType:"application/pdf"},{path:"export/page-1.png",sha256:$s2,contentType:"image/png"},{path:("audio/"+$r1+".m4a"),sha256:$s3,contentType:"audio/mp4"}]}' > "$TMP/up_h.json"
s=$(api POST /api/uploads "$TMP/up_h.json"); expect 200 "$s" "POST /api/uploads export/notes.pdf + export/page-1.png"
cp "$TMP/out" "$TMP/up_h_out.json"
for i in 0 1 2; do
  f=$(jq -r ".uploads[$i].path|sub(\"^export/\";\"\")|sub(\"^audio/.*\";\"rec1.m4a\")" "$TMP/up_h_out.json")
  HDRS=(); while IFS= read -r h; do HDRS+=(-H "$h"); done < <(jq -r ".uploads[$i].headers|to_entries[]|\"\(.key): \(.value)\"" "$TMP/up_h_out.json")
  s=$(curl -sS -o "$TMP/out" -w '%{http_code}' -X PUT "${HDRS[@]}" --data-binary "@$TMP/$f" "$(jq -r ".uploads[$i].url" "$TMP/up_h_out.json")"); expect 200 "$s" "PUT $f"
done
jq -n --arg n "$NOTE_ID" '{noteId:$n, files:[{path:"export/page-0.png",sha256:("a"*64),contentType:"image/png"}]}' > "$TMP/bad_h.json"
s=$(api POST /api/uploads "$TMP/bad_h.json"); expect 400 "$s" "upload export/page-0.png (pages are 1-based) -> 400"

jq -n --arg n "$NOTE_ID" '{
  pdf_key:("notes/"+$n+"/export/notes.pdf"),
  pages:[{index:0,png_key:("notes/"+$n+"/export/page-1.png"),text:"Vendor sync\n! Stripe webhooks for refunds\nQA owner? -> Karen Thu\n# launch Fri"}],
  moments:[{page:0,bbox:[40,80,300,30],t_start:26.4,t_end:31.0,text:"! Stripe webhooks for refunds"},
           {page:0,bbox:[40,120,300,30],t_start:88.2,t_end:92.5,text:"QA owner? -> Karen Thu"},
           {page:0,bbox:[40,20,200,30],t_start:null,t_end:null,text:"Vendor sync"}],
  time_zone:"America/New_York", expires_in_days:30}' > "$TMP/handoff.json"
s=$(api POST "/api/notes/$NOTE_ID/handoff" "$TMP/handoff.json"); expect 200 "$s" "POST /api/notes/:id/handoff"
HURL="$(jq -r .url "$TMP/out")"; HTOK="$(jq -r .token "$TMP/out")"
echo "      expires_at=$(jq -r .expires_at "$TMP/out") warnings=$(jq -c '.warnings // []' "$TMP/out") url=$BASE/h/<token>"
[ "$HURL" = "$BASE/h/$HTOK" ] && [ ${#HTOK} -eq 43 ] && ok "url is <base>/h/<43-char token>" || fail "url/token shape: $HURL"
echo '{"moments":[]}' > "$TMP/handoff_min.json"
s=$(api POST "/api/notes/$(uuidgen | tr 'A-Z' 'a-z')/handoff" "$TMP/handoff_min.json"); expect 404 "$s" "handoff for an unknown note -> 404"
jq '.pdf_key="notes/'"$NOTE_ID"'/drawing.pkdrawing"' "$TMP/handoff.json" > "$TMP/handoff_bad.json"
s=$(api POST "/api/notes/$NOTE_ID/handoff" "$TMP/handoff_bad.json"); expect 400 "$s" "handoff pdf_key outside export/ -> 400"

# public: no Authorization header anywhere below
s=$(curl -sS -D "$TMP/hdr" -o "$TMP/brief.md" -w '%{http_code}' "$HURL"); expect 200 "$s" "GET /h/<token> without auth"
grep -qi '^content-type: text/markdown; charset=utf-8' "$TMP/hdr" && grep -qi '^x-robots-tag: noindex' "$TMP/hdr" && grep -qi '^cache-control: private, no-store' "$TMP/hdr" \
  && ok "markdown content-type + X-Robots-Tag + Cache-Control" || fail "headers: $(tr -d '\r' < "$TMP/hdr" | tr '\n' ' ')"
[ -n "${SMOKE_HANDOFF_OUT:-}" ] && cp "$TMP/brief.md" "$SMOKE_HANDOFF_OUT"
chk() { if grep -qF -- "$1" "$TMP/brief.md"; then ok "briefing has: $1"; else fail "briefing missing: $1"; fi; }
chk "# Vendor sync: refunds + QA"
chk "Speakers: Reed, Karen, Maya"
chk "### 0:26–0:31 · page 1 · \"! Stripe webhooks for refunds\""
chk "- [0:19] **Karen:** One risk."
chk "- ▶ [0:25] **Reed:** Then we should wire up Stripe webhooks"
chk "### 1:28–1:32 · page 1 · \"QA owner? -> Karen Thu\""
chk "- [1:10] **Reed:** Last thing before we switch rooms"
chk "- ▶ [1:28] **Karen:** So who owns QA for the release?"
chk "- ▶ [1:32] **Reed:** I will, by Thursday. Great, thanks."
chk "### Recording 2 · 1:23 · started 3:21 PM · note time 1:23–2:46"
chk "**[2:47]** remember to send the deck"
chk "_Written while no recording was running:_ \"Vendor sync\""
chk "\\# launch Fri"
for p in notes.pdf page/1.png audio/1.m4a; do
  s=$(curl -sS -D "$TMP/hdr" -o /dev/null -w '%{http_code}' "$HURL/$p"); expect 302 "$s" "GET /h/<token>/$p -> 302"
  LOC="$(tr -d '\r' < "$TMP/hdr" | sed -n 's/^[Ll]ocation: //p')"
  s=$(curl -sS -o "$TMP/dl" -w '%{http_code}' "$LOC"); expect 200 "$s" "  follow redirect for $p"
  f=$(basename "$p"); [ "$f" = 1.png ] && f=page-1.png; [ "$f" = 1.m4a ] && f=rec1.m4a
  cmp -s "$TMP/dl" "$TMP/$f" && ok "  $p bytes match" || fail "  $p bytes differ"
done
for p in page/2.png audio/2.m4a audio/9.m4a nope; do
  s=$(curl -sS -o "$TMP/out" -w '%{http_code}' "$HURL/$p"); expect 404 "$s" "GET /h/<token>/$p -> 404"
done
s=$(curl -sS -o "$TMP/brief.json" -w '%{http_code}' "$HURL?format=json"); expect 200 "$s" "GET /h/<token>?format=json"
jq -e '.note.speakers==["Reed","Karen","Maya"] and (.recordings|length)==3 and .recordings[1].offset_s==83 and (.moments[1].transcript|map(.recording)|index(2)) != null and .pages[0].image_url != null' "$TMP/brief.json" >/dev/null \
  && ok "json: speakers, offsets, moment window spans recordings 1+2" || fail "json: $(head -c 300 "$TMP/brief.json")"
s=$(curl -sS -I -o /dev/null -w '%{http_code}' "$HURL"); expect 200 "$s" "HEAD /h/<token>"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' "$BASE/h/not-a-token"); expect 404 "$s" "bad token -> 404"; echo "      $(cat "$TMP/out")"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' "$BASE/h/$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"); expect 404 "$s" "unknown well-formed token -> 404"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' -X DELETE "$BASE/api/handoffs/$HTOK"); expect 401 "$s" "revoke without auth -> 401"
s=$(api DELETE "/api/handoffs/$HTOK"); expect 200 "$s" "DELETE /api/handoffs/:token"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' "$HURL"); expect 404 "$s" "revoked link -> 404"
s=$(curl -sS -o "$TMP/out" -w '%{http_code}' "$HURL/notes.pdf"); expect 404 "$s" "revoked link file -> 404"
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/note.json"); expect 200 "$s" "PUT back to 1 recording (tombstones recordings 2+3)"

# 7. re-PUT without the recording/element -> tombstoned
jq '.recordings=[] | .transcripts=[] | .elements=[] | .strokes_index=null' "$TMP/note.json" > "$TMP/note2.json"
s=$(api PUT "/api/notes/$NOTE_ID" "$TMP/note2.json"); expect 200 "$s" "PUT without recording/element"
if jq -e '.recordings.tombstoned==1 and .elements.tombstoned==1' "$TMP/out" >/dev/null; then ok "missing recording + element tombstoned"; else fail "tombstone counts: $(cat "$TMP/out")"; fi

# 8. DELETE (tombstone)
s=$(api DELETE "/api/notes/$NOTE_ID"); expect 200 "$s" "DELETE /api/notes/:id"; echo "      $(cat "$TMP/out")"
s=$(api GET "/api/notes/$NOTE_ID")
if jq -e '.note.deleted_at != null' "$TMP/out" >/dev/null; then ok "note shows deleted_at after DELETE"; else fail "note not tombstoned"; fi

echo "----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
