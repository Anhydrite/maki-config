#!/usr/bin/env bash
# Prouve que l'armement de lua/relance.lua SURVIT a un rechargement et qu'une
# extinction demandee ne se rallume pas toute seule.
#
# Pourquoi ce test existe (mesure du 2026-11-04) : l'armement ne vivait que dans
# la table `sessions` du module. Un `/reload` -- ou un redemarrage de maki -- la
# vide, et la boucle s'eteint EN SILENCE : le proprietaire a constate ce silence
# juste apres une autocompaction, alors que `docs/design/SUIVI.md` gardait du
# travail. Le remede ecrit l'armement sur disque et le relit au premier
# evenement du plugin.
#
# Ce que le test mesure, sans compaction et sans attendre un vrai /reload :
#   A  armement ecrit            -> le fichier d'etat existe et porte armed=true
#   B  table videe + relecture   -> l'armement revient (c'est ce que fait un /reload)
#   C  stop demande              -> le fichier ne porte plus AUCUNE session armee
#
# Controle negatif, pour le harnais : `this is not lua` ajoute au plugin copie
# fait sortir "syntax error" sur stderr -- un silence ne vaut donc pas un succes.
#
# Un seul appel modele court. Sort en erreur sur tout ecart.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CFG=$(mktemp -d)
LOG="$HOME/.local/logs/maki/maki.log"
trap 'rm -rf "$CFG"' EXIT

mkdir -p "$CFG/maki/lua"
cp lua/relance.lua lua/ocgo.lua lua/tps.lua "$CFG/maki/lua/"
cp plugin.toml "$CFG/maki/plugin.toml"
printf 'require("ocgo")\nrequire("tps")\nrequire("relance")\nrequire("selftest")\n' \
  > "$CFG/maki/init.lua"

PROMPT="List the numbers from 1 to 300 separated by spaces, then stop."

cat > "$CFG/maki/lua/selftest.lua" <<'LUA'
local R = require("relance")
-- Id FACTICE : un run `-p` n'a pas de session courante (mesure : current() rend nil),
-- et l'etat est range par id. Un id de test ne touche aucune session reelle, et le
-- cas C le retire du fichier d'etat.
local sid = "selftest-relance"
local T = R._test

maki.defer_fn(function()
  -- A : armer et ecrire.
  local st = T.state_for(sid)
  st.armed = true
  st.max = 0
  st.path = "/tmp/suivi-de-test.md"
  T.write_state()
  local chemin = T.state_file()
  local texte = maki.fs.read(chemin) or ""
  local arme = texte:find('"armed":true') ~= nil
  maki.log.info(string.format("relance-survie A fichier=%s arme=%s", tostring(chemin), tostring(arme)))

  -- B : ce que fait un /reload -- la table disparait, le disque reste.
  local restaure = "nil"
  T.sessions[sid] = nil
  local lu = T.read_state()
  if lu[sid] then
    restaure = tostring(lu[sid].armed)
  end
  maki.log.info("relance-survie B restaure=" .. restaure)

  -- C : une extinction demandee ne doit pas revenir au chargement suivant.
  T.stop(sid, "test", false)
  T.sessions[sid] = nil
  local apres = maki.fs.read(chemin) or ""
  local vide = apres:find('"armed":true') == nil
  maki.log.info("relance-survie C vide=" .. tostring(vide))
end, 500)
LUA

before=$(wc -l < "$LOG")
XDG_CONFIG_HOME="$CFG" timeout 120 maki -p "$PROMPT" --max-turns 1 >/dev/null 2>/tmp/relance-survie.err
delta=$(tail -n +$((before + 1)) "$LOG")

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

check "A  armement ecrit" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-survie A .*arme=[a-z]*' | head -1 | sed 's/.*arme=//')" "true"
check "B  armement relu apres vidage de la table" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-survie B restaure=[a-z]*' | head -1 | sed 's/.*restaure=//')" "true"
check "C  extinction non persistee" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-survie C vide=[a-z]*' | head -1 | sed 's/.*vide=//')" "true"

# Controle negatif du harnais : un plugin casse doit parler.
BAD=$(mktemp -d)
mkdir -p "$BAD/maki/lua"
cp lua/*.lua "$BAD/maki/lua/"
cp plugin.toml "$BAD/maki/plugin.toml"
printf 'require("relance")\n' > "$BAD/maki/init.lua"
printf '\nthis is not lua\n' >> "$BAD/maki/lua/relance.lua"
XDG_CONFIG_HOME="$BAD" timeout 60 maki -p "say ok" --max-turns 1 >"$BAD/out" 2>&1
if grep -q "syntax error" "$BAD/out"; then
  echo "OK   controle negatif (syntax error detectee)"
else
  echo "FAIL controle negatif : un plugin casse n'a rien signale"
  fail=1
fi
rm -rf "$BAD"

exit "$fail"
