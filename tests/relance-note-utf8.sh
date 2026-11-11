#!/usr/bin/env bash
# Prouve que la note de relance est de l'UTF-8 VALIDE, donc acceptee par
# `maki.session.prompt`.
#
# Pourquoi ce test existe (mesure du 2026-11-11, AnhyWhere, question du
# proprietaire « pourquoi /relance ne te relance pas tout seul ») : `/relance` a
# rendu
#   command handler failed: bad argument #1: error converting Lua string to
#   String (invalid utf-8 sequence of 1 bytes from index 402)
# et la boucle est restee ARMEE sans jamais poster un tour (state.json :
# armed=true, runs=0). La cause n'etait pas l'armement : `tronque` coupait la
# demande a `longueur - 1` OCTETS, donc au milieu d'un caractere accentue, et la
# note portait un octet de continuation isole.
#
# Ce que le test mesure :
#   A  tronque() sur une coupe qui tombe dans « é » -> UTF-8 valide
#   B  resume_note() sur le SUIVI REEL (la note qui a fait echouer /relance) -> UTF-8 valide
#   C  controle negatif : le validateur du test REFUSE bien l'ancienne coupe
#      (sinon A et B ne prouveraient rien)
#
# Un seul appel modele court. Sort en erreur sur tout ecart.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SUIVI=${SUIVI:-/root/AnhyWhere/docs/design/SUIVI.md}
CFG=$(mktemp -d)
LOG="$HOME/.local/logs/maki/maki.log"
trap 'rm -rf "$CFG"' EXIT

mkdir -p "$CFG/maki/lua"
cp lua/relance.lua lua/ocgo.lua lua/tps.lua "$CFG/maki/lua/"
cp plugin.toml "$CFG/maki/plugin.toml"
printf 'require("ocgo")\nrequire("tps")\nrequire("relance")\nrequire("selftest")\n' \
  > "$CFG/maki/init.lua"

PROMPT="Reply with the single word: ok"

cat > "$CFG/maki/lua/selftest.lua" <<'LUA'
local R = require("relance")

-- Validateur strict : chaque octet de tete annonce ses continuations, et aucune
-- ne manque. C'est exactement ce que le convertisseur de maki refuse.
local function valide(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local extra
    if c < 0x80 then
      extra = 0
    elseif c >= 0xC2 and c <= 0xDF then
      extra = 1
    elseif c >= 0xE0 and c <= 0xEF then
      extra = 2
    elseif c >= 0xF0 and c <= 0xF4 then
      extra = 3
    else
      return false, i
    end
    for k = 1, extra do
      local b = s:byte(i + k)
      if not b or b < 0x80 or b > 0xBF then
        return false, i
      end
    end
    i = i + 1 + extra
  end
  return true, #s
end

maki.defer_fn(function()
  local T = R._test

  -- A : 138 « a » puis des « é » : la coupe a 139 octets tombe DANS le premier é
  -- (0xC3 0xA9), ce que l'ancien `sub(1, longueur - 1)` rendait invalide.
  local casse = ("a"):rep(138) .. "ééé"
  local note = T.tronque(casse, 140)
  local a_ok, a_pos = valide(note)
  maki.log.info(string.format("relance-utf8 A valide=%s taille=%d", tostring(a_ok), #note))

  -- B : la note REELLE, construite depuis le SUIVI qui a fait echouer /relance.
  local brut = maki.fs.read("@SUIVI@") or ""
  local total, done, nonfini = R.parse(brut)
  local traitable = {}
  for _, item in ipairs(nonfini) do
    if not item.blocked then
      traitable[#traitable + 1] = item
    end
  end
  local st = { runs = 0, max = 0 }
  local reelle = T.resume_note(st, "@SUIVI@", total, done, nonfini, traitable)
  local b_ok, b_pos = valide(reelle)
  maki.log.info(string.format("relance-utf8 B valide=%s taille=%d traitables=%d",
    tostring(b_ok), #reelle, #traitable))

  -- C : controle negatif. La coupe de l'ancien code, telle quelle.
  local ancienne = ("a"):rep(138) .. "\xC3"
  local c_ok = valide(ancienne)
  maki.log.info(string.format("relance-utf8 C detecte=%s", tostring(not c_ok)))
end, 500)
LUA

sed -i "s|@SUIVI@|$SUIVI|g" "$CFG/maki/lua/selftest.lua"

before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
XDG_CONFIG_HOME="$CFG" timeout 120 maki -p "$PROMPT" --max-turns 1 >/dev/null 2>/tmp/relance-utf8.err
delta=$(tail -n +$((before + 1)) "$LOG" 2>/dev/null)

fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"
  else
    echo "FAIL $name (got '$got', want '$want')"
    fail=1
  fi
}

check "A  tronque() reste un UTF-8 valide" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-utf8 A valide=[a-z]*' | head -1 | sed 's/.*=//')" "true"
check "B  la note de relance du SUIVI reel est un UTF-8 valide" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-utf8 B valide=[a-z]*' | head -1 | sed 's/.*=//')" "true"
check "C  controle negatif : l'ancienne coupe est refusee" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-utf8 C detecte=[a-z]*' | head -1 | sed 's/.*=//')" "true"

if [[ -s /tmp/relance-utf8.err ]]; then
  echo "--- stderr ---"
  cat /tmp/relance-utf8.err
fi

exit "$fail"
