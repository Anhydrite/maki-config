#!/usr/bin/env bash
# Prouve que le lecteur du SUIVI RESPECTE LE PIPE ECHAPPE (`\|`) dans une
# cellule, et que le rang de l'etat ne se decale donc plus.
#
# Pourquoi ce test existe (mesure du 2026-11-09, dans AnhyWhere) : `REQ-20261109-13`
# a ete proposee DEUX RELANCES DE SUITE alors que sa ligne etait close et
# publiee. La demande contient un pipe echappe — `curl -fsSL … | sudo sh` ecrit
# `\|` — et `cells_of` decoupait sur TOUS les pipes : `cells[3]` valait un
# fragment de la demande («  sudo sh -s -- --install` → … »), jamais l'etat. Une
# ligne dont la demande contient `\|` ne pouvait donc JAMAIS etre vue finie.
#
# Ce que le test mesure :
#   A  trois lignes synthetiques (une close, une bloquee, une close) -> total 3, fini 2
#   B  la ligne close A PIPE ECHAPPE n'est pas dans les non finies
#   C  la ligne BLOQUEE a pipe echappe reste non finie ET bloquee (controle negatif :
#      le correctif ne doit pas avaler une ligne ouverte avec le meme caractere)
#   D  sur le SUIVI reel, `REQ-20261109-13` n'est plus comptee non finie
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

maki.defer_fn(function()
  -- Trois lignes qui portent le MEME pipe echappe, dans la demande.
  local synthetique = table.concat({
    "| REQ-20261109-98 | demande avec un \\| pipe | **FAIT — close** | preuve |",
    "| REQ-20261109-99 | demande avec un \\| pipe | **EN ATTENTE — décision du propriétaire** | preuve |",
    "| REQ-20261109-13 | demande avec un \\| pipe | **FAIT — close** | preuve |",
  }, "\n")

  local total, done, nonfini = R.parse(synthetique)
  local vu = {}
  for _, item in ipairs(nonfini) do
    vu[item.id] = item
  end
  maki.log.info(string.format("relance-parse A total=%d fini=%d", total, done))
  maki.log.info("relance-parse B close_au_pipe_absente=" .. tostring(vu["REQ-20261109-98"] == nil))
  maki.log.info("relance-parse C bloquee_au_pipe="
    .. tostring(vu["REQ-20261109-99"] ~= nil and vu["REQ-20261109-99"].blocked == true))

  -- Le SUIVI reel, celui qui a fait tourner la relance deux fois pour rien.
  local brut = maki.fs.read("@SUIVI@") or ""
  local reel_total, reel_fini, reel_nonfini = R.parse(brut)
  local enCours = {}
  for _, item in ipairs(reel_nonfini) do
    enCours[item.id] = true
  end
  maki.log.info(string.format("relance-parse D reel_total=%d reel_fini=%d treize_en_cours=%s",
    reel_total, reel_fini, tostring(enCours["REQ-20261109-13"] == true)))
end, 500)
LUA

sed -i "s|@SUIVI@|$SUIVI|g" "$CFG/maki/lua/selftest.lua"

before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
XDG_CONFIG_HOME="$CFG" timeout 120 maki -p "$PROMPT" --max-turns 1 >/dev/null 2>/tmp/relance-parse.err
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

check "A  total et fini sur le jeu synthetique" \
  "$(printf '%s\n' "$delta" | grep -o 'relance-parse A [^\"]*' | head -1 | sed 's/.*A //')" "total=3 fini=2"
check "B  la ligne close a pipe echappe n'est pas non finie" \
  "$(printf '%s\n' "$delta" | grep -o 'close_au_pipe_absente=[a-z]*' | head -1 | sed 's/.*=//')" "true"
check "C  la ligne bloquee a pipe echappe reste bloquee" \
  "$(printf '%s\n' "$delta" | grep -o 'bloquee_au_pipe=[a-z]*' | head -1 | sed 's/.*=//')" "true"
check "D  REQ-20261109-13 n'est plus non finie dans le SUIVI reel" \
  "$(printf '%s\n' "$delta" | grep -o 'treize_en_cours=[a-z]*' | head -1 | sed 's/.*=//')" "false"

if [[ -s /tmp/relance-parse.err ]]; then
  echo "--- stderr ---"
  cat /tmp/relance-parse.err
fi

exit "$fail"
