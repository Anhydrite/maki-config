-- /relance — auto-relaunch driven by the project's suivi.md.
--
-- `/relance init` creates docs/suivi.md with the writing rules when no ledger
-- exists yet (never overwriting one), so arming never dies on "no suivi.md
-- found" without a way forward.
--
-- The file is the arbiter: a `REQ-YYYYMMDD-NN` row is finished when its state
-- cell starts with "fait" (which covers "fait, publié" and "fait, à publier"),
-- and a checkbox case is finished when it is `[x]`. Everything else is work
-- left on the table, so the plugin wakes the session again after each turn
-- until nothing is left.
--
-- Why the file and not the transcript: the agent cannot quietly decide it is
-- done. The ledger already carries the truth, and the turn that updates it is
-- the same turn that claims the work.
--
-- Guards, in the order they stop the loop:
--   1. no unfinished task left                      -> done
--   2. turn cancelled (Esc), or dropped             -> stopped
--   3. two relaunches without the ledger moving     -> stopped, and named
--   4. the iteration cap                            -> stopped
-- A turn closed by ANY OTHER reason (compaction, end_turn, max_turns) does not
-- stop the loop: measured 2026-11-04, the loop went silent right after an
-- auto-compaction while the file still held work.
-- The user keeps the floor: a queued prompt, a running turn, or text in the
-- input bar never gets a wake on top of it.
--
-- DURABILITE — MESURE DU 2026-11-04. Le proprietaire a constate que la session
-- s'arretait alors que `docs/design/SUIVI.md` gardait du travail, et la cause
-- n'etait pas la compaction elle-meme : l'armement vivait UNIQUEMENT dans la
-- table `sessions` de ce module. Un `/reload` (ou un redemarrage de maki) la
-- vide, et rien ne le dit : la boucle s'eteint en silence. L'armement est donc
-- ECRIT SUR DISQUE (`maki.env.state_dir()/relance/state.json`) et RESTAURE au
-- chargement, puis relance de lui-meme la session RESTEE ARMEE. Une
-- autocompaction remet aussi les strikes a zero : ses tours de relecture ne
-- comptent plus comme « sans progres », puisque le fichier n'a pas bouge.

local MAX_STRIKES = 2
-- MESURE DU 2026-11-10 : `step` s'efface quand la session est occupee (statut
-- "working", prompt en file, ou texte en cours de frappe) et ne reprogrammait
-- RIEN. Un `TurnEnd` etait la seule seconde chance ; si le proprietaire
-- commencait a taper juste apres le rapport, aucun tour ne suivait et la
-- boucle restait ARMED mais muette (constate apres le run 18).
--
-- MESURE DU 2026-11-10 (suite) : arreter au bout de 120 s contredisait la regle du
-- proprietaire (« reste actif tant que je ne l'ai pas desactive »). Taper une
-- longue question `/btw` occupe la session plusieurs minutes ; la boucle doit
-- alors ATTENDRE son tour, pas s'eteindre. Au-dela du plafond on RALENTIT donc
-- le sondage au lieu d'arreter, et les evenements qui rendent la parole
-- (SessionStatusChanged -> idle, InputChanged) remettent le compteur a zero et
-- reveillent la relance tout de suite.
local RETRY_DELAY_MS = 3000
local MAX_OCCUPIED_RETRIES = 40
local SLOW_RETRY_DELAY_MS = 15000

local step -- forward: schedule_retry below calls it
-- 0 = AUCUN PLAFOND, et c'est le defaut. Demande du proprietaire, 2026-10-28 : « il faut que /relacne
-- reste actif tant que je ne l'ai pas desactive ». Le plafond de 15 arretait la boucle sans que
-- personne ne l'ait demande ; `/relance 20` en pose un explicitement, et `/relance` seul l'eteint.
local DEFAULT_MAX = 0

-- A state cell that begins with one of these is a finished line. Prefix
-- matching on purpose: "fait, publié", "terminé", "livré", "soldé" all pass,
-- and accents never enter the comparison.
local DONE_STEMS = { "fait", "termin", "livr", "publi", "sold", "done", "ok" }

-- Une ligne dont l'etat dit « en attente de decision / d'arbitrage » ne se TRAVAILLE pas : elle se
-- POSE en question. Mesure du 2026-10-28 : cinq lignes bloquees par la meme question restee sans
-- reponse, et la relance a redemande trois fois le meme travail, qui ne pouvait pas se faire.
--
-- MESURE DU 2026-10-30 : CE DETECTEUR NE CONNAISSAIT QUE LA DECISION, ET IL A FAIT 25 RELANCES INUTILES.
-- Les huit lignes restantes du projet AnhyWhere disaient « **EN ATTENTE — PUBLICATION** » ou
-- « **EN ATTENTE D'UN ACTE DU PROPRIÉTAIRE** ». Aucune ne contenait « décision » : toutes passaient
-- donc pour TRAVAILLABLES, et la boucle a redemandé vingt-cinq fois « prends la PREMIÈRE de ces
-- lignes, traite-la entièrement » pour un travail qui n'existait pas — le code était livré, il ne
-- manquait que des actes d'exploitation (publier, rallumer le WAF, copier des gabarits, ré-adhérer
-- les nœuds) que l'agent ne peut pas faire.
--
-- UN ACTE BLOQUE COMME UNE DECISION. C'est la regle qui manquait : la relance doit POSER la question
-- au propriétaire dès que la ligne attend de lui quelque chose — un arbitrage ou un geste.
local ACT_STEMS = { "publication", "proprietaire", "propriétaire", "acte" }

local function is_blocked(state)
  local s = (state or ""):lower()

  -- 1. UNE DECISION BLOQUE, MEME SANS LE MOT « ATTENTE ». Mesure du 2026-10-30 :
  --    `**À FAIRE — décision de fonctionnalité**` n'etait pas vue comme bloquee, parce que le
  --    detecteur exigeait d'abord « attente ». La relance redemandait donc de travailler une ligne
  --    dont l'objet meme est de trancher.
  -- Une decision DEJA RENDUE n'est plus un blocage : elle devient du travail. Mesure du 2026-10-30,
  -- apres la reponse du proprietaire (`REQ-20261030-09` : « décision rendue (b) : ignorer le
  -- parametre ») — sans cette exception, la relance aurait pose une question deja repondue.
  local rendue = s:find("décision rendue", 1, true) or s:find("decision rendue", 1, true)
    or s:find("décision prise", 1, true) or s:find("decision prise", 1, true)
  if not rendue
    and (s:find("décision", 1, true) or s:find("decision", 1, true) or s:find("arbitrage", 1, true)) then
    return true
  end

  -- 2. UN ACTE D'EXPLOITATION BLOQUE COMME UNE DECISION, mais seulement sous « attente » — sinon le
  --    mot « acte » d'une demande ordinaire ferait passer une ligne travaillable pour bloquee.
  if not s:find("attente", 1, true) then
    return false
  end
  for _, mot in ipairs(ACT_STEMS) do
    if s:find(mot, 1, true) then
      return true
    end
  end
  return false
end

local function bloque_count(items)
  local n = 0
  for _, item in ipairs(items) do
    if item.blocked then
      n = n + 1
    end
  end
  return n
end

local CANDIDATES = {
  "suivi.md",
  "SUIVI.md",
  "Suivi.md",
  "docs/design/SUIVI.md",
  "docs/design/suivi.md",
  "docs/SUIVI.md",
  "docs/suivi.md",
}

local log = maki.log

-- session id -> state table
local sessions = {}

local function debug(msg)
  log.debug("relance: " .. msg)
end

-- ARMEMENT PERSISTANT : voir DURABILITE en tete de fichier. Un seul fichier par
-- processus maki, hors du projet (maki.env.state_dir()), donc il ne pollue aucun
-- arbre et il survit a `/reload` comme a un redemarrage.
local STATE_VERSION = 1
local STATE_SUBDIR = "relance"

local function state_file()
  local dir = maki.env.state_dir()
  if not dir then
    return nil
  end
  return maki.fs.joinpath(dir, STATE_SUBDIR, "state.json")
end

local function read_state_file()
  local path = state_file()
  if not path then
    return {}
  end
  local text = maki.fs.read(path)
  if not text or text == "" then
    return {}
  end
  local ok, decoded = pcall(maki.json.decode, text)
  if not ok or type(decoded) ~= "table" or type(decoded.sessions) ~= "table" then
    return {}
  end
  local out = {}
  for id, saved in pairs(decoded.sessions) do
    if type(saved) == "table" and saved.armed then
      out[id] = saved
    end
  end
  return out
end

local function write_state_file()
  local path = state_file()
  if not path then
    return
  end
  local saved = {}
  for id, st in pairs(sessions) do
    if st.armed then
      saved[id] = { armed = true, max = st.max or 0, path = st.path, runs = st.runs or 0 }
    end
  end
  local encoded = maki.json.encode({ version = STATE_VERSION, sessions = saved })
  maki.fs.mkdir(maki.fs.dirname(path), { parents = true })
  local ok, err = maki.fs.atomic_write(path, encoded)
  if not ok then
    debug("etat non ecrit : " .. tostring(err))
  end
end

-- LU A LA DEMANDE, JAMAIS AU CHARGEMENT : `maki.fs.read` est asynchrone, et un
-- appel au niveau du module casse `require("relance")` (« attempt to yield
-- across metamethod/C-call boundary », mesure par `maki index` le 2026-11-04).
-- Un `/reload` retrouve quand meme ce qu'il vient de perdre : la lecture se
-- fait au premier evenement, qui est aussi le premier besoin.
local persisted = nil

local function persisted_state()
  if not persisted then
    persisted = read_state_file()
  end
  return persisted
end

local function is_done(state)
  local s = (state or ""):lower()
  s = s:gsub("^%**", ""):gsub("^%s+", "")
  if s == "" then
    return false
  end
  for _, stem in ipairs(DONE_STEMS) do
    if s:sub(1, #stem) == stem then
      return true
    end
  end
  return false
end

-- Split a markdown table row into cells, dropping the outer pipes.
local function cells_of(line)
  local s = line
  if s:sub(1, 1) == "|" then
    s = s:sub(2)
  end
  if s:sub(-1) == "|" then
    s = s:sub(1, -2)
  end
  local out = {}
  for cell in (s .. "|"):gmatch("([^|]*)|") do
    out[#out + 1] = cell
  end
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Read the ledger: returns total, finished, and the list of unfinished items.
-- Two shapes are understood in the same pass, because a project may carry both:
--   | REQ-20261025-27 | demande | en attente | preuve |
--   - [ ] something
local function parse(text)
  local total, done, unfinished = 0, 0, {}
  local lineno = 0

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local stripped = trim(line)

    local id = stripped:match("^|%s*(REQ%-%d%d%d%d%d%d%d%d%-%d+)")
    if id then
      local cells = cells_of(stripped)
      local state = trim(cells[3] or "")
      total = total + 1
      if is_done(state) then
        done = done + 1
      else
        unfinished[#unfinished + 1] = {
          id = id,
          state = state,
          line = lineno,
          demand = trim(cells[2] or ""),
          blocked = is_blocked(state),
        }
      end
    elseif stripped:find("^|") then
      -- any other table row: not a task, do not count it
    else
      local box = stripped:match("^[-*+]%s+%[(.)%]%s*(.+)$")
      if box then
        if box == "x" or box == "X" then
          total = total + 1
          done = done + 1
        elseif box == " " or box == "" then
          total = total + 1
          unfinished[#unfinished + 1] = {
            id = "#" .. lineno,
            state = "à faire",
            line = lineno,
            demand = trim((stripped:gsub("^[-*+]%s+%[.%]%s*", ""))),
          }
        end
      end
    end
  end

  return total, done, unfinished
end

-- Cheap change detector: the counts plus a byte checksum of the whole file.
-- Counts alone would miss a line rewritten in place; the checksum alone would
-- fire on every proof appended. Both together are what "the ledger moved" means.
local function signature(text, total, done)
  local sum = 0
  for i = 1, #text, 97 do
    sum = (sum * 31 + text:byte(i)) % 2147483647
  end
  return string.format("%d/%d/%d/%d", total, done, sum, #text)
end

local function state_for(session_id)
  -- Un id absent n'est pas une session : un etat JETABLE, jamais range. Sans ce
  -- garde, `sessions[nil]` leve « table index is nil » et emporte le callback
  -- appelant (mesure par `tests/relance-survie.sh` le 2026-11-04 : un run `-p`
  -- n'a pas de session courante).
  if not session_id then
    return {
      armed = false,
      runs = 0,
      strikes = 0,
      last_sig = nil,
      path = nil,
      max = DEFAULT_MAX,
      restored = false,
      retries = 0,
    }
  end
  local st = sessions[session_id]
  if not st then
    st = {
      armed = false,
      runs = 0,
      strikes = 0,
      last_sig = nil,
      path = nil,
      max = DEFAULT_MAX,
      restored = false,
      retries = 0,
    }
    -- Un armement ecrit avant un `/reload` ou un redemarrage reprend ici : sans
    -- cette reprise, la boucle s'eteint en silence (mesure du 2026-11-04).
    local saved = persisted_state()[session_id]
    if saved then
      st.armed = true
      st.path = saved.path
      if type(saved.max) == "number" then
        st.max = saved.max
      end
      st.restored = true
      log.info("relance: armement restaure pour " .. session_id .. " (" .. tostring(state_file()) .. ")")
    end
    sessions[session_id] = st
  end
  return st
end

local function find_ledger(cwd, wanted)
  if wanted and wanted ~= "" then
    local path = wanted
    if path:sub(1, 1) ~= "/" and cwd then
      path = maki.fs.joinpath(cwd, path)
    end
    local text = maki.fs.read(path)
    if text then
      return path, text
    end
    return nil, nil
  end

  local dir, seen = cwd, {}
  while dir and not seen[dir] do
    seen[dir] = true
    for _, name in ipairs(CANDIDATES) do
      local candidate = maki.fs.joinpath(dir, name)
      local text = maki.fs.read(candidate)
      if text then
        return candidate, text
      end
    end
    local parent = maki.fs.dirname(dir)
    if not parent or parent == dir or parent == "" or parent == "." then
      break
    end
    dir = parent
  end
  return nil, nil
end

local function rel(path)
  local cwd = maki.uv.cwd()
  if cwd and path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return path
end

-- /relance init — LE FICHIER NE DOIT PAS EXISTER POUR ETRE CREE. Le gabarit
-- DICTE l'ecriture (formes lues, vocabulaire des etats, regles de tenue) parce
-- qu'un suivi vide ne dit rien : l'agent qui le remplit sans regle ecrit des
-- lignes que ce module ne sait pas lire, et la relance tourne a vide.
--
-- La cible par defaut est docs/suivi.md : c'est la ou le proprietaire range ses
-- suivis (docs/design/SUIVI.md dans ses projets), donc on ne cree pas un
-- suivi.md a la racine d'un depot qui a deja une arborescence docs/.
local INIT_TARGET = "docs/suivi.md"

local function ledger_template()
  return table.concat({
    "# suivi — source de verite de /relance",
    "",
    "Ce fichier est le seul juge de l'avancement. La relance le relit a chaque tour,",
    "reprend une seule tache, et s'arrete quand plus aucune ligne n'est ouverte. Elle",
    "ne se fie ni au resume de la conversation ni a ce que l'agent raconte.",
    "",
    "## Comment ecrire une ligne",
    "",
    "Deux formes sont lues, et elles peuvent cohabiter dans le meme fichier :",
    "",
    "1. Ligne de tableau, identifiant REQ :",
    "",
    "   | ID | Demande | Etat | Preuve |",
    "   | --- | --- | --- | --- |",
    "   | REQ-AAAAMMJJ-NN | ce qu'il faut faire, en une phrase actionnable | a faire | test ou chemin |",
    "",
    "   Seules les lignes dont la colonne 1 vaut REQ- suivi de 8 chiffres, d'un tiret",
    "   et d'un numero sont comptees. Les autres lignes de tableau sont ignorees.",
    "",
    "2. Case a cocher : `- [ ] intitule` ouverte, `- [x] intitule` finie.",
    "",
    "## Vocabulaire des etats (colonne 3)",
    "",
    "| Etat ecrit | Ce que la relance en fait |",
    "| --- | --- |",
    "| a faire, en cours, tout le reste | travail : la ligne est reprise |",
    "| fait, termine, livre, publie, solde, done, ok | finie : ignoree (le prefixe suffit, « fait, publie » passe) |",
    "| attente de decision, arbitrage | posee en question au proprietaire, jamais travaillee |",
    "| attente — publication, attente d'un acte du proprietaire | idem : un acte d'exploitation n'est pas du code |",
    "| decision rendue (a) | debloquee : redevient du travail |",
    "",
    "## Les regles de tenue",
    "",
    "- Une ligne par tache, et on n'efface jamais une ligne finie : le fichier est l'historique.",
    "- Le tour qui fait le travail met SA ligne a jour dans le meme geste. Un tour qui",
    "  n'ecrit pas compte comme un tour sans progres, et deux d'affilee arretent la relance.",
    "- Jamais « fait » sans preuve : la colonne 4 cite le fichier, le test ou la sortie obtenue.",
    "- Un identifiant neuf a chaque demande, jamais reutilise, jamais renummerote.",
    "- Une ligne que l'agent ne peut pas traiter (decision a rendre, geste d'exploitation)",
    "  reste en attente avec la raison ecrite ; la relance la posera en question au lieu",
    "  de la redemander.",
    "- Une tache par relance : c'est le fichier qui declare le lot termine, pas l'agent.",
    "- Si tout est fini, vider le tableau (ou tout passer a « fait ») : une relance sur un",
    "  fichier vide s'arrete d'elle-meme.",
    "",
    "## Premier etat — remplacer la ligne modele",
    "",
    "| ID | Demande | Etat | Preuve |",
    "| --- | --- | --- | --- |",
    "| REQ-AAAAMMJJ-NN | decris la premiere tache ici | a faire | |",
    "",
    "La ligne `REQ-AAAAMMJJ-NN` est un modele : elle n'est PAS comptee par la relance",
    "(il faut 8 chiffres), donc ce fichier neuf ne declenche aucune relance tant que tu",
    "n'as pas ecrit une vraie ligne. Ensuite : `/relance`.",
    "",
  }, "\n")
end

-- Cree le suivi SEULEMENT s'il n'existe deja nulle part : on interroge toute la
-- chaine de CANDIDATES (dont docs/suivi.md) depuis le cwd, puis la cible exacte.
-- Un fichier existant n'est jamais ecrase : c'est l'historique du projet.
local function init_ledger(cwd, wanted)
  local existing = find_ledger(cwd, wanted)
  if existing then
    return nil, "exists", existing
  end
  local target = (wanted and wanted ~= "") and wanted or INIT_TARGET
  local path = target
  if path:sub(1, 1) ~= "/" and cwd then
    path = maki.fs.joinpath(cwd, path)
  end
  if maki.fs.read(path) then
    return nil, "exists", path
  end
  maki.fs.mkdir(maki.fs.dirname(path), { parents = true })
  local ok, err = maki.fs.write(path, ledger_template())
  if not ok then
    return nil, tostring(err), path
  end
  return path, nil, nil
end

local function stop(session_id, reason, notify)
  local st = sessions[session_id]
  if st then
    st.armed = false
    st.last_sig = nil
  end
  -- L'extinction doit survivre au redemarrage autant que l'armement : sinon la
  -- relance se rallumerait seule au prochain `/reload`, contre la demande.
  write_state_file()
  log.info("relance: stopped for " .. session_id .. ": " .. reason)
  if notify then
    maki.ui.flash("Relance : " .. reason)
  end
end

local function cap_label(st)
  if st.max and st.max > 0 then
    return tostring(st.max)
  end
  return "sans plafond"
end

local function tronque(texte, longueur)
  local t = (texte or ""):gsub("%s+", " ")
  if #t <= longueur then
    return t
  end
  return t:sub(1, longueur - 1) .. "…"
end

-- LA FORME « QUESTIONS ». Elle s'emploie quand AUCUNE ligne n'est traitable : demander le travail
-- produirait le meme constat encore une fois, et c'est exactement ce que le proprietaire a reproche
-- le 2026-10-28 (« il faut que /relance soit plus pertinent au niveau du suivi des taches »).
local function questions_note(st, path, unfinished, blocked)
  local lignes = {
    string.format(
      "[relance %d/%s] %s : %d tâche(s) non finie(s), dont AUCUNE traitable — les %d attendent une DÉCISION ou un ACTE du propriétaire.",
      st.runs + 1,
      cap_label(st),
      rel(path),
      #unfinished,
      #blocked
    ),
    "Ces lignes ne peuvent pas avancer sans toi : le code est livré, il manque un arbitrage ou un geste (publier, rallumer le WAF, copier des gabarits, ré-adhérer un nœud). Pose les questions, une par ligne, avec les options et leur coût :",
  }
  for i = 1, math.min(#blocked, 6) do
    lignes[#lignes + 1] = string.format("  - %s (ligne %d) — « %s »", blocked[i].id, blocked[i].line, tronque(blocked[i].demand, 110))
  end
  if #blocked > 6 then
    lignes[#lignes + 1] = string.format("  - … et %d autre(s)", #blocked - 6)
  end
  lignes[#lignes + 1] = "Une réponse tient en un message (« REQ-… a, REQ-… b »). La relance reste active et reprendra le travail dès qu'une ligne sera débloquée."
  lignes[#lignes + 1] = string.format(
    "Relance %d (%s) : seul le fichier vidé ou /relance off l'arrête ; elle survit à la compaction et à un /reload (armement écrit sur disque).",
    st.runs + 1,
    cap_label(st)
  )
  return table.concat(lignes, "\n")
end

local function resume_note(st, path, total, done, unfinished, traitable)
  local ids, extra = {}, #unfinished - 6
  for i = 1, math.min(#unfinished, 6) do
    ids[#ids + 1] = unfinished[i].id
  end
  local list = table.concat(ids, ", ")
  if extra > 0 then
    list = list .. string.format(" (+%d autres)", extra)
  end

  -- La ligne demandee est nommee, avec sa ligne de fichier et son etat : apres
  -- une compaction le modele n'a plus l'historique, et « la premiere de ces
  -- lignes » lui demandait de reconstruire ce que le resume ne portait pas.
  local cible = ""
  local first = traitable and traitable[1]
  if first then
    local demande = tronque(first.demand, 140)
    if demande ~= "" then
      cible = string.format("Prochaine ligne : %s (ligne %d) — « %s ». ", first.id, first.line, demande)
    else
      cible = string.format("Prochaine ligne : %s (ligne %d). ", first.id, first.line)
    end
  end

  return string.format(
    "[relance %d/%s] %s porte encore %d tâche(s) non finie(s) sur %d : %s. "
      .. cible
      .. "Traite-la entièrement (code, test rouge→vert, doc, preuve), puis mets SA ligne à jour dans le même geste : "
      .. "un tour qui ne touche pas le fichier compte comme un tour sans progrès, et deux d'affilée arrêtent la relance. "
      .. "Le FICHIER est le juge, jamais le résumé : si tu viens d'être compacté, relis la ligne et son état avant de conclure "
      .. "qu'elle est finie, et ne te fie pas au récit du résumé pour dire que le lot est terminé. "
      .. "Une seule tâche par relance : tu n'as pas à décider que tout est fini, c'est la relance qui te rend la main. "
      .. "Respecte l'AGENTS.md du projet (boucle T0/T1, pas de suite complète hors commit). "
      .. "Si la tâche exige une décision du propriétaire ou une action destructive, laisse-la en attente "
      .. "avec la raison écrite et prends la suivante.",
    st.runs + 1,
    cap_label(st),
    rel(path),
    #unfinished,
    total,
    list
  )
end

-- La session est occupee : ne pas prendre la parole, mais ne pas mourir non
-- plus. On reessaie ; passe le plafond on ralentit au lieu d'arreter, parce que
-- la boucle doit rester active jusqu'a extinction explicite. Seul un evenement
-- qui rend la parole peut legitimer un arret, jamais l'attente elle-meme.
local function schedule_retry(session_id, st)
  local attempts = (st.retries or 0) + 1
  st.retries = attempts
  local delay = RETRY_DELAY_MS
  if attempts > MAX_OCCUPIED_RETRIES then
    delay = SLOW_RETRY_DELAY_MS
    if (attempts - MAX_OCCUPIED_RETRIES) % 20 == 1 then
      log.info(string.format(
        "relance: session occupee depuis %d reessais, sondage ralenti a %.0f s (boucle toujours active)",
        attempts, SLOW_RETRY_DELAY_MS / 1000
      ))
    end
  else
    debug(string.format("relance: voie occupée, réessai %d/%d dans %d ms",
      attempts, MAX_OCCUPIED_RETRIES, delay))
  end
  maki.defer_fn(function()
    local current = sessions[session_id]
    if current and current.armed then
      step(session_id, false, nil)
    end
  end, delay)
end

-- Decide, then wake. `kick` is true when the user just ran /relance and the
-- session is sitting idle, so the first run does not wait for a human turn.
step = function(session_id, kick, reason_from_turn)
  local st = state_for(session_id)
  if not st.armed then
    return
  end

  if reason_from_turn then
    if reason_from_turn == "cancelled" or reason_from_turn == "dropped" then
      return stop(session_id, "tour interrompu (" .. reason_from_turn .. ")", true)
    end
    if reason_from_turn ~= "finished" and reason_from_turn ~= "max_turns" then
      -- MESURE DU 2026-11-04 : une autocompaction ferme le tour avec un motif qui
      -- n'est ni `finished` ni `max_turns`. S'arreter la rendait la boucle MUETTE
      -- juste apres la compaction, alors que le fichier gardait du travail (le
      -- proprietaire l'a constate). Un motif inconnu ne stoppe donc plus : on le
      -- note, et on continue — c'est le fichier qui decide, pas le motif du tour.
      debug("tour clos par " .. tostring(reason_from_turn) .. " : la relance continue")
    end
  end

  if st.max and st.max > 0 and st.runs >= st.max then
    return stop(session_id, string.format("plafond de %d relances atteint", st.max), true)
  end

  local snapshot, err = maki.session.read({ session = session_id })
  if not snapshot then
    return stop(session_id, "session illisible : " .. tostring(err), true)
  end

  local cwd = snapshot.cwd or maki.uv.cwd()
  local path, text = find_ledger(cwd, st.path)
  if not path then
    return stop(session_id, "aucun suivi.md trouvé depuis " .. rel(cwd or "?") .. " — /relance init crée " .. INIT_TARGET, true)
  end

  local total, done, unfinished = parse(text)
  local sig = signature(text, total, done)

  if #unfinished == 0 then
    return stop(session_id, string.format("terminé, %d/%d lignes finies dans %s", done, total, rel(path)), true)
  end

  -- Ce qui est TRAITABLE, et ce qui attend une decision. Un tampon dont toutes les lignes sont
  -- bloquees ne peut pas progresser : le compter comme « sans progres » arreterait la boucle apres
  -- deux tours, alors que la demande est qu'elle reste active jusqu'a extinction explicite.
  local traitable, blocked = {}, {}
  for _, item in ipairs(unfinished) do
    if item.blocked then
      blocked[#blocked + 1] = item
    else
      traitable[#traitable + 1] = item
    end
  end

  -- Progress check, skipped on the very first run: arming is not a relaunch.
  if st.last_sig and not kick and #traitable > 0 then
    if st.last_sig == sig then
      st.strikes = st.strikes + 1
      log.warn(string.format(
        "relance: no progress for %s (%d/%d), strike %d",
        session_id, done, total, st.strikes
      ))
      if st.strikes >= MAX_STRIKES then
        return stop(
          session_id,
          string.format("%d relances sans progrès (%d tâche(s) restante(s))", st.strikes, #unfinished),
          true
        )
      end
    else
      st.strikes = 0
    end
  end

  -- Never take the floor from the user: an in-flight run, a queued prompt, or
  -- text being typed will get to the ledger on its own.
  local queued = (snapshot.queue and snapshot.queue.count) or 0
  local composing = false
  local input = maki.ui.input()
  if input and input.session_id == session_id and (input.text or "") ~= "" then
    composing = true
  end
  if not kick and (snapshot.status == "working" or queued > 0 or composing) then
    debug("left for the next run: status " .. tostring(snapshot.status))
    schedule_retry(session_id, st)
    return
  end

  if #traitable == 0 then
    -- Une seule question par etat du fichier : la reposer a chaque tour serait le bavardage que la
    -- demande du 2026-10-28 a reproche. La boucle reste ARMEE (rien ne l'arrete), elle attend.
    if st.last_sig == sig then
      debug("relance: questions deja posees, tampon inchange, attente de la reponse")
      return
    end
    local question = questions_note(st, path, unfinished, blocked)
    st.runs = st.runs + 1
    st.last_sig = sig
    st.path = path
    st.retries = 0
    local envoye, erreur = maki.session.prompt(question, { session = session_id })
    if not envoye then
      st.runs = st.runs - 1
      return stop(session_id, "prompt refusé : " .. tostring(erreur), true)
    end
    write_state_file()
    log.info(string.format("relance: questions posees pour %s (%d bloquees)", session_id, #blocked))
    return
  end

  local text_note = resume_note(st, path, total, done, unfinished, traitable)

  st.runs = st.runs + 1
  st.last_sig = sig
  st.path = path
  st.retries = 0

  local sent, send_err = maki.session.prompt(text_note, { session = session_id })
  if not sent then
    st.runs = st.runs - 1
    return stop(session_id, "prompt refusé : " .. tostring(send_err), true)
  end
  -- L'etat sur disque doit dire la verite : `runs` et `path` n'etaient ecrits
  -- qu'a l'armement et a l'arret, et le fichier affichait « runs: 0 » apres
  -- dix-huit relances.
  write_state_file()

  log.info(string.format(
    "relance: run %d/%s for %s (%d unfinished, %d/%d done) %s",
    st.runs, cap_label(st), session_id, #unfinished, done, total, sent
  ))
end

local function status_line(session_id)
  local st = sessions[session_id]
  if not st or not st.armed then
    return "Relance : arrêtée."
  end
  local snapshot = maki.session.read({ session = session_id })
  local cwd = (snapshot and snapshot.cwd) or maki.uv.cwd()
  local path, text = find_ledger(cwd, st.path)
  if not path then
    return "Relance : active, mais aucun suivi.md trouvé. /relance init crée " .. INIT_TARGET .. "."
  end
  local total, done, unfinished = parse(text)
  local fichier = state_file()
  return string.format(
    "Relance : active sur %s — %d non finie(s) / %d (dont %d en attente de décision), %d relance(s) (%s), %d strike(s). Armement écrit dans %s (survit à la compaction et au rechargement).",
    rel(path), #unfinished, total, bloque_count(unfinished), st.runs, cap_label(st), st.strikes,
    tostring(fichier)
  )
end

local function current_session()
  local id = maki.session.current()
  if not id then
    maki.ui.flash("Relance : aucune session active")
  end
  return id
end

maki.api.register_command({
  name = "/relance",
  description = "Auto-relance l'agent tant que suivi.md garde des tâches non finies, sans plafond par défaut ; l'armement est écrit sur disque, donc il survit à /reload, à un redémarrage et à une autocompaction. /relance arme (jamais n'éteint) ; /relance init crée docs/suivi.md avec le gabarit et les règles d'écriture (jamais si un suivi existe déjà) ; /relance off arrête ; /relance 20 pose un plafond ; /relance <chemin> choisit le fichier.",
  nargs = "*",
  handler = function(opts)
    local id = current_session()
    if not id then
      return
    end
    local st = state_for(id)
    local arg = trim(opts.args or "")
    local lower = arg:lower()

    -- /relance init : cree docs/suivi.md quand aucun suivi n'existe deja, avec le
    -- gabarit qui dicte l'ecriture. Sans ce geste, armer la relance ne trouvait
    -- rien et s'arretait sur « aucun suivi.md trouve » — le proprietaire a demande
    -- que la commande sache poser le fichier au lieu de seulement le chercher.
    if lower == "init" or lower:match("^init%s") then
      local voulu = trim(arg:sub(5))
      local snapshot = maki.session.read({ session = id })
      local cwd = (snapshot and snapshot.cwd) or maki.uv.cwd()
      local path, why, known = init_ledger(cwd, voulu)
      if not path then
        if why == "exists" then
          maki.ui.flash("Relance init : un suivi existe deja (" .. rel(known) .. "), rien n'a ete cree. Pour en changer : /relance " .. rel(known))
        else
          maki.ui.flash("Relance init : " .. rel(tostring(known or voulu)) .. " n'a pas pu etre cree (" .. tostring(why) .. ")")
        end
        return
      end
      maki.ui.flash("Relance init : " .. rel(path) .. " cree avec son gabarit et ses regles. Ecris ta premiere ligne REQ (ou coche une case), puis /relance.")
      log.info("relance: init created " .. path)
      return
    end

    if lower == "off" or lower == "stop" or lower == "arrêt" or lower == "arret" or lower == "0" then
      if not st.armed then
        maki.ui.flash("Relance : déjà arrêtée")
        return
      end
      stop(id, "arrêt demandé", true)
      return
    end

    if lower == "status" or lower == "etat" or lower == "état" then
      maki.ui.flash(status_line(id))
      return
    end

    -- MESURE DU 2026-11-04 : le binaire « /relance » NU servait a la fois a
    -- armer et a eteindre, et la trace de la session portait « stopped … arrêt
    -- demandé » alors que le proprietaire croyait l'avoir relancee. Un geste qui
    -- veut dire deux choses est un piege : nu, il ARME (ou confirme qu'elle est
    -- deja armee), et seule une extinction EXPLICITE arrete.
    if lower == "on" or lower == "start" or lower == "go" then
      arg = ""
    end

    if arg == "" and st.armed then
      maki.ui.flash("Relance : déjà active. Pour l'arrêter : /relance off. " .. status_line(id))
      return
    end

    if arg ~= "" then
      local n = tonumber(arg)
      if n then
        st.max = math.floor(n)
        if st.max < 1 then
          st.max = DEFAULT_MAX
        end
      else
        st.path = arg
      end
    end

    st.armed = true
    st.runs = 0
    st.strikes = 0
    st.last_sig = nil
    st.restored = false
    -- Ecrit AVANT le premier tour : si maki est recharge ou redemarre dans la
    -- seconde, l'armement ne depend pas d'un tour qui n'a pas encore eu lieu.
    write_state_file()

    local snapshot = maki.session.read({ session = id })
    local cwd = (snapshot and snapshot.cwd) or maki.uv.cwd()
    local path, text = find_ledger(cwd, st.path)
    if not path then
      st.armed = false
      maki.ui.flash("Relance : aucun suivi.md trouvé depuis " .. rel(cwd or "?") .. " — /relance init crée " .. INIT_TARGET .. ".")
      return
    end
    local total, done, unfinished = parse(text)
    maki.ui.flash(string.format(
      "Relance armée : %s, %d non finie(s) / %d (dont %d en attente de décision), plafond %s.",
      rel(path), #unfinished, total, bloque_count(unfinished), cap_label(st)
    ))
    log.info(string.format("relance: armed for %s on %s (%d/%d done)", id, path, done, total))

    if #unfinished == 0 then
      stop(id, "rien à faire, toutes les lignes sont finies", true)
      return
    end

    step(id, true, nil)
  end,
})

-- LA PAROLE RENDUE. `step` s'efface quand le proprietaire occupe la session ;
-- ces deux evenements sont le moment ou il la rend, et sans eux le sondage
-- reste seul juge. Une session qui passe a `idle`, ou une barre de saisie qui
-- change d'etat, remet le compteur a zero et reveille la relance aussitot.
-- `InputChanged` precede le tour : c'est ce qui rattrape le cas `/btw`, ou la
-- session principale ne recoit aucun `TurnEnd` pendant que l'agent parallele
-- repond.
maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(ev)
    local data = ev.data or {}
    local id = data.session_id or maki.session.current()
    if not id or data.status ~= "idle" then
      return
    end
    local st = sessions[id]
    if not (st and st.armed) then
      return
    end
    st.retries = 0
    maki.defer_fn(function()
      local s2 = sessions[id]
      if s2 and s2.armed then
        step(id, false, nil)
      end
    end, 500)
  end,
})

maki.api.create_autocmd("InputChanged", {
  callback = function(ev)
    local id = (ev.data and ev.data.session_id) or maki.session.current()
    local st = id and sessions[id]
    if not (st and st.armed and (st.retries or 0) > 0) then
      -- Rien n'attendait la place : eviter de traverser `step` a chaque touche.
      return
    end
    local input = maki.ui.input()
    if input and input.session_id == id and (input.text or "") ~= "" then
      -- La frappe continue : le sondage differe s'en occupe, pas la touche.
      return
    end
    st.retries = 0
    maki.defer_fn(function()
      local s2 = sessions[id]
      if s2 and s2.armed then
        step(id, false, nil)
      end
    end, 300)
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(ev)
    local id = ev.data and ev.data.session_id
    if not id then
      return
    end
    -- Let the turn finish tearing down before posting the next one: a prompt
    -- sent in the same tick races the history write it just ended.
    local reason = ev.data.reason
    maki.defer_fn(function()
      step(id, false, reason)
    end, 300)
  end,
})

maki.api.create_autocmd("SessionEnd", {
  callback = function(ev)
    local id = ev.data and ev.data.session_id
    if id then
      -- La table seulement : le FICHIER garde l'armement. Une fin de session
      -- n'est pas une extinction demandee, et un evenement de trop ne doit pas
      -- eteindre la boucle au prochain chargement.
      sessions[id] = nil
    end
  end,
})

-- COMPACTION : c'est le moment ou le modele perd l'historique detaille. Deux
-- choses ici, et pas une de plus.
--  1. Les strikes sont remis a zero : les tours de relecture qui suivent une
--     compaction ne touchent pas le fichier, et comptaient comme « sans
--     progres » — deux d'affilee eteignaient la relance juste apres une
--     autocompaction (mesure du 2026-11-04).
--  2. Un tour est relance si personne ne l'a fait. Le plugin autocompact poste
--     deja sa note de reprise ; le garde-fou « travail en cours / prompt en
--     file » de `step` empeche alors le doublon. Si `resume` est desactive la
--     bas, c'est cette voie qui reprend le travail.
maki.api.create_autocmd("CompactionDone", {
  callback = function(ev)
    local id = ev.data and ev.data.session_id
    if not id then
      return
    end
    local st = sessions[id]
    if st then
      st.strikes = 0
      st.last_sig = nil
    end
    log.info("relance: compaction terminee pour " .. id .. " (strikes remis a zero)")
    maki.defer_fn(function()
      local s2 = sessions[id]
      if s2 and s2.armed then
        step(id, false, nil)
      end
    end, 3000)
  end,
})

-- REPRISE APRES CHARGEMENT : `/reload` reconstruit ce module, et un redemarrage
-- de maki repart d'une table vide. Sans cette reprise, la boucle s'eteignait en
-- silence alors que le fichier gardait du travail — c'est exactement ce que le
-- proprietaire a constate le 2026-11-04.
local function reprendre_si_restaure(id)
  if not id then
    return
  end
  local st = state_for(id)
  if st.armed and st.restored then
    st.restored = false
    maki.ui.flash("Relance : armement restauré du disque, la boucle reprend.")
    maki.defer_fn(function()
      step(id, false, nil)
    end, 500)
  end
end

maki.api.create_autocmd("SessionFocusChanged", {
  callback = function(ev)
    reprendre_si_restaure(ev.data and ev.data.session_id)
  end,
})

maki.defer_fn(function()
  reprendre_si_restaure(maki.session.current())
end, 2500)


-- Kept for the day a spec runner exists: the parser is pure.
-- `_test` est la surface de sonde de `tests/relance-survie.sh` : elle n'ouvre
-- rien que le plugin ne fasse deja (ecrire/relire l'armement, l'arreter), et
-- elle permet de prouver la durabilite sans attendre un vrai `/reload`.
return {
  parse = parse,
  is_done = is_done,
  _test = {
    state_for = state_for,
    schedule_retry = schedule_retry,
    retry_policy = function() return MAX_OCCUPIED_RETRIES, RETRY_DELAY_MS, SLOW_RETRY_DELAY_MS end,
    state_file = state_file,
    read_state = read_state_file,
    write_state = write_state_file,
    stop = stop,
    sessions = sessions,
  },
}
