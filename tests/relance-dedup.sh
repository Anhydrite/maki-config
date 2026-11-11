#!/usr/bin/env bash
# Prouve qu'un DOUBLE EVENEMENT ne poste pas deux relances pour la meme ligne.
#
# Pourquoi ce test existe (mesure du 2026-11-11, constat du proprietaire « corriger le bug
# de /relance qui donne 2 fois la relance ») : trois evenements rapproches appellent `step`
# pour la meme fin de tour — `TurnEnd` (+300 ms), `SessionStatusChanged` -> idle (+500 ms)
# et `InputChanged` (+300 ms). Quand la session est deja `idle` au moment du `TurnEnd`, les
# deux premiers passent le garde « occupe » et postent DEUX prompts : l'agent recoit deux
# fois la meme relance, pour la meme ligne.
#
# Ce que le test mesure, sur la fonction PURE (pas d'attente, pas de modele double) :
#   A  meme signature dans la fenetre   -> doublon (rien n'est poste)
#   B  meme signature apres la fenetre  -> pas doublon (une relance ulterieure reste possible)
#   C  signature DIFFERENTE             -> pas doublon (le fichier a bouge : c'est une vraie relance)
#   D  aucun prompt precedent           -> pas doublon (controle negatif : sinon la boucle
#                                          ne posterait jamais rien)
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

PROMPT="Reply with the single word: ok"

cat > "$CFG/maki/lua/selftest.lua" <<'LUA'
local R = require("relance")

maki.defer_fn(function()
  local T = R._test
  local maintenant = 1000000
  local fenetre = T.dedup_window and T.dedup_window() or 0

  -- A : meme signature, dans la fenetre -> doublon.
  local st = { last_prompt_at = maintenant - 1, last_prompt_sig = "sig-1" }
  maki.log.info("relance-dedup A doublon=" .. tostring(T.estDoublon(st, "sig-1", maintenant)))

  -- B : meme signature, apres la fenetre -> pas doublon.
  local st2 = { last_prompt_at = maintenant - (fenetre + 1), last_prompt_sig = "sig-1" }
  maki.log.info("relance-dedup B doublon=" .. tostring(T.estDoublon(st2, "sig-1", maintenant)))

  -- C : signature differente, dans la fenetre -> pas doublon (le fichier a bouge).
  maki.log.info("relance-dedup C doublon=" .. tostring(T.estDoublon(st, "sig-2", maintenant)))

  -- D : controle negatif, aucun prompt precedent.
  maki.log.info("relance-dedup D doublon=" .. tostring(T.estDoublon({}, "sig-1", maintenant)))
end, 500)
LUA

before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
XDG_CONFIG_HOME="$CFG" timeout 120 maki -p "$PROMPT" --max-turns 1 >/dev/null 2>/tmp/relance-dedup.err
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

valeur() { printf '%s\n' "$delta" | grep -o "relance-dedup $1 doublon=[a-z]*" | head -1 | sed 's/.*=//'; }

check "A  meme signature dans la fenetre = doublon" "$(valeur A)" "true"
check "B  meme signature apres la fenetre = pas doublon" "$(valeur B)" "false"
check "C  signature differente = pas doublon" "$(valeur C)" "false"
check "D  aucun prompt precedent = pas doublon" "$(valeur D)" "false"

if [[ -s /tmp/relance-dedup.err ]]; then
  echo "--- stderr ---"
  cat /tmp/relance-dedup.err
fi

exit "$fail"
